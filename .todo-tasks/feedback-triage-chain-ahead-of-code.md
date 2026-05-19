# Codify the "Surface after this phase" contract into the todo-task skill

## Motivation

Triaging a spec chain ahead of its code progress was a hunch; it was implemented
and validated end-to-end against a real 6-phase epic (`packs-as-data`, phases
01→06 in the Luminous repo). The workflow held: downstream phases were triaged
against each predecessor's *declared output surface* instead of live code, and the
chain ran without a contract mismatch forcing a stop.

But the validation lives only in the user's head and in archived Luminous specs.
Nothing in the todo-task skill or scripts mentions a Surface, a contract, or
deviation-flagging — confirmed by grep across `SKILL.md`, `execute-plan.sh`,
`lib.sh`, and `status.sh`. This task makes the validated workflow a first-class
part of the system so future chains use it without the user hand-rolling it, and
closes the one open edge from the feedback note: **deviation-flagging in result
reports**.

The validated contract has three rules:
- Downstream phases triage against the **Surface, not the code** — the Surface
  stands in for code that does not exist yet.
- **If it is not in the Surface, it does not exist** for triage purposes.
- The **negative-space line** ("still exist / still work / not changed") is also a
  contract — it tells later phases what they can still rely on.

At execution, the agent must make reality match the declared Surface or halt, and
must report any deviation so only affected downstream specs need re-triage.

## Do NOT

- Do NOT edit the installed copy at `.claude/skills/todo-task/`. Per CLAUDE.md, the
  repo source of truth is `skills/todo-task/` — modify only that.
- Do NOT make the `## Surface after this phase` block mandatory for standalone
  one-off tasks. It is required only for chain/epic phases (a spec that is part of
  a chain, or has an `{epic}-` prefix). One-off tasks omit it.
- Do NOT make a declared Surface deviation block the auto-merge or fail the task.
  Deviations are a **soft flag** — surfaced loudly in the result file and status
  output, but the merge still proceeds when build/tests pass. Treat it like the
  existing "Retried" flag, not like a verification failure.
- Do NOT try to machine-diff the declared Surface against the implementation. The
  Surface is prose. Detection relies on the agent self-reporting in a dedicated
  result section; the runner only checks whether that section is non-empty.
- Do NOT change the result-file vocabulary constants (`SM_*`) or the buckets in
  `status.sh`. The deviation flag is an additive note, not a new state.
- Do NOT break the existing positional call sites of `write_result_file`. There
  are two (`execute-plan.sh:82` emergency finalizer, `execute-plan.sh:413` normal
  finalize) — both must be updated to pass the new argument.

## Plan

### 1. Teach the contract in `skills/todo-task/SKILL.md` — triage mode

Reference example of the validated format (read it before writing the template):
`../Luminous/.todo-tasks/.archived/20260518-packs-as-data-02c-wire-interpreter.md`.
Its `## Surface after this phase` block is a bullet list of the symbols, files, and
behaviors the phase promises to leave behind, ending with negative-space lines
("Legacy X still exists and still works").

Make three edits to the `## Mode: triage` section:

**a. Step 3 ("Research the codebase").** Add a paragraph: when triaging a spec that
is part of a chain or epic and whose predecessor phases have not merged yet, do not
research live code for the predecessor's output — read the predecessor spec's
`## Surface after this phase` block and triage against that. The Surface stands in
for code that does not exist yet. If it is not in the Surface, treat it as not
existing.

**b. Step 6 (the executable-spec template).** Add a new section to the template,
placed at the very bottom, after `## Notes`:

````markdown
## Surface after this phase

> Required for chain/epic phases. Omit for standalone one-off tasks.

- {Symbols this phase promises to leave behind — exported functions, types,
  files — stated precisely enough that a later phase can triage against them.}
- {Behaviors / integration points the phase guarantees.}
- {Negative space: what is deliberately unchanged and can still be relied on —
  e.g. "Legacy X still exists and still works until Phase N".}
````

Also add a sentence to the prose right before/after the template noting that the
Surface block is the contract downstream phases triage against.

**c. Triaging Guidelines.** Add bullets capturing the three validated rules:
triage downstream phases against the Surface not the code; if it is not in the
Surface it does not exist; the negative-space line is also a contract.

### 2. Hold the execution agent to the Surface — `skills/todo-task/execute-plan.sh`

In `phase_run_session`, extend `CLAUDE_PROMPT` (around lines 199-209):

- Add an instruction: if the plan contains a `## Surface after this phase` section,
  the agent must make the implementation match that declared Surface exactly, or
  halt and explain why it cannot. The Surface is a contract that later phases of
  the chain depend on.
- Add to the required closing output: after `## Notes`, the agent must also end
  with a `## Surface Deviations` section listing any way the implementation
  diverged from the declared Surface (a missing/renamed symbol, a changed
  signature, a behavior that differs). If there were no deviations, or the plan had
  no Surface block, the agent writes `## Surface Deviations` followed by `None.`

### 3. Detect and record the deviation flag — `execute-plan.sh` + `lib.sh`

**In `execute-plan.sh`:** after `CLAUDE_RESULT` is populated in `phase_run_session`,
derive a `SURFACE_DEVIATIONS` variable. Parse the body of the `## Surface
Deviations` section out of `CLAUDE_RESULT` (awk: lines after `## Surface
Deviations` up to the next `## ` heading or EOF). If that body, trimmed, is empty
or exactly `None.`/`None`, set `SURFACE_DEVIATIONS="none"`; otherwise set it to
`"declared"`. Initialize it to `"none"` so the failed-session branch in `main()`
and the emergency finalizer have a defined value.

**In `lib.sh`:** add a new trailing positional parameter `surface_deviations` to
`write_result_file` (param 15, after `error_detail`). Update the usage comment
block (lines 73-76). In the result template, add a header field after
`**Retried**`:

```
**Surface Deviations**: ${surface_deviations}
```

The agent's own `## Surface Deviations` prose already lands inside `## Claude
Summary` via `claude_result` — the header field is the machine-readable flag, the
prose is the detail. Do not add a separate body section.

**Update both call sites** in `execute-plan.sh`:
- `phase_finalize` (line 413) — pass `"${SURFACE_DEVIATIONS:-none}"`.
- `emergency_finalize` (line 82) — pass `"none"` (no agent output to parse).

### 4. Surface the flag in `skills/todo-task/status.sh`

In the `.done/` result loop (around lines 70-94), after `retried` is parsed, add:

```bash
surface_dev=$(parse_result_field "$result" "surface deviations")
```

(`parse_result_field` lowercases keys/values and handles the `**bold**` form, so
`**Surface Deviations**:` is found via `surface deviations`.)

When `surface_dev` is `declared`, prepend a marker to `notes`, e.g.
`"Surface deviations declared — re-triage downstream. "`. This must show for
**successful** runs too, not only the attention bucket — a deviation on a green run
is exactly the case the feedback note cares about. Place the marker alongside the
existing `"Retried. "` prefix logic so it appears regardless of bucket.

## Files to Modify

- `skills/todo-task/SKILL.md` — triage Step 3 (Surface-aware research), Step 6
  (Surface template section), Triaging Guidelines (three rules).
- `skills/todo-task/execute-plan.sh` — `CLAUDE_PROMPT` (Surface instruction +
  `## Surface Deviations` closing section); `SURFACE_DEVIATIONS` detection;
  defaulting in `main()`'s failed-session branch; both `write_result_file` calls.
- `skills/todo-task/lib.sh` — `write_result_file` new param, usage comment,
  `**Surface Deviations**` header field.
- `skills/todo-task/status.sh` — parse `surface deviations` field, add note marker
  for `declared`.

## Verification

```bash
# All scripts still parse
bash -n skills/todo-task/execute-plan.sh
bash -n skills/todo-task/lib.sh
bash -n skills/todo-task/status.sh

# write_result_file emits the new field and accepts the new arg
# Note: subshell keeps the cd from changing outer CWD; source uses worktree-relative path;
# trunk arg ("unchanged") is at position 15, surface_deviations ("declared") at position 16.
REPO_ROOT="$(pwd)"
(cd "$(mktemp -d)" && \
  source "${REPO_ROOT}/skills/todo-task/lib.sh" && \
  write_result_file ./r.md slug completed passed clean \
    2 "abc def" feat/x /tmp/wt false sess-1 "summary" "build ok" "" unchanged declared && \
  grep -q '^\*\*Surface Deviations\*\*: declared' ./r.md && echo "PASS: field written" && \
  grep -c 'Surface Deviations' ./r.md)

# SKILL.md teaches the contract
grep -q 'Surface after this phase' skills/todo-task/SKILL.md && echo "PASS: SKILL template"
grep -qi 'Surface, not the code' skills/todo-task/SKILL.md && echo "PASS: SKILL rule"

# execute-plan.sh prompts for the deviations section
grep -q 'Surface Deviations' skills/todo-task/execute-plan.sh && echo "PASS: prompt"

# status.sh reads the flag
grep -q 'surface deviations' skills/todo-task/status.sh && echo "PASS: status parse"
```

## Out of Scope

- Machine-validating a declared Surface against the implementation. Detection is
  agent self-report only.
- Auto-re-triaging downstream specs when a deviation is flagged. The system
  surfaces the flag; the user decides what to re-triage.
- Backfilling `## Surface after this phase` blocks into existing pending specs.
- Any change to chain orchestration (`launch-chain.sh`, `execute-chain.sh`) — the
  contract is authored at triage and checked at single-plan execution; chaining is
  unaffected.

## Notes

- The feedback note flagged deviation-flagging as the one untested edge. This task
  builds the plumbing (prompt → result field → status note) but, like the epic
  that never hit a mismatch, the `declared` path will only be truly exercised when
  a real chain deviates. The verification above tests the mechanism, not a live
  deviation.
- `parse_result_field` returns values lowercased — `status.sh` must compare
  against `declared` / `none` in lowercase.
- The reference spec in `../Luminous/` is in a sibling repo. It is a read-only
  example to model the template after; do not modify anything outside this repo.
- Keep the SKILL.md additions concise — headless agents read it; verbose triage
  instructions dilute the negative constraints.

## Surface after this phase

> This task is standalone (not a chain phase), so no downstream spec triages
> against it. Block included only to model the format the implementing agent must
> add to `SKILL.md`.
