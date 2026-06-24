# Route chains through the classifier; renderers consume state + progress verbatim

## Motivation

Phase 1 added the pure chain state machine to `lib.sh` but wired nothing. This phase makes
`report.sh:emit_chains` a thin fact-gatherer that calls `derive_chain_state`, and emits a
ready-made `progress` field via `chain_progress`. `status.sh` and `monitor.sh` then print
state + progress **verbatim** and stop computing `done_n+1` — which structurally fixes the
impossible `5/4` (the clamp lives in `chain_progress`) and renders the new `finalizable`
state instead of a phantom `failed`.

This is Phase 2 of the `chain-state-machine` epic. **Triage against Phase 1's declared
Surface, not live `lib.sh`** — Phase 1 has not merged. The following are guaranteed to
exist (from Phase 1's Surface):

- `SM_CHAIN_RUNNING/WAITING/AWAITING_MERGE/CONFLICT/FINALIZABLE/COMPLETE/FAILED`
- `derive_chain_state <alive> <done_n> <total> <merge_state> <waiting_unsatisfied> <merged_on_trunk>` → one `SM_CHAIN_*`
- `chain_progress <state> <done_n> <total>` → print-ready, never overflows
- `chain_state_bucket <state>` → `SM_BUCKET_*`
- `chain_merged_on_trunk <repo_root> <phases_csv>` → 0 iff all phases on trunk HEAD

If a symbol is not in that list, treat it as nonexistent.

## Do NOT

- Do NOT recompute chain status or progress in `status.sh` / `monitor.sh`. They become
  dumb consumers: read the emitted `cstatus` and `progress` fields and print them. Delete
  every `$(( done_n + 1 ))` used for *progress display*.
- Do NOT re-derive state with inline `if run_is_alive / merge_state` logic in `emit_chains`
  — gather the raw facts and call `derive_chain_state`.
- Do NOT change Phase 1's function signatures or the `lib.sh` enum. Consume them as-is.
- Do NOT break the existing TSV consumers silently — `status.sh`, `monitor.sh`, and
  `archive.sh` all parse the chain record positionally. If you add the `progress` column,
  update **every** reader in the same phase.
- Do NOT add `progress` anywhere but the end of the chain record (append), so the existing
  leading columns keep their positions.
- The `done_n + 1` used to pick which phases to list as *queued/upcoming*
  (`monitor.sh:388`, `status.sh` upcoming loop) is a different concern from progress
  display — keep that logic, but only run it for `running`/`waiting` states.

## Plan

### 1. `report.sh:emit_chains` — gather facts, call the classifier (lines ~170-211)

Replace the inline status logic (`:193-207`) with fact-gathering + one call:

- `alive` = `run_is_alive "$run"` → "true"/"false".
- `done_n`/`total` already computed (`:183-191`) — keep.
- `merge_state` = `read_run_field "$run" merge_state`.
- `waiting_unsatisfied` = the existing `waiting_for` check (`:194`) reduced to a boolean.
- `merged_on_trunk` = `chain_merged_on_trunk "$REPO_ROOT" "$phases"`.
- `status="$(derive_chain_state "$alive" "$done_n" "$total" "$merge_state" "$waiting_unsatisfied" "$merged_on_trunk")"`.
- `progress="$(chain_progress "$status" "$done_n" "$total")"`.

For the `waiting` case, keep setting `current="after ${waiting_for}"` as today.

Append `progress` as the final field of the chain record. Update the `printf` and the
**format-doc comment at the top of `report.sh` (~line 13)** to:
`chain <name> <status> <done_n> <total> <current> <phases_csv> <worktree> <branch> <progress>`.

### 2. Completed-chain (definition) loop (`report.sh:213-221`)

Keep emitting `complete` from the trunk-definition loop. Emit its `progress` too —
`chain_progress complete "$total" "$total"` → `"${total}/${total}"`. Append the field so
the record shape matches the live loop.

### 3. `status.sh` — consume verbatim (chain block, lines ~128-166)

- Update the chain-record read to include the trailing `progress` field.
- Replace the `case "$cstatus"` progress phrasing (`:136-141`) entirely: print the emitted
  `progress` string directly. No `done_n+1`.
- Render the new states: `awaiting-merge` and `finalizable` show the exact
  `git merge --squash` / finalize hint and do **not** set `HAS_ATTENTION`; `conflict` and
  `failed` do. Drive the attention decision from `chain_state_bucket` (== `attention`)
  rather than a hardcoded `[[ "$cstatus" == "failed" ]]` (`:163`).
- For `finalizable`, print a one-liner pointing at Phase 3's finalize step
  (e.g. "merged out-of-band — run finalize-chain to clear"). Until Phase 3 lands the
  script, the wording can name the command; it is informational.

### 4. `monitor.sh` — consume verbatim (active block ~359-393 and `render_chains` ~420-435)

- Update both chain-record reads to include `progress`.
- Replace every `$(( done_n + 1 ))/$total` progress print with the emitted `progress`
  string, in both the `running` and `failed` arms (this is the literal `5/4` site:
  `monitor.sh:369,373,432`).
- Add/adjust `case` arms so `finalizable` renders (cyan, "merged — finalize") alongside the
  existing `awaiting-merge`/`conflict` arms; `failed` and `conflict` stay red.
- Keep the queued-phase listing but gate it to `running`/`waiting` only.

## Files to Modify

- `.claude/skills/todo-task/report.sh` — `emit_chains` calls `derive_chain_state` +
  `chain_progress`; both loops append `progress`; update the format-doc comment.
- `.claude/skills/todo-task/status.sh` — read + print `progress`; attention via
  `chain_state_bucket`; render `finalizable`.
- `.claude/skills/todo-task/monitor.sh` — read + print `progress` in both chain renderers;
  remove `done_n+1` progress math; render `finalizable`.

## Verification

```bash
bash -n .claude/skills/todo-task/report.sh
bash -n .claude/skills/todo-task/status.sh
bash -n .claude/skills/todo-task/monitor.sh

# No renderer computes progress as done_n+1 anymore (queued-phase indexing may remain,
# but not for the progress string). Assert the overflow site is gone from progress prints:
! grep -nE 'phase %d/%d.*done_n \+ 1|done_n \+ 1.*/.*total' .claude/skills/todo-task/monitor.sh

# emit_chains routes through the classifier and emits progress.
grep -q 'derive_chain_state' .claude/skills/todo-task/report.sh
grep -q 'chain_progress' .claude/skills/todo-task/report.sh

# status/monitor still run clean against current state.
bash .claude/skills/todo-task/status.sh >/dev/null
bash .claude/skills/todo-task/monitor.sh >/dev/null
```

## Out of Scope

- `finalize-chain.sh` itself and the `execute-chain.sh` message/`write_chain_definition`
  adoption — Phase 3. This phase only needs to *render* the `finalizable` state; the
  status/monitor hint may name the finalize command before it exists.

## Notes

- The `5/4` overflow is fixed by Phase 1's clamp; this phase's job is to ensure the
  renderers actually *use* `chain_progress` instead of their own arithmetic. Grep for
  stray `+ 1` in the chain blocks during review.
- Watch the positional TSV reads: adding a trailing field is safe only if every reader's
  `read -r` list is extended. `archive.sh` reads chain records too (`:124`) — it only uses
  `cstatus`, so a trailing field is harmless there, but confirm its `read` doesn't choke.

## Surface after this phase

- The chain TSV record from `report.sh` is
  `chain <name> <status> <done_n> <total> <current> <phases_csv> <worktree> <branch> <progress>`
  where `status` is a `SM_CHAIN_*` value and `progress` is the print-ready string from
  `chain_progress` (never overflows).
- `status.sh` and `monitor.sh` print chain status and progress verbatim from the record;
  they no longer compute progress. Attention is driven by `chain_state_bucket`.
- `finalizable` chains render distinctly (non-attention) with a hint to finalize.
- Negative space: `execute-chain.sh` and `archive.sh` behavior is unchanged; no
  `finalize-chain.sh` exists yet.
