# Fix false-positive "surface deviations declared" when agent writes "None." + explanation

## Motivation

The original report (`feedback-surface-deviation-misclassified-as-failure`) described a
clean, merged agent run being classified as `build_failure`, skipped by auto-archive, and
shown with a `Surface Deviations: declared` header that contradicted a body saying "None."

Research found the **classification half is already fixed** by the `agent.md`/`merge.md`
refactor: `classify_task` → `derive_overall_state` (`skills/todo-task/lib.sh:46-69,279-298`)
now derives overall state solely from `session`/`verification`/`merge`. A surface deviation
no longer causes `build_failure`, no longer blocks `archive.sh` (which keys on
`overall == success`, `archive.sh:106`), and only appends an informational note in
`report.sh:116`. The proposed `success-with-deviations` state is unnecessary.

What remains is the **false-positive detector** in `skills/todo-task/execute-plan.sh:287`:

```bash
if [[ -z "$dev_body" || "$dev_body" == "None." || "$dev_body" == "None" ]]; then
```

This treats the section as "no deviation" only when the body is *exactly* `None.` (or
`None`). The agent is instructed to write `None.` but routinely appends an explanation
("None. The plan had no declared Surface block."), so `dev_body` is non-empty and unequal,
and the run is flagged `declared`. That spurious note is now harmless to classification but
still misleading — and is the one part of the report that still reproduces.

## Do NOT

- Do NOT touch classification (`lib.sh` `derive_overall_state` / `classify_task`),
  `report.sh`, `archive.sh`, or introduce a `success-with-deviations` state. Those concerns
  from the original draft are already resolved; this task is the parser only.
- Do NOT change the agent prompt instructions in `execute-plan.sh` (the "write '## Surface
  Deviations' followed by 'None.'" guidance, lines ~247-249) — keep accepting what the agent
  already produces.
- Do NOT change the awk extraction (lines 282-286 / 283-285) that slices out the section
  body. Only the None-vs-declared decision changes.
- Do NOT match "None" as a bare substring — a real deviation like "Nonexistent enum removed,
  broke MapScreen" must still classify as `declared`. Match the leading **word** "None".
- Do NOT edit the installed copies under `.claude/skills/todo-task/` — they are gitignored;
  the tracked source of truth is `skills/todo-task/`.

## Plan

### 1. Add a pure, testable helper to `skills/todo-task/lib.sh`

Add a small function (near the other parse helpers, e.g. just after `parse_result_field`,
~line 133). It takes the already-extracted Surface Deviations section body and returns
`none` or `declared`:

```bash
# surface_deviation_state <deviations-section-body>
# Classifies the extracted "## Surface Deviations" section body. The agent is told
# to write "None." when nothing deviated, but frequently appends an explanation
# ("None. The plan had no declared Surface block."), so the decision keys on the
# leading "None" word, not whole-body equality. A non-None first line ⇒ declared.
surface_deviation_state() {
  local body="$1" first
  first=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -n1 \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z "$first" || "$first" =~ ^[Nn]one([[:punct:][:space:]].*)?$ ]]; then
    echo "none"
  else
    echo "declared"
  fi
}
```

The regex `^[Nn]one([[:punct:][:space:]].*)?$` matches `None`, `None.`,
`None. <anything>`, `none ...` — but not `Nonexistent...` (the char after "None" must be
punctuation, whitespace, or end-of-string).

### 2. Call the helper from `skills/todo-task/execute-plan.sh`

Replace the inline `if [[ ... ]]` block (lines 287-291). Keep the awk extraction (282-286)
unchanged; the only behavioral change is the None-detection. `execute-plan.sh` already
sources `lib.sh`, so the helper is in scope.

```bash
  local dev_body
  dev_body=$(echo "$CLAUDE_RESULT" | awk '
    /^## Surface Deviations[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ')
  SURFACE_DEVIATIONS="$(surface_deviation_state "$dev_body")"
```

(The `| sed ... | grep -v '^$'` trailing filter on line 286 moves into the helper's
first-line normalization, so drop it from the extraction.)

## Files to Modify

- `skills/todo-task/lib.sh` — add `surface_deviation_state` helper after `parse_result_field`.
- `skills/todo-task/execute-plan.sh` — replace the inline None-check (lines 287-291) with a
  call to `surface_deviation_state`; trim the now-redundant sed/grep filter on line 286.

## Verification

```bash
# Helper classifies leading "None" (with or without trailing explanation) as none,
# and real deviations as declared — including ones whose first word starts with "None".
source skills/todo-task/lib.sh
fail=0
check() {
  local got; got="$(surface_deviation_state "$2")"
  if [[ "$got" == "$1" ]]; then echo "ok:   [$2] -> $got"
  else echo "FAIL: [$2] expected $1 got $got"; fail=1; fi
}
check none "None."
check none "None"
check none "None. The plan had no declared Surface block."
check none ""
check none "none — nothing diverged"
check declared "Renamed getFoo to fetchFoo; callers updated."
check declared "Nonexistent enum removed, broke MapScreen — fixed it."

# Both modified scripts must still parse.
bash -n skills/todo-task/lib.sh
bash -n skills/todo-task/execute-plan.sh

exit $fail
```

## Out of Scope

- Streaming/heartbeat progress visibility (separate draft
  `feedback-headless-run-invisible-progress`).
- Any change to how the deviation note is worded or surfaced in `report.sh`/`status.sh`.
- Reconciling old already-archived result files.

## Notes

- The helper relocation is the parser fix, not scope creep: it keeps the exact awk
  extraction but moves the None decision somewhere a bash assertion can exercise it (the
  parser was previously buried inside `phase_session` and untestable). Verification depends
  on this.
- After this lands, syncing into a project via the install/update script propagates it to
  `.claude/skills/todo-task/`. The repo deliverable is the `skills/todo-task/` source only.
- Risk: the regex must not over-match. The "Nonexistent..." test case guards the most likely
  real-world false-negative.
