# Agent Result: feedback-surface-deviation-misclassified-as-failure

date: 2026-06-16T21:02:55-04:00
session: completed
verification: passed
commits: 1
branch: main_claude_feedback-surface-deviation-misclassified-as-failure
surface deviations: none
session id: 1ca130bd-4521-43b0-9673-683c5d71af81


## Summary

All verification passes and the commit is in place.

## Implementation Summary

Added `surface_deviation_state()` helper to `skills/todo-task/lib.sh` (after `parse_result_field`, ~line 135) and updated `skills/todo-task/execute-plan.sh` to call it instead of the inline equality check.

**Changes made:**
- `lib.sh`: Added `surface_deviation_state <body>` that extracts the first non-blank line, strips whitespace, and matches `^[Nn]one([[:punct:][:space:]].*)?$` — so `None.`, `None`, `None. The plan had no declared Surface block.`, and `none — nothing diverged` all return `none`, while `Nonexistent...` still returns `declared`.
- `execute-plan.sh`: Replaced the 6-line inline if-block (including the `| sed ... | grep -v '^$'` filter) with two lines: the awk extraction (unchanged in behavior) and `SURFACE_DEVIATIONS="$(surface_deviation_state "$dev_body")"`.

## Notes

The sed/grep trim that was on the awk pipe (line 286) moved into the helper's first-line normalization. The extraction itself is unchanged — no behavior change, just the trim happened earlier in the pipeline before, now happens inside the helper on the first line only. This is consistent with what the plan described.

## Surface Deviations

None.

## Commits

```
24f7441 fix: surface deviations false-positive when agent writes "None." with explanation
```

## Build & Test Output (last 30 lines)

```
ok:   [None.] -> none
ok:   [None] -> none
ok:   [None. The plan had no declared Surface block.] -> none
ok:   [] -> none
ok:   [none — nothing diverged] -> none
ok:   [Renamed getFoo to fetchFoo; callers updated.] -> declared
ok:   [Nonexistent enum removed, broke MapScreen — fixed it.] -> declared
```
