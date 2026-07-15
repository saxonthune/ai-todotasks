# Harden archive.sh: `--merged` salvage exit + correct success exit code

## Motivation

Two correctness gaps in `archive.sh`, fixed together because they touch the same
file:

**(A) No archive exit for manually-salvaged work.** Manual salvage is the
documented recovery for a crashed agent: finish the work by hand in its worktree,
commit on the agent branch, squash-merge to trunk. But the archive tooling has no
exit for that path. Every route refuses it: `archive.sh <slug>` skips it as
not-success, `--force-failed` skips it (a `salvageable` outcome is deliberately
excluded from force-eligibility so we never auto-`rm` a worktree with recoverable
work), and removing the run-record makes it reclassify as `pending` and get
skipped again — leaving a phantom crashed row pointing at a deleted worktree, and
a merged spec a batch executor would happily re-run. The operator is pushed into
the exact hand-moving of files the skill says never to do.

The fix is an explicit operator assertion: `archive.sh --merged <slug>` archives
the named slug(s) regardless of classified outcome — the operator is asserting the
work already landed on trunk, so the spec/results should be `git rm`'d and the
worktree/branch cleaned up like any completed task.

**(B) `archive.sh` exits 1 after a successful archive.** The script's final line
`[[ $archived -eq 0 ]] && echo "- Nothing to archive."` leaks a non-zero exit
whenever something *was* archived: `$archived` is non-zero, so the `[[ ]]` test is
false, the `&&` short-circuits, and — as the last statement under `set -uo
pipefail` — the failed test becomes the script's exit code. A caller chaining
`archive.sh && just test` sees the follow-up silently skipped and a spurious error.
A successful archive (or a no-op sweep with nothing to do) must exit 0; non-zero is
reserved for genuine failures.

## Do NOT

- Do NOT make `--merged` a sweep — it requires explicit slug(s). Without slugs it
  is an error. It must never archive an outcome the operator did not name.
- Do NOT try to auto-detect reachability-from-trunk. A squash-merge produces a new
  commit, so the agent branch's commits are NOT literally reachable — a reachability
  check would wrongly refuse the salvage case. `--merged` trusts the operator.
- Do NOT skip a slug that is still `running` — a live run must never be archived.
  This one guard stays even under `--merged`.
- Do NOT change the default (no-flag) or `--force-failed` eligibility rules.
- Do NOT alter `archive_one`'s file-moving mechanics (it already handles a
  stranded worktree agent.md correctly). `--merged` only changes *which* slugs
  reach `archive_one`, not how they are archived.
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.

## Plan

### 1. `skills/todo-task/archive.sh` — parse `--merged` and route asserted slugs

In the arg loop (around lines 30-36) add a `MERGED=false` flag and a `--merged`
case that sets it true, alongside the existing `--force-failed`.

In the explicit-slug branch (around lines 97-113), the current gate is:

```bash
    if [[ "$overall" == "$SM_OVERALL_SUCCESS" ]] || { [[ "$FORCE_FAILED" == "true" ]] && force_eligible "$overall"; }; then
      archive_one "$slug"; archived=$((archived+1))
    else
      echo "- Skipped ${slug} (${overall}) — pass --force-failed to archive failures, or merge/resolve manually"
    fi
```

Add a `--merged` short-circuit that still respects the `running` guard (which is
checked just above, at line ~105) but bypasses the outcome-eligibility check:

```bash
    if [[ "$MERGED" == "true" ]]; then
      echo "- Archiving ${slug} (operator asserts merged to trunk)"
      archive_one "$slug"; archived=$((archived+1)); continue
    fi
    if [[ "$overall" == "$SM_OVERALL_SUCCESS" ]] || { [[ "$FORCE_FAILED" == "true" ]] && force_eligible "$overall"; }; then
      ...
```

If `--merged` is passed with NO slugs, error out (mirror the "Unknown option"
style): print a usage note and exit non-zero — `--merged` is meaningless as a
sweep because "merged" is an assertion about specific slugs.

### 2. `skills/todo-task/archive.sh` — update the header usage block

Extend the header comment (lines 9-20) to document the new flag:

```
#   archive.sh --merged <slug>  archive slug(s) the operator merged/resolved by hand
```

and note it bypasses outcome eligibility (still skips a running slug).

### 3. `skills/todo-task/archive.sh` — fix the success exit code

Ensure the script exits 0 when it archived something (or when a sweep found
nothing to do), reserving non-zero for genuine failures. The minimal fix: make the
final "nothing to archive" line unable to leak, and end the script with an explicit
`exit 0`. For example, change the tail:

```bash
if [[ $archived -eq 0 ]]; then
  echo "- Nothing to archive."
fi
exit 0
```

Do NOT invent a new failure exit path in this task — an explicit-slug "no such
task" already prints a "- Skipped" line; leaving overall exit 0 is acceptable and
matches the draft's "reserve non-zero for actual failures" (there is no actual
failure here). Keep the change surgical.

### 4. `skills/todo-task/SKILL.md` — document the salvage exit

In the status/triage flow where conflict and salvaged agents are discussed, add a
brief note: after manually finishing and merging a crashed/salvaged agent's work
to trunk, run `archive.sh --merged <slug>` to clean up — this is the sanctioned
exit that replaces hand-moving files into `.archived/`. Keep it to a couple of
lines; do not restructure the doc.

## Files to Modify

- `skills/todo-task/archive.sh` — Step 1 (parse `--merged`, route asserted slugs, guard empty-slug case) + Step 2 (header usage) + Step 3 (fix success exit code).
- `skills/todo-task/SKILL.md` — Step 4 (short note on the salvage archive exit).

## Verification

```bash
# Script still parses.
bash -n skills/todo-task/archive.sh && echo "archive OK"

# The flag is parsed and routed.
grep -q -- '--merged' skills/todo-task/archive.sh && echo "flag present OK"
grep -q 'operator asserts merged' skills/todo-task/archive.sh && echo "route present OK"

# Empty-slug --merged is rejected (no such task / usage error, non-zero exit),
# and never archives a sweep. Run from repo root in the worktree.
if bash skills/todo-task/archive.sh --merged >/dev/null 2>&1; then
  echo "EMPTY-SLUG GUARD FAILED (should exit non-zero)"
else
  echo "empty-slug --merged rejected OK"
fi

# Success exit code: an empty sweep (nothing to archive) must exit 0, not 1.
# Run from the worktree repo root; with no completed outcomes this sweeps nothing.
if bash skills/todo-task/archive.sh >/dev/null 2>&1; then
  echo "empty sweep exits 0 OK"
else
  echo "EXIT-CODE FIX FAILED (empty sweep should exit 0)"
fi
grep -q 'exit 0' skills/todo-task/archive.sh && echo "explicit exit 0 present OK"

# Header documents the flag.
grep -q 'archive.sh --merged' skills/todo-task/archive.sh && echo "header doc OK"

# SKILL.md mentions the salvage exit.
grep -q 'archive.sh --merged' skills/todo-task/SKILL.md && echo "SKILL doc OK"
```

## Out of Scope

- Auto-detection of trunk-reachability (deliberately rejected — squash merges
  break it, and the operator assertion is the safe contract).
- Any change to `report.sh` classification or the `salvageable` outcome itself.
- The default sweep and `--force-failed` behavior.

## Notes

- The `running` guard is the one safety check `--merged` keeps: the reporter marks
  a slug `running` only while its run-record PID is alive, so refusing those
  prevents archiving a task mid-flight even if the operator fat-fingers the slug.
- `archive_one` already copies a stranded worktree agent.md into `.archived/`
  before `git rm`, so a salvaged task with no trunk-side result file still archives
  a useful record.
