# Raise shipped budget/turn defaults so viable sessions survive the last mile

## Motivation

The shipped defaults (`MAX_TURNS=100`, `MAX_BUDGET=5.00`, `RETRY_BUDGET=3.00`)
are sized for small fix tasks. A larger phase — the kind chains exist for —
routinely finishes its implementation and commits cleanly, then spends its
remaining budget debugging a verification failure and dies at the cap during
the last mile, stranding a complete, committed implementation in the worktree.
Doubling the caps gives those larger sessions room to finish without materially
raising the ceiling on small runs (which finish well under the old caps anyway).

This task is ONLY the defaults change. The separate `commits: 0` misreport on
budget-death is tracked as its own investigation and is out of scope here.

## Do NOT

- Do NOT touch `MAX_RETRIES` (stays `4`).
- Do NOT change any classification, reporting, or state-machine code — this is a
  pure constants change in two files.
- Do NOT alter `source_task_config`'s resolution order or its structure — only
  the default *values* on the `MAX_TURNS` / `MAX_BUDGET` / `RETRY_BUDGET` lines.
- Do NOT edit `.claude/skills/…` (gitignored, absent from the worktree). Edit the
  tracked template under `skills/todo-task/…`.

## Plan

### 1. `skills/todo-task/lib.sh` — bump the fallback defaults

In `source_task_config` (the `${VAR:-default}` fallbacks, currently around lines
205-208), change:

- `MAX_BUDGET="${MAX_BUDGET:-5.00}"`   → `MAX_BUDGET="${MAX_BUDGET:-10.00}"`
- `RETRY_BUDGET="${RETRY_BUDGET:-3.00}"` → `RETRY_BUDGET="${RETRY_BUDGET:-6.00}"`
- `MAX_TURNS="${MAX_TURNS:-100}"`      → `MAX_TURNS="${MAX_TURNS:-200}"`

Leave `MAX_RETRIES="${MAX_RETRIES:-4}"` unchanged.

### 2. `skills/todo-task/task-config.template.sh` — bump the template values

This is the file copied into a project as `.todo-tasks/task-config.sh` on install,
so its literal values are what a new project inherits. Change:

- `MAX_BUDGET="5.00"`   → `MAX_BUDGET="10.00"`
- `RETRY_BUDGET="3.00"` → `RETRY_BUDGET="6.00"`
- `MAX_TURNS=100`       → `MAX_TURNS=200`

Leave `MAX_RETRIES=4` unchanged. Keep the surrounding comments accurate (they
describe the fields, not the numbers, so no comment edits should be needed).

## Files to Modify

- `skills/todo-task/lib.sh` — bump the three `${VAR:-default}` fallbacks in `source_task_config`.
- `skills/todo-task/task-config.template.sh` — bump the three literal values.

## Verification

```bash
# Both files still parse.
bash -n skills/todo-task/lib.sh && echo "lib.sh OK"
bash -n skills/todo-task/task-config.template.sh && echo "template OK"

# New defaults are present in lib.sh fallbacks.
grep -q 'MAX_BUDGET:-10.00' skills/todo-task/lib.sh && echo "lib MAX_BUDGET OK"
grep -q 'RETRY_BUDGET:-6.00' skills/todo-task/lib.sh && echo "lib RETRY_BUDGET OK"
grep -q 'MAX_TURNS:-200' skills/todo-task/lib.sh && echo "lib MAX_TURNS OK"

# Template literals updated.
grep -q 'MAX_BUDGET="10.00"' skills/todo-task/task-config.template.sh && echo "tmpl MAX_BUDGET OK"
grep -q 'RETRY_BUDGET="6.00"' skills/todo-task/task-config.template.sh && echo "tmpl RETRY_BUDGET OK"
grep -q 'MAX_TURNS=200' skills/todo-task/task-config.template.sh && echo "tmpl MAX_TURNS OK"

# MAX_RETRIES untouched.
grep -q 'MAX_RETRIES:-4' skills/todo-task/lib.sh && echo "MAX_RETRIES unchanged OK"
```

## Out of Scope

- The `commits: 0` misreport on budget/turn death — its own investigation task.
- Any change to `execute-plan.sh` retry/session logic.
- Existing installed `.todo-tasks/task-config.sh` in any project (never overwritten
  on update; users bump their own if they want the new caps).

## Notes

- A project that already has `.todo-tasks/task-config.sh` keeps its own values —
  the template change only affects fresh installs. The `lib.sh` fallbacks are the
  safety net for a project whose config omits a field, so both must move together.
