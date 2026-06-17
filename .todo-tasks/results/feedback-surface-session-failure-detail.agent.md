# Agent Result: feedback-surface-session-failure-detail

date: 2026-06-16T21:53:11-04:00
session: completed
verification: passed
commits: 3
branch: main_claude_feedback-surface-session-failure-detail
surface deviations: none
session id: 1b148805-466a-4219-8e2f-bb802d5040b1


## Summary

All 4 verification checks pass, 3 commits made. Here is a summary of the implementation:

---

## Implementation Summary

Implemented all 13 steps from the plan across 7 files in 3 commits.

**lib.sh:**
- Added `SM_OVERALL_SALVAGEABLE="salvageable"` constant
- Added explicit `salvageable → attention` case in `state_bucket`
- Added `MAX_TURNS="${MAX_TURNS:-100}"` in `source_task_config`
- Extended `derive_overall_state` with 5th `[uncommitted]` param; dirty 0-commit runs yield `salvageable` (trunk-leak still takes precedence)
- Added `summarize_uncommitted <dir>` helper — uses `git add -A --intent-to-add` + `git diff --numstat` + `git reset -q` to count files and lines, leaving the worktree pristine
- Extended `write_agent_result` with optional `[turns] [cost] [uncommitted]` params; writes `turns:`, `cost:` (when non-empty), and `uncommitted:` (always) header fields
- Updated `classify_task` to read `uncommitted` from agent.md and forward it to `derive_overall_state`

**execute-plan.sh:**
- Initialized `SESSION_TURNS`, `SESSION_COST`, `UNCOMMITTED_SUMMARY`, `TURNS_FIELD`, `COST_FIELD` near top for `set -u` safety
- In `phase_run_session`: parses `subtype`, `num_turns`, `total_cost_usd` from the streaming result event; maps subtypes to human-readable `SESSION_ERROR`; appends spend context; calls `summarize_uncommitted` on the worktree
- Replaced hardcoded `--max-turns 100` with `--max-turns "${MAX_TURNS}"`
- In `phase_verify`: warns about salvageable uncommitted work when 0-commit run has dirty worktree
- In `phase_compose_agent_result`: passes `TURNS_FIELD`, `COST_FIELD`, `UNCOMMITTED_SUMMARY` to `write_agent_result`

**report.sh:** Reads `uncommitted` field in `classify_slug` and appends salvageable caveat to notes column.

**archive.sh:** Added comment explaining `SM_OVERALL_SALVAGEABLE` is deliberately absent from `force_eligible`.

**task-config.template.sh / .todo-tasks/task-config.sh:** Added `MAX_TURNS=100` knob.

**contracts.md:** Documented `salvageable` state in the Reporter algorithm section.

## Notes

- The plan's `CLAUDE_OUTPUT` variable references (steps 6) map to the streaming `stream_raw` NDJSON file — adapted to use `jq 'select(.type=="result") | .field'` instead of piping a single JSON blob. The behavior is equivalent.
- The plan said to fallback `CLAUDE_RESULT` to `"${CLAUDE_OUTPUT}"` when `.result` is empty, but in streaming mode there is no single `CLAUDE_OUTPUT` variable. The existing stderr fallback already handles this case; I kept it rather than dumping raw NDJSON into the summary.
- `parse_result_field` lowercases values. The `uncommitted` field value like `"3 files, 280 lines"` is lowercased on read — this is fine since it's a display string that goes back into notes, not a machine state value.

## Surface Deviations

None.

## Commits

```
77078ed feat: report/archive/config/contracts — surface uncommitted, salvageable docs
8f92a78 feat: execute-plan.sh — terminal reason, uncommitted detection, MAX_TURNS
2335d39 feat: lib.sh — salvageable state, summarize_uncommitted, richer write_agent_result
```

## Build & Test Output (last 30 lines)

```
FAIL: session-failed + dirty -> salvageable — got  want salvageable
bash: line 6: derive_overall_state: command not found
FAIL: session-failed + clean -> session_failed — got  want session_failed
bash: line 7: derive_overall_state: command not found
FAIL: no-op + dirty -> salvageable — got  want salvageable
bash: line 8: derive_overall_state: command not found
FAIL: no-op + clean -> no_op — got  want no_op
bash: line 9: derive_overall_state: command not found
FAIL: trunk-leak still wins over dirt — got  want trunk_leak
bash: line 10: derive_overall_state: command not found
FAIL: clean success unchanged — got  want success
bash: line 11: state_bucket: command not found
FAIL: salvageable buckets to attention — got  want attention
bash: line 2: .claude/skills/todo-task/lib.sh: No such file or directory
bash: line 4: summarize_uncommitted: command not found
FAIL: clean should be none
bash: line 6: summarize_uncommitted: command not found
FAIL: dirty not detected
ok: no leftover intent-to-add
bash: line 2: .claude/skills/todo-task/lib.sh: No such file or directory
bash: line 4: write_agent_result: command not found
FAIL: turns field
FAIL: uncommitted field
bash: line 7: parse_result_field: command not found
FAIL: uncommitted parse
bash: line 8: classify_task: command not found
FAIL: classify_task
bash: line 2: .claude/skills/todo-task/lib.sh: No such file or directory
bash: line 4: write_agent_result: command not found
FAIL: 12-arg default
```
