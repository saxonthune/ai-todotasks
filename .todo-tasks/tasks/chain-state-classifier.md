# Chain state classifier — pure state machine for chains in lib.sh

## Motivation

Chains have no analog of `lib.sh:derive_overall_state()`. `report.sh:emit_chains` computes
status inline, and the renderers recompute progress as `done_n+1` — which overflows to
`5/4` when a chain finished every phase but failed at the *final merge* (`done_n == total`).
This phase adds the pure, centralized chain state machine to `lib.sh`. It wires nothing —
`emit_chains` and the renderers are untouched here (that is Phase 2) — so this phase is
independently safe to merge: existing behavior is unchanged, new functions are dormant.

This is Phase 1 of the `chain-state-machine` epic. Mirror the existing style of
`derive_overall_state` / `state_bucket` exactly (same comment format, same `case`/`echo`
idiom, `readonly` constants grouped with the others).

## Do NOT

- Do NOT modify `report.sh`, `status.sh`, `monitor.sh`, or `execute-chain.sh`. This phase
  is **`lib.sh` only**. Wiring is Phase 2/3.
- Do NOT store or persist any state. These are *pure derivation* functions computed from
  inputs the caller already has. No new files, no run-record writes.
- Do NOT remove or rename the existing `SM_CHAIN_AWAITING_MERGE` / `SM_CHAIN_CONFLICT`
  constants (`lib.sh:45-46`) — extend the set, keep their string values stable
  (`"awaiting-merge"`, `"conflict"`) since the run-record `merge_state:` field and
  Phase-2-era renderers depend on them.
- Do NOT let `chain_progress` ever emit a numerator greater than the denominator. Clamp.

## Plan

### 1. Extend the chain state enum (near `lib.sh:44-46`)

Keep the two existing constants; add the rest so chains have a closed enum like
`SM_OVERALL_*`. String values are the statuses the reporter/renderers will use:

```sh
# Chain states — derived by derive_chain_state(); used as chain status downstream.
readonly SM_CHAIN_RUNNING="running"
readonly SM_CHAIN_WAITING="waiting"
readonly SM_CHAIN_AWAITING_MERGE="awaiting-merge"   # (exists) deferred, branch ready, clean
readonly SM_CHAIN_CONFLICT="conflict"               # (exists) content conflict, needs resolution
readonly SM_CHAIN_FINALIZABLE="finalizable"         # merged out-of-band; orphaned run-record to clear
readonly SM_CHAIN_COMPLETE="complete"               # merged + trunk definition present
readonly SM_CHAIN_FAILED="failed"                   # dead, not merged, no merge_state marker (true crash)
```

### 2. `derive_chain_state()` — the analog of `derive_overall_state`

```sh
# derive_chain_state <alive> <done_n> <total> <merge_state> <waiting_unsatisfied> <merged_on_trunk>
#   alive               : "true"/"false" — run-record PID still running
#   done_n / total      : phases classified success / total phases
#   merge_state         : run-record merge_state: field ("", awaiting-merge, conflict)
#   waiting_unsatisfied : "true" if --after predecessor has not succeeded yet
#   merged_on_trunk     : "true" if every phase's result is present on trunk HEAD
# Echoes one SM_CHAIN_* value. Pure.
```

Logic (first match wins):
- `alive == true` && `waiting_unsatisfied == true` → `SM_CHAIN_WAITING`
- `alive == true` → `SM_CHAIN_RUNNING`
- dead (`alive == false`):
  - `merged_on_trunk == true` → `SM_CHAIN_FINALIZABLE` (work landed out-of-band; only the
    orphaned run-record remains — Phase 3 clears it)
  - `merge_state == awaiting-merge` → `SM_CHAIN_AWAITING_MERGE`
  - `merge_state == conflict` → `SM_CHAIN_CONFLICT`
  - else → `SM_CHAIN_FAILED` (genuine crash — no marker, not merged)

Note: the trunk-definition / `complete` case is emitted by `emit_chains`'s definition loop
(no run-record) and stays there; `derive_chain_state` covers the run-record-present states.
For completeness `derive_chain_state` may also accept and short-circuit on a
`has_definition` flag → `SM_CHAIN_COMPLETE`, but that is optional — Phase 2 decides whether
to route the definition loop through the classifier. Document whichever you choose in the
Surface.

### 3. `chain_progress()` — derive the progress string once, clamped

```sh
# chain_progress <state> <done_n> <total> — ready-to-print progress, never overflows.
chain_progress() {
  local state="$1" done_n="$2" total="$3" n
  case "$state" in
    "$SM_CHAIN_RUNNING")
      n=$(( done_n + 1 )); (( n > total )) && n="$total"   # clamp — kills "5/4"
      echo "phase ${n}/${total}" ;;
    "$SM_CHAIN_WAITING") echo "0/${total}" ;;
    *)                   echo "${done_n}/${total}" ;;        # done/failed/awaiting/conflict/finalizable/complete
  esac
}
```

The clamp is the structural fix: no caller can ever render a numerator > total again.

### 4. `chain_state_bucket()` — attention grouping (analog of `state_bucket`)

```sh
# chain_state_bucket <state> — does this chain need operator attention?
#   conflict, failed          → attention
#   awaiting-merge, finalizable → ready (benign; a one-liner away from done)
#   complete                  → success
#   running, waiting          → (neither — active)
```

Echo the `SM_BUCKET_*` value (reuse the existing bucket constants). Renderers/status use
this to decide whether to trip "Attention needed".

### 5. `chain_merged_on_trunk()` — git-native "did it land?" check

Both Phase 2 (classifier input) and Phase 3 (finalize guard) need this, so it lives here:

```sh
# chain_merged_on_trunk <repo_root> <phases_csv> — true iff every phase's agent result
# is present on trunk HEAD (a squash-merge of the chain branch brings them to trunk).
chain_merged_on_trunk() {
  local repo="$1" phases="$2" p
  for p in ${phases//,/ }; do
    [[ -n "$p" ]] || continue
    git -C "$repo" cat-file -e "HEAD:.todo-tasks/results/${p}.agent.md" 2>/dev/null || return 1
  done
  return 0
}
```

### 6. `write_chain_definition()` — shared definition writer

Extract the chain-definition block currently inlined in
`execute-chain.sh:do_post_merge_success` (lines ~291-308) into `lib.sh` so Phase 3's
`finalize-chain.sh` and `execute-chain.sh` share one writer (no drift). Do NOT change
`execute-chain.sh` to call it in this phase (that adoption is Phase 3) — just define the
function here matching the existing output exactly:

```sh
# write_chain_definition <dest_path> <name> <phases_csv> [after] — writes the trunk
# chain definition file (does not commit; caller commits). Byte-compatible with the
# block in execute-chain.sh:do_post_merge_success.
```

## Files to Modify

- `.claude/skills/todo-task/lib.sh` — chain enum constants + `derive_chain_state`,
  `chain_progress`, `chain_state_bucket`, `chain_merged_on_trunk`, `write_chain_definition`.

## Verification

```bash
bash -n .claude/skills/todo-task/lib.sh

# Functions are pure and behave — source the lib and assert outputs.
bash -c '
  source .claude/skills/todo-task/lib.sh
  set -e
  [ "$(derive_chain_state true  2 4 "" false false)" = "running" ]
  [ "$(derive_chain_state true  0 4 "" true  false)" = "waiting" ]
  [ "$(derive_chain_state false 4 4 awaiting-merge false true)" = "finalizable" ]
  [ "$(derive_chain_state false 4 4 awaiting-merge false false)" = "awaiting-merge" ]
  [ "$(derive_chain_state false 2 4 conflict false false)" = "conflict" ]
  [ "$(derive_chain_state false 1 4 "" false false)" = "failed" ]
  # progress never overflows
  [ "$(chain_progress running 4 4)" = "phase 4/4" ]
  [ "$(chain_progress running 2 4)" = "phase 3/4" ]
  [ "$(chain_progress failed  4 4)" = "4/4" ]
  [ "$(chain_progress awaiting-merge 4 4)" = "4/4" ]
  echo "OK"
'
```

## Out of Scope

- Wiring any of this into `emit_chains` or the renderers — that is Phase 2.
- `finalize-chain.sh` and `execute-chain.sh` adoption of `write_chain_definition` — Phase 3.

## Surface after this phase

- `lib.sh` exports a closed chain-state enum: `SM_CHAIN_RUNNING="running"`,
  `SM_CHAIN_WAITING="waiting"`, `SM_CHAIN_AWAITING_MERGE="awaiting-merge"`,
  `SM_CHAIN_CONFLICT="conflict"`, `SM_CHAIN_FINALIZABLE="finalizable"`,
  `SM_CHAIN_COMPLETE="complete"`, `SM_CHAIN_FAILED="failed"`.
- `derive_chain_state <alive> <done_n> <total> <merge_state> <waiting_unsatisfied> <merged_on_trunk>`
  echoes exactly one `SM_CHAIN_*` value, per the logic above (dead+merged→finalizable;
  dead+awaiting-merge marker→awaiting-merge; dead+conflict marker→conflict; dead+nothing→failed).
- `chain_progress <state> <done_n> <total>` echoes a print-ready string and **never** emits
  a numerator greater than `total` (running clamps `done_n+1` to `total`; all terminal
  states echo `done_n/total`; waiting echoes `0/total`).
- `chain_state_bucket <state>` echoes a `SM_BUCKET_*` value: conflict/failed→attention,
  awaiting-merge/finalizable→ready, complete→success, running/waiting→(active, non-attention).
- `chain_merged_on_trunk <repo_root> <phases_csv>` returns 0 iff every phase's
  `.todo-tasks/results/<phase>.agent.md` exists on trunk `HEAD`.
- `write_chain_definition <dest_path> <name> <phases_csv> [after]` writes the trunk chain
  definition (uncommitted), byte-compatible with `execute-chain.sh:do_post_merge_success`.
- Negative space: `emit_chains`, `status.sh`, `monitor.sh`, and `execute-chain.sh` are
  **unchanged** by this phase — the new functions exist but nothing calls them yet. The
  existing `SM_CHAIN_AWAITING_MERGE`/`SM_CHAIN_CONFLICT` string values are unchanged.
