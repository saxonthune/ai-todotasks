# Agent Result: feedback-chain-run-visibility

date: 2026-06-16T21:49:13-04:00
session: completed
verification: passed
commits: 1
branch: main_claude_feedback-chain-run-visibility
surface deviations: none
session id: a5ba5277-78f0-413d-b824-8281d43e651e


## Summary

Implementation complete. One commit made.

---

## Implementation summary

**monitor.sh:**
- Added global `declare -A CHAIN_MEMBER=()` for the phase-membership set
- Added `phases` field to CHAINS array entries (it was parsed from the TSV but discarded)
- At end of `parse_records`: build CHAIN_MEMBER from all active chain phases, filter PENDING to exclude them, update N_PENDING
- New `render_chains` helper: shows each chain with active-phase headline (`running phase 1/2: <slug>`) and indented `queued <slug>` lines for upcoming phases; hides done phases
- `render_overview`: split the single `if N_RUNNING > 0 || N_CHAINS > 0` block into separate Active (tasks only) and Chains sections
- `render_active` tab: updated inline rendering with phase counter and queued phase lines, preserves worktree display

**status.sh:**
- After record collection, build `CHAIN_MEMBER` from all chains' phases CSV, filter `PENDING` before rendering
- Chains table: Progress column → `phase N/total` (active-phase index); Phases column renamed to `Upcoming` showing only queued phases (hidden for complete, all for waiting, tail for running/failed)

## Notes

- The `phases` field in monitor.sh's CHAINS entries was silently dropped before this change — it was parsed from the TSV but not stored. That was the root cause of the scatter-into-pending bug.
- The `render_active` tab (not `render_overview`) keeps an inline chains loop rather than calling `render_chains`, because it also shows the worktree path per chain which `render_chains` doesn't include.
- For `waiting` chains, the current field is the literal string `after <slug>` (not a phase slug), so the headline uses `waiting <name> after <slug>` without a phase counter — this matches the plan's note about the waiting special-case.

## Surface Deviations

None.

## Commits

```
4846b07 feat: group chain phases in status/monitor, hide done, active-phase counter
```

## Build & Test Output (last 30 lines)

```
OK: chain phases grouped, upcoming shown, done hidden, counter active-phase
```
