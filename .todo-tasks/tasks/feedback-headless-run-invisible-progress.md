# Strip "no-op" from user-facing output — say "no changes"

## Motivation

"No-op" is engineer-shorthand from the script's point of view ("this branch
produces zero diff against trunk"). Surfaced to a human as the *outcome label* in
the dashboard, it reads as a dismissal a non-engineer cannot decode. The internal
state id stays `no_op`; only the rendered label changes to something a non-engineer
reads correctly for "the agent ran and produced no commits": **no changes**.

This is a renderer-only change. Classification and the state-machine vocabulary in
`lib.sh` are untouched.

## Do NOT

- Do NOT rename or remove `SM_OVERALL_NOOP` or change its value (`no_op`) in
  `skills/todo-task/lib.sh` — it stays the internal state id, and archived records,
  logs, and commit messages may still use it.
- Do NOT change `state_bucket`, `classify_task`, `derive_overall_state`, or any
  classification path. The `no_op` state still buckets as `questionable`.
- Do NOT touch the `Summary:` line's bucket counts (they name buckets, e.g.
  "questionable", not the `no_op` state).
- Do NOT edit `.claude/skills/…`. Edit the tracked `skills/todo-task/…` copies.

## Plan

### 1. `skills/todo-task/monitor.sh` — friendly label in the display map

`overall_label()` (around line 96-108) maps state ids to display strings. Change
the `no_op` case only:

```bash
    "$SM_OVERALL_NOOP")         echo "no changes" ;;
```

Leave `overall_color()`'s `no_op` case (yellow) as-is.

### 2. `skills/todo-task/status.sh` — friendly label where the raw state prints

`status.sh` prints the raw `${overall}` state id in two spots: the `render_bucket`
row (around line 90) and the Crashed Agents table (around line 113). For a
`no_op` task these show the literal `no_op`. Translate `no_op` → `no changes` at
render time WITHOUT changing any other state's rendered text.

The minimal, local way: before printing the row, substitute just the no-op id.
For example in `render_bucket`, after `IFS='|' read -r slug overall commits notes`:

```bash
    local disp="$overall"
    [[ "$overall" == "$SM_OVERALL_NOOP" ]] && disp="no changes"
```

then print `${disp}` in the State column. Apply the same one-line substitution in
the Crashed Agents loop. Every other state (`build_failure`, `session_failed`,
`merge_conflict`, `success`, …) must render exactly as it does today.

## Files to Modify

- `skills/todo-task/monitor.sh` — `overall_label()` `no_op` case → "no changes".
- `skills/todo-task/status.sh` — substitute `no_op` → "no changes" at the two raw-state print sites; leave all other states unchanged.

## Verification

```bash
# Both renderers still parse.
bash -n skills/todo-task/monitor.sh && echo "monitor OK"
bash -n skills/todo-task/status.sh && echo "status OK"

# The friendly label is present in both renderers.
grep -q 'no changes' skills/todo-task/monitor.sh && echo "monitor label OK"
grep -q 'no changes' skills/todo-task/status.sh && echo "status label OK"

# The internal state id is untouched in lib.sh.
grep -q 'SM_OVERALL_NOOP="no_op"' skills/todo-task/lib.sh && echo "state id unchanged OK"

# The old user-facing "no-op" string is gone from the monitor display map line.
! grep -q 'echo "no-op"' skills/todo-task/monitor.sh && echo "old monitor label removed OK"
```

## Out of Scope

- Any change to classification, buckets, or the state-machine vocabulary.
- The genuine-vs-fixed no-op *classification* concern (already fixed upstream —
  a clean auto-merge no longer misclassifies as no_op). This task is wording only.
- Renaming the "questionable" bucket.

## Notes

- Wording choice: "no changes" over "empty" — it reads as a plain description of
  the outcome ("the agent ran and changed nothing") rather than a container state.
- Keep the substitution local so a future reader sees exactly which state is
  relabeled and why, without a shared indirection that could drift.
