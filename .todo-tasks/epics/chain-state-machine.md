# Epic: chain-state-machine

chain: chain-state-machine
members: chain-state-classifier,chain-state-render-consumers,chain-finalize-orphan-cleanup

## Motivation

Single tasks are formalized: `lib.sh:derive_overall_state()` is a pure function mapping
raw facts → one canonical `SM_OVERALL_*` state, with `state_bucket()` for grouping, and
the renderers consume that verbatim. **Chains never got this treatment.**
`report.sh:emit_chains` computes chain status with inline ad-hoc logic, chain "states" are
bare strings, and each renderer recomputes presentation (`done_n+1`) independently.

That single structural gap surfaces as a family of bugs: a deferred/crashed-at-merge chain
read as `failed`; the impossible `5/4` progress in `monitor.sh`/`status.sh` (a chain that
finished all phases but failed at the *final merge* has `done_n == total`, and the renderer
adds one); and an orphaned `.running/chain-*.run` lingering forever after a human completes
a deferred merge out-of-band.

This epic promotes chains to first-class state-machine citizens — **without abandoning
"derive, don't store."** All chain state stays *derived* from file presence; we simply
centralize the derivation (one `derive_chain_state` analogous to `derive_overall_state`),
derive progress exactly once, make renderers dumb consumers, and add the one genuinely
missing *mutation* (clearing an orphaned run-record after an out-of-band merge).

## Phases

1. **chain-state-classifier** — pure chain state-machine in `lib.sh`: a closed `SM_CHAIN_*`
   enum, `derive_chain_state()`, `chain_progress()` (clamped — can never exceed total),
   `chain_state_bucket()`, `chain_merged_on_trunk()`, and a shared `write_chain_definition()`.
   Library-only; nothing is wired yet, so it is independently safe to merge.
2. **chain-state-render-consumers** — `emit_chains` becomes a thin fact-gatherer that calls
   the classifier and emits a ready-made `progress` field; `status.sh` and `monitor.sh`
   consume state + progress verbatim and stop computing `done_n+1`. Fixes `5/4` and renders
   the new `finalizable` state.
3. **chain-finalize-orphan-cleanup** — `finalize-chain.sh <name>`: after an out-of-band
   merge, verify the chain landed on trunk, write its definition, remove worktree/branch,
   clear the orphaned run-record. `execute-chain.sh` deferred/conflict messages point at it;
   adopt the shared `write_chain_definition()`; document in `SKILL.md`. (Folds the
   `feedback-manual-chain-merge-orphans-run-record` draft.)

## Notes

- Execute as a sequential chain (each phase depends on Phase 1's helpers). Phases 2 and 3
  triage against Phase 1's declared Surface, not live code.
