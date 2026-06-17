# Stream headless-run progress to the log

## Motivation

During a headless run, `execute-plan.sh` captures Claude's output with
`CLAUDE_OUTPUT=$(claude … --output-format json …)` (phase_run_session, ~line 251).
The `json` format emits a single object only when the process exits, so the run's
`.log` file — which `launch.sh` feeds from execute-plan's stdout — stays frozen at
the banner for the entire run. `monitor.sh` reads a running task's `age` from the
run-record, which is written once at launch and never touched again, so it counts up
from launch time, not from last activity. The result: a working 25-minute agent and a
hung one are indistinguishable from the outside, which drives bad triage decisions
(launching backup work for an agent that was actually fine).

The `claude` CLI (v2.1.179) supports `--output-format stream-json` with `--verbose`,
emitting one NDJSON event per turn in realtime. Streaming a concise digest to stdout
makes the `.log` grow continuously, and its mtime becomes a real "last activity" signal
the dashboard can surface for free — no separate heartbeat file needed.

This task covers **Part 1 (streaming progress)** only. Part 2 of the original draft
(the residual "no-op" wording polish) stays in the inbox for later.

## Do NOT

- Do NOT change the two `claude -p` calls in `phase_retry_if_needed` (~lines 381, 394).
  They stay on `--output-format json`. Only `phase_run_session` streams.
- Do NOT merge Claude's stderr into the NDJSON stream. The current `json` call uses
  `2>&1`; the streaming call MUST send stderr to a separate file (it would corrupt jq
  parsing of the events and the final result extraction). stderr still reaches the
  `.log` via launch.sh's own `2>&1`, so nothing is lost.
- Do NOT break the `CLAUDE_RESULT` / `SESSION_ID` / `CLAUDE_EXIT` contract. With
  stream-json those now come from the final `{"type":"result",…}` event, not a single
  top-level object. Everything downstream (Surface Deviations parse at ~line 282, the
  agent.md summary, session-failure detection at ~line 271) must keep working unchanged.
- Do NOT introduce a separate `.heartbeat` file. Reuse the `.log` mtime for the
  activity signal (decided in triage).
- Do NOT add any new runtime dependency. `jq` is already required; no python/node.
- Do NOT touch classification / state-machine logic in `lib.sh`.
- Do NOT use `--include-partial-messages`. One event per turn (tool_use batches) is
  enough granularity; partial messages add noise.

## Plan

### 1. Add a stream formatter helper in `execute-plan.sh`

Define a small function (place it just above `phase_run_session`) that reads NDJSON
events on stdin and prints one human-readable line per item to stdout. Use a single
`jq -r --unbuffered` filter so lines flush live:

- `type=="assistant"`: iterate `.message.content[]?` —
  - `text` block → `"  " + (.text | gsub("\n";" ") | .[0:100])` (truncated, one line)
  - `tool_use` block → `"→ " + .name + ": " + (.input.command // .input.file_path //
    .input.pattern // .input.path // "" | tostring | .[0:80])`
- `type=="result"` → `"✓ session complete"`
- everything else → `empty`

Wrap so a malformed line can't abort the whole stream (e.g. pipe through the jq filter
with `2>/dev/null`; if jq dies the raw tee below still preserves the data for parsing —
only the live digest stops, which is acceptable degradation).

### 2. Switch `phase_run_session` to streaming with a tee

Replace the `CLAUDE_OUTPUT=$(claude … --output-format json … 2>&1)` capture (lines
~251-259) with a pipeline that (a) streams a formatted digest to stdout live, (b) tees
the raw NDJSON to a temp file for parsing, and (c) keeps stderr separate:

```bash
local stream_raw stream_err
stream_raw="$(mktemp)"; stream_err="$(mktemp)"

claude -p \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
  --permission-mode bypassPermissions \
  --output-format stream-json --verbose \
  --max-turns 100 \
  --model sonnet \
  --max-budget-usd "${MAX_BUDGET}" \
  "${CLAUDE_PROMPT}" 2>"$stream_err" \
  | tee "$stream_raw" \
  | format_stream_events
CLAUDE_EXIT=${PIPESTATUS[0]}
```

Note `set -o pipefail` may be active — confirm `CLAUDE_EXIT` reflects claude's exit
(via `PIPESTATUS[0]`), not `tee`/jq. If `tee`/jq exit nonzero they must not mask a
successful claude run.

### 3. Re-derive `CLAUDE_RESULT` / `SESSION_ID` from the result event

Replace the `echo "${CLAUDE_OUTPUT}" | jq …` extraction (lines ~261-265) with reads of
the final `type=="result"` event from `$stream_raw`:

```bash
CLAUDE_RESULT=$(jq -r 'select(.type=="result") | .result // empty' "$stream_raw" 2>/dev/null | tail -1)
SESSION_ID=$(jq -r 'select(.type=="result") | .session_id // empty' "$stream_raw" 2>/dev/null | tail -1)
```

If `CLAUDE_RESULT` is empty (crash before a result event), fall back to the tail of
`$stream_err` so the agent.md summary still records something useful. The existing
session-failure check (`-z "$CLAUDE_RESULT" && -z "$SESSION_ID"` → failed) keeps working.
Clean up both temp files (`rm -f "$stream_raw" "$stream_err"`) before the function returns.

### 4. Point a running task's `age` at the `.log` mtime in `report.sh`

In `classify_slug`, the running branch (Rule 3, ~lines 88-90) currently sets
`age="$(age_of "$run_file")"`. Change it to prefer the run's `.log` file mtime so `age`
means "last activity", falling back to the run-record when the log is absent:

```bash
elif [[ -n "$run_file" ]] && run_is_alive "$run_file"; then
  phase="running"
  local logf="${TODO}/.running/${slug}.log"
  if [[ -f "$logf" ]]; then age="$(age_of "$logf")"; else age="$(age_of "$run_file")"; fi
```

### 5. Relabel the running-age display (small, same change)

`monitor.sh` and `status.sh` render the running task's `age`. Wherever the running
list currently labels that number as elapsed/running time, update the wording to "last
activity" / "last seen" so the now-activity-based value reads correctly. If the existing
output already shows a bare "Ns ago" with no misleading label, no change is needed —
just verify.

## Files to Modify

- `skills/todo-task/execute-plan.sh` — add `format_stream_events`; convert
  `phase_run_session` to streaming + tee; re-derive `CLAUDE_RESULT`/`SESSION_ID` from
  the result event; temp-file cleanup.
- `skills/todo-task/report.sh` — running-task `age` from `.log` mtime (Rule 3).
- `skills/todo-task/monitor.sh` — relabel running-age column to "last activity" if it
  currently implies elapsed time.
- `skills/todo-task/status.sh` — same relabel check for the running section.

## Verification

```bash
# 1. Syntax-check every modified script.
bash -n skills/todo-task/execute-plan.sh
bash -n skills/todo-task/report.sh
bash -n skills/todo-task/monitor.sh
bash -n skills/todo-task/status.sh

# 2. Exercise the formatter against a synthetic stream-json fixture.
#    Source the function out of execute-plan.sh, or copy format_stream_events into a
#    scratch file, then feed it representative events and assert the digest lines.
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the plan now"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/Foo.kt"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"./gradlew compileDebug"}}]}}' \
  '{"type":"result","subtype":"success","result":"done","session_id":"abc123"}' \
  | jq -r --unbuffered '
      if .type=="assistant" then
        (.message.content[]? |
          if .type=="text" then "  " + (.text|gsub("\n";" ")|.[0:100])
          elif .type=="tool_use" then "→ " + .name + ": " +
            (.input.command // .input.file_path // .input.pattern // .input.path // "" | tostring | .[0:80])
          else empty end)
      elif .type=="result" then "✓ session complete"
      else empty end'
# Expect:
#   Reading the plan now
#   → Edit: src/Foo.kt
#   → Bash: ./gradlew compileDebug
#   ✓ session complete

# 3. Confirm result/session extraction picks the final result event.
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}' \
  '{"type":"result","subtype":"success","result":"SUMMARY TEXT","session_id":"sess-9"}' \
  > /tmp/streamfix.jsonl
test "$(jq -r 'select(.type=="result") | .result // empty' /tmp/streamfix.jsonl | tail -1)" = "SUMMARY TEXT"
test "$(jq -r 'select(.type=="result") | .session_id // empty' /tmp/streamfix.jsonl | tail -1)" = "sess-9"

# 4. report.sh still emits well-formed TSV after the age change.
bash skills/todo-task/report.sh task
```

## Out of Scope

- Part 2 of the original draft: renaming/removing the user-facing "no-op" label. Left in
  the inbox draft `feedback-headless-run-invisible-progress.md`.
- Streaming the two retry-loop `claude` calls.
- Any change to classification or the agent.md/merge.md result model.
- A standalone heartbeat file or new run-record fields.

## Notes

- `--verbose` is required for realtime streaming with `--print` + `stream-json`
  (per `claude --help`). Without it the stream is suppressed.
- The biggest risk is the stderr/stdout split: if claude's stderr leaks into the
  NDJSON pipe, both the live digest and the final result/session parse can break.
  Keep `2>"$stream_err"` strictly separate from the piped stdout.
- A real end-to-end test would require launching an actual headless agent, which the
  verification above deliberately avoids — it validates the parsing/formatting seams
  (where the bugs live) with fixtures instead.
- Reviewer watch-point: confirm `PIPESTATUS[0]` (not `$?`) is used for `CLAUDE_EXIT`,
  since the claude command is now mid-pipeline.
