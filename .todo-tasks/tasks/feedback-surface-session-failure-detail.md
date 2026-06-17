# Surface the real failure reason and salvageable work on session failure

## Motivation

When a headless session fails, the orchestrator throws away almost everything it
already knows. `phase_run_session` captures the full `claude -p --output-format json`
blob and the exit code, but the only thing that survives is one line —
`"Claude CLI exited with code 1"`. The agent.md `## Summary` ends up empty (on a
non-zero exit `.result` is empty and we don't fall back to raw output), and the
`0 commits` heuristic flags the run as a no-op even when the worktree holds
complete, passing, *uncommitted* work. A near-miss success ("hit the turn cap one
step before `git commit`") is indistinguishable from a total crash, costing a
15–20 minute manual forensic dig every time.

This task surfaces, in `agent.md` and `status.sh`, (a) the **real terminal reason**
plus turns/cost spent vs caps, and (b) **salvageable uncommitted work** in the
worktree — and introduces a new overall state so a dirty 0-commit run is no longer
misclassified as a no-op.

## Do NOT

- Do NOT make the headless agent write any result file. `agent.md` is
  orchestrator-owned (`write_agent_result`), written while cd'd in the worktree.
- Do NOT move the uncommitted-work detection somewhere that only the no-op path
  reaches. On session failure `main()` skips `phase_verify` entirely — the
  detection MUST run on both the session-failed path and the no-op path. Compute
  it once at the end of `phase_run_session` (which already `cd`s into the worktree)
  so both branches inherit it.
- Do NOT add the new `salvageable` state to `force_eligible` in `archive.sh` — it
  must stay un-archivable so `--force-failed` never `git rm`s recoverable work.
- Do NOT change the JSON parsing to assume fields exist. The CLI may emit
  non-JSON on a hard crash (auth/network). Every `jq` read uses `// empty` and the
  code degrades to "exit code N, output not JSON".
- Do NOT alter the success path behavior (commits > 0, clean merge). The new
  fields are additive; existing success classification must be unchanged.
- Do NOT break the existing `write_agent_result` call in `emergency_finalize` —
  the new parameters must be optional with safe defaults.

## Plan

### 1. lib.sh — new state, bucket, and config default

In the state-machine vocabulary block (`lib.sh`, near the `SM_OVERALL_*`
constants), add:

```bash
readonly SM_OVERALL_SALVAGEABLE="salvageable"
```

In `source_task_config`, add a `MAX_TURNS` default alongside the budget defaults:

```bash
MAX_TURNS="${MAX_TURNS:-100}"
```

In `state_bucket`, map the new state to the attention bucket (it already falls
through to attention via the `*)` default, but add an explicit case for clarity):

```bash
"$SM_OVERALL_SALVAGEABLE") echo "$SM_BUCKET_ATTENTION" ;;
```

### 2. lib.sh — `derive_overall_state` takes an `uncommitted` signal

Change the signature to accept a trailing `uncommitted` argument and let
salvageable work supersede both `session_failed` and `no_op`:

```bash
# derive_overall_state <session> <verification> <merge> [trunk] [uncommitted]
# uncommitted: human summary ("3 files, 280 lines") or "none"/"0"/empty when clean.
derive_overall_state() {
  local session="$1" verify="$2" merge="$3" trunk="${4:-$SM_TRUNK_UNCHANGED}" uncommitted="${5:-none}"
  local has_dirt=false
  [[ -n "$uncommitted" && "$uncommitted" != "none" && "$uncommitted" != "0" ]] && has_dirt=true

  if [[ "$session" == "$SM_SESSION_FAILED" ]]; then
    if [[ "$has_dirt" == "true" ]]; then echo "$SM_OVERALL_SALVAGEABLE"; else echo "$SM_OVERALL_SESSION_FAIL"; fi
    return
  fi
  case "$verify" in
    "$SM_VERIFY_FAILED") echo "$SM_OVERALL_BUILD_FAIL" ;;
    "$SM_VERIFY_SKIPPED")
      if [[ "$trunk" == "$SM_TRUNK_MOVED" ]]; then
        echo "$SM_OVERALL_TRUNK_LEAK"
      elif [[ "$has_dirt" == "true" ]]; then
        echo "$SM_OVERALL_SALVAGEABLE"
      else
        echo "$SM_OVERALL_NOOP"
      fi ;;
    "$SM_VERIFY_PASSED")
      # ... unchanged merge case block ...
  esac
}
```

Keep the existing `SM_VERIFY_PASSED` merge sub-case block exactly as-is.

### 3. lib.sh — `summarize_uncommitted` helper

Add a read-only helper that reports both a file count and a line count
(including untracked files, via a throwaway intent-to-add that is immediately
reset so the worktree is left pristine):

```bash
# summarize_uncommitted <dir>
# Echoes "N files, M lines" if the worktree has uncommitted changes (tracked
# modifications AND untracked files), or "none" when clean. Read-only: any
# intent-to-add markers used to count untracked lines are reset before return.
summarize_uncommitted() {
  local dir="$1"
  local porcelain; porcelain=$(git -C "$dir" status --porcelain 2>/dev/null || true)
  [[ -z "$porcelain" ]] && { echo "none"; return; }
  local files; files=$(echo "$porcelain" | grep -c . || echo 0)
  git -C "$dir" add -A --intent-to-add >/dev/null 2>&1 || true
  local lines; lines=$(git -C "$dir" diff --numstat 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
  git -C "$dir" reset -q >/dev/null 2>&1 || true
  echo "${files} files, ${lines} lines"
}
```

### 4. lib.sh — `write_agent_result` gains turns/cost/uncommitted fields

Append three optional positional params (after `surface_deviations`) and write
them as `key: value` header fields when present. Keeping them optional with
defaults means `emergency_finalize`'s existing 12-arg call still works:

```bash
write_agent_result() {
  local result_path="$1" slug="$2" session="$3" verification="$4"
  local commits_count="$5" commits_log="$6" branch="$7" session_id="$8"
  local claude_result="$9" build_test_tail="${10}"
  local error_detail="${11:-}" surface_deviations="${12:-none}"
  local turns="${13:-}" cost="${14:-}" uncommitted="${15:-none}"
  ...
}
```

In the heredoc header, after the `surface deviations:` line, add (guarded so empty
turns/cost are omitted; `uncommitted` always written so the reporter and
`classify_task` can read it):

```bash
$(if [[ -n "$turns" ]]; then echo "turns: ${turns}"; fi)
$(if [[ -n "$cost" ]]; then echo "cost: ${cost}"; fi)
uncommitted: ${uncommitted}
```

### 5. lib.sh — `classify_task` reads and forwards `uncommitted`

In `classify_task`, after reading `session`/`verification` from the agent.md, also
read the `uncommitted` field and pass it to `derive_overall_state`:

```bash
local uncommitted=""
if [[ -n "$agent_md" && -f "$agent_md" ]]; then
  session=$(parse_result_field "$agent_md" session)
  verification=$(parse_result_field "$agent_md" verification)
  uncommitted=$(parse_result_field "$agent_md" uncommitted)
fi
...
uncommitted="${uncommitted:-none}"
...
derive_overall_state "$session" "$verification" "$merge" "$trunk" "$uncommitted"
```

### 6. execute-plan.sh — parse terminal reason + measure uncommitted work

In `phase_run_session`, after `CLAUDE_EXIT=$?` and the existing
`session_id`/`result` extraction, parse the richer JSON fields and build a
friendly `SESSION_ERROR`. Also capture turns/cost into script-scope vars
(`SESSION_TURNS`, `SESSION_COST`) and measure uncommitted work (this function is
already `cd`'d into the worktree):

```bash
SESSION_SUBTYPE=$(echo "${CLAUDE_OUTPUT}" | jq -r '.subtype // empty' 2>/dev/null || echo "")
SESSION_TURNS=$(echo "${CLAUDE_OUTPUT}" | jq -r '.num_turns // empty' 2>/dev/null || echo "")
SESSION_COST=$(echo "${CLAUDE_OUTPUT}" | jq -r '.total_cost_usd // empty' 2>/dev/null || echo "")
```

Format the persisted field values (only when the numbers are present):

```bash
TURNS_FIELD=""; [[ -n "$SESSION_TURNS" ]] && TURNS_FIELD="${SESSION_TURNS}/${MAX_TURNS}"
COST_FIELD="";  [[ -n "$SESSION_COST" ]]  && COST_FIELD="\$${SESSION_COST}/\$${MAX_BUDGET}"
UNCOMMITTED_SUMMARY=$(summarize_uncommitted "${WORKTREE_DIR}")
```

When `CLAUDE_EXIT -ne 0`, replace the bare exit-code message with a mapped reason
that always includes the exit code and, when known, the subtype and spend:

```bash
if [[ $CLAUDE_EXIT -ne 0 ]]; then
  SESSION_STATE="$SM_SESSION_FAILED"
  case "$SESSION_SUBTYPE" in
    error_max_turns)
      SESSION_ERROR="Ran out of turns (reached --max-turns ${MAX_TURNS})" ;;
    error_during_execution)
      SESSION_ERROR="Error during execution (CLI exit ${CLAUDE_EXIT})" ;;
    "")
      SESSION_ERROR="Claude CLI exited with code ${CLAUDE_EXIT} — output was not JSON (possible auth/network failure)" ;;
    *)
      SESSION_ERROR="Claude CLI exited with code ${CLAUDE_EXIT} (subtype: ${SESSION_SUBTYPE})" ;;
  esac
  [[ -n "$SESSION_TURNS" || -n "$SESSION_COST" ]] && \
    SESSION_ERROR="${SESSION_ERROR}; spent ${SESSION_TURNS:-?} turns / \$${SESSION_COST:-?}"
fi
```

Keep the existing `elif [[ -z "$CLAUDE_RESULT" && -z "$SESSION_ID" ]]` no-result
branch. ALSO: so the empty-`.result` case isn't a blank `## Summary`, fall back to
the raw output when `.result` is empty — change the `CLAUDE_RESULT` assignment so
an empty `.result` yields the trimmed raw `CLAUDE_OUTPUT` instead of "":

```bash
CLAUDE_RESULT=$(echo "${CLAUDE_OUTPUT}" | jq -r '.result // empty' 2>/dev/null || echo "")
[[ -z "$CLAUDE_RESULT" ]] && CLAUDE_RESULT="${CLAUDE_OUTPUT}"
```

Initialize `SESSION_TURNS=""`, `SESSION_COST=""`, `UNCOMMITTED_SUMMARY="none"`,
`TURNS_FIELD=""`, `COST_FIELD=""` near the top of the script (with the other early
inits like `SURFACE_DEVIATIONS`) so `set -u` and `emergency_finalize` are safe.

### 7. execute-plan.sh — use `MAX_TURNS` in the CLI invocation

Replace the hardcoded `--max-turns 100` in `phase_run_session` with
`--max-turns "${MAX_TURNS}"` so the cap and the reported "N/100" stay in sync.
(The retry invocation's `--max-turns 50` can stay as-is — out of scope.)

### 8. execute-plan.sh — pass new fields into `write_agent_result`

In `phase_compose_agent_result`, extend the `write_agent_result` call to forward
the new values:

```bash
write_agent_result "$agent_md" "$PLAN_SLUG" \
  "$SESSION_STATE" "$VERIFICATION_STATE" \
  "${COMMITS_COUNT:-0}" "${COMMITS:-(none)}" "$BRANCH" "${SESSION_ID:-}" \
  "${CLAUDE_RESULT:-}" "$build_test_tail" "${SESSION_ERROR:-}" "${SURFACE_DEVIATIONS:-none}" \
  "${TURNS_FIELD:-}" "${COST_FIELD:-}" "${UNCOMMITTED_SUMMARY:-none}"
```

### 9. execute-plan.sh — annotate the no-op log message

In `phase_verify`, the `else` branch that prints `"Agent produced 0 commits.
Marking as no-op."` should mention salvageable work when present:

```bash
if [[ "$UNCOMMITTED_SUMMARY" != "none" ]]; then
  echo "WARNING: Agent produced 0 commits, but the worktree has uncommitted work: ${UNCOMMITTED_SUMMARY} (salvageable)."
else
  echo "WARNING: Agent produced 0 commits. Marking as no-op."
fi
```

### 10. report.sh — surface uncommitted work in the notes column

In `classify_slug`, where `notes` is built from the agent.md fields, also read the
`uncommitted` field and append a caveat when it's not clean:

```bash
local unc; unc="$(parse_result_field "$agent_md" uncommitted)"
[[ -n "$unc" && "$unc" != "none" && "$unc" != "0" ]] && \
  notes="${notes}${unc} uncommitted in worktree (salvageable). "
```

Place this alongside the existing `dev`/`err` note-building so the order reads:
surface-deviation note, then uncommitted note, then error text. Keep the existing
tab/newline stripping that follows.

### 11. archive.sh — confirm salvageable is NOT force-eligible

Verify (and leave) `force_eligible` WITHOUT `$SM_OVERALL_SALVAGEABLE`. Add a brief
comment noting the deliberate omission so a future edit doesn't "helpfully" add it:

```bash
# Note: SM_OVERALL_SALVAGEABLE is intentionally absent — never auto-rm a worktree
# that holds recoverable uncommitted work. Resolve it by hand.
```

### 12. task-config.template.sh — document MAX_TURNS

Add a `MAX_TURNS` entry near `MAX_BUDGET` in the template (and the repo's own
`.todo-tasks/task-config.sh`) so the new knob is discoverable:

```bash
# Maximum agent turns per headless session
MAX_TURNS=100
```

### 13. contracts.md — record the new state

Add one line to the Reporter algorithm / classification description noting that a
0-commit run with a dirty worktree classifies as `salvageable` (attention bucket,
not auto-archivable), distinct from `no_op`.

## Files to Modify

- `.claude/skills/todo-task/lib.sh` — `SM_OVERALL_SALVAGEABLE` const, `MAX_TURNS` default, `state_bucket` case, `derive_overall_state` signature+logic, `summarize_uncommitted` helper, `write_agent_result` params+fields, `classify_task` reads/forwards `uncommitted`
- `.claude/skills/todo-task/execute-plan.sh` — early var inits, terminal-reason parsing + `CLAUDE_RESULT` fallback in `phase_run_session`, `--max-turns "${MAX_TURNS}"`, no-op log annotation in `phase_verify`, extended `write_agent_result` call in `phase_compose_agent_result`
- `.claude/skills/todo-task/report.sh` — append uncommitted caveat to `notes` in `classify_slug`
- `.claude/skills/todo-task/archive.sh` — clarifying comment on `force_eligible` omission
- `.claude/skills/todo-task/task-config.template.sh` — document `MAX_TURNS`
- `.todo-tasks/task-config.sh` — add `MAX_TURNS=100`
- `contracts.md` — document `salvageable` state

## Verification

```bash
# All scripts pass syntax check
bash -n .claude/skills/todo-task/lib.sh
bash -n .claude/skills/todo-task/execute-plan.sh
bash -n .claude/skills/todo-task/report.sh
bash -n .claude/skills/todo-task/archive.sh

# derive_overall_state: dirty 0-commit cases classify as salvageable, clean ones don't
bash -c '
source .claude/skills/todo-task/lib.sh
fail=0
check() { [[ "$1" == "$2" ]] && echo "ok: $3" || { echo "FAIL: $3 — got $1 want $2"; fail=1; }; }
check "$(derive_overall_state failed failed not_attempted unchanged "3 files, 280 lines")" "salvageable" "session-failed + dirty -> salvageable"
check "$(derive_overall_state failed failed not_attempted unchanged none)" "session_failed" "session-failed + clean -> session_failed"
check "$(derive_overall_state completed skipped_no_commits not_attempted unchanged "2 files, 10 lines")" "salvageable" "no-op + dirty -> salvageable"
check "$(derive_overall_state completed skipped_no_commits not_attempted unchanged none)" "no_op" "no-op + clean -> no_op"
check "$(derive_overall_state completed skipped_no_commits not_attempted moved "9 files, 9 lines")" "trunk_leak" "trunk-leak still wins over dirt"
check "$(derive_overall_state completed passed clean unchanged none)" "success" "clean success unchanged"
check "$(state_bucket salvageable)" "attention" "salvageable buckets to attention"
exit $fail
'

# summarize_uncommitted: clean repo -> none; leaves worktree pristine
bash -c '
source .claude/skills/todo-task/lib.sh
tmp=$(mktemp -d); git -C "$tmp" init -q; git -C "$tmp" commit -q --allow-empty -m init
[[ "$(summarize_uncommitted "$tmp")" == "none" ]] && echo "ok: clean -> none" || echo "FAIL: clean should be none"
echo "new content" > "$tmp/newfile.txt"
out="$(summarize_uncommitted "$tmp")"
[[ "$out" == *"file"* && "$out" != "none" ]] && echo "ok: dirty -> $out" || echo "FAIL: dirty not detected"
[[ -z "$(git -C "$tmp" status --porcelain | grep "^A")" ]] && echo "ok: no leftover intent-to-add" || echo "FAIL: intent-to-add not reset"
rm -rf "$tmp"
'

# write_agent_result with new fields produces parseable turns/cost/uncommitted
bash -c '
source .claude/skills/todo-task/lib.sh
tmp=$(mktemp)
write_agent_result "$tmp" demo failed failed 0 "(none)" br "" "" "" "Ran out of turns" none "47/100" "\$2.10/\$5.00" "3 files, 280 lines"
grep -q "^turns: 47/100" "$tmp" && echo "ok: turns field" || echo "FAIL: turns field"
grep -q "^uncommitted: 3 files, 280 lines" "$tmp" && echo "ok: uncommitted field" || echo "FAIL: uncommitted field"
[[ "$(parse_result_field "$tmp" uncommitted)" == "3 files, 280 lines" ]] && echo "ok: uncommitted parses" || echo "FAIL: uncommitted parse"
[[ "$(classify_task "$tmp" "")" == "salvageable" ]] && echo "ok: classify_task -> salvageable" || echo "FAIL: classify_task"
rm -f "$tmp"
'

# emergency_finalize backward-compat: 12-arg write_agent_result call still works
bash -c '
source .claude/skills/todo-task/lib.sh
tmp=$(mktemp)
write_agent_result "$tmp" demo failed failed 0 "(none)" br "" "stub" "" "boom" none
grep -q "^uncommitted: none" "$tmp" && echo "ok: 12-arg call defaults uncommitted" || echo "FAIL: 12-arg default"
rm -f "$tmp"
'
```

## Out of Scope

- Streaming live progress of a running session (separate task:
  `feedback-headless-run-invisible-progress`).
- Auto-committing or auto-recovering the salvageable work — this task only makes
  it *visible*. Recovery stays a human action.
- Changing the retry invocation's `--max-turns 50`.
- Any change to chain/epic result handling beyond what falls out of the shared
  `classify_task`/`derive_overall_state` changes.

## Notes

- The CLI JSON shape is confirmed as `{type, subtype, result, session_id, ...}`;
  `num_turns`/`total_cost_usd`/`is_error` are standard siblings. All reads use
  `// empty` so a non-JSON hard-crash degrades gracefully to "exit code N".
- `summarize_uncommitted` uses `git add -A --intent-to-add` followed by
  `git reset -q` purely to count untracked lines. The reset restores a pristine
  worktree — reviewers should confirm the verification's "no leftover
  intent-to-add" check passes, since a human will salvage from that worktree.
- `derive_overall_state` gains a 5th parameter. Every caller goes through
  `classify_task`, which is updated to pass it — grep for other direct callers
  before finishing to be safe.
- `salvageable` deliberately sits in the attention bucket and is excluded from
  `--force-failed`, so it persists in `status.sh` until a human resolves it. This
  is intended: the whole point is to stop near-miss work from being discarded.

## Surface after this phase

- `lib.sh` exports a new overall state `SM_OVERALL_SALVAGEABLE="salvageable"`,
  bucketed to attention.
- `lib.sh` `derive_overall_state` signature is
  `<session> <verification> <merge> [trunk] [uncommitted]`; a non-clean
  `uncommitted` value yields `salvageable` for both session-failed and no-op
  inputs (trunk-leak still takes precedence).
- `lib.sh` exposes `summarize_uncommitted <dir>` → `"N files, M lines"` or
  `"none"`, read-only (no persistent index changes).
- `lib.sh` `write_agent_result` accepts trailing optional params
  `[turns] [cost] [uncommitted]` and writes `turns:`, `cost:`, and `uncommitted:`
  header fields; `uncommitted:` is always present (defaults to `none`).
- `lib.sh` `classify_task` reads the `uncommitted` field and forwards it to
  `derive_overall_state`.
- `lib.sh` `source_task_config` sets `MAX_TURNS` (default 100).
- Agent result files (`results/{slug}.agent.md`) now carry `turns:`, `cost:`, and
  `uncommitted:` fields in addition to the existing header fields.
- `report.sh` task records include the uncommitted-work caveat in the `notes`
  column when a run left salvageable work.
- `archive.sh` `force_eligible` still excludes `salvageable` — such runs are never
  auto-archived.
