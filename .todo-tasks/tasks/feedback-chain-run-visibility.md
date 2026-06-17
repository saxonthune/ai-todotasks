# Group chain phases under their chain in status/monitor output

## Motivation

A multi-phase chain is currently opaque in both `monitor.sh` and `status.sh`:

1. **Phases scatter into "Pending."** A chain's not-yet-merged phase specs live in
   `tasks/` but share a single chain run-record (`chain-{name}.run`), not per-slug
   run-records. So `report.sh`'s per-task ladder classifies every chain phase —
   done, running, or queued — as plain `pending` (Rule 5). The renderers then list
   them in the flat Pending bucket, disconnected from their chain and looking like
   unrelated standalone tasks.
2. **The `done_n/total` counter is ambiguous.** It shows `0/4` while phase 1 is
   actively running. "0/4" reads as "nothing happening" even though phase 1 is in
   progress.

The authoritative per-phase progress is **already** in the reporter's `chain`
record: ordered `phases` CSV, `done_n`, `current`, and `status`. Because chains run
strictly sequentially, per-phase status is fully derivable from these alone:

- index `< done_n` → done
- index `== done_n` → current (running, or failed if the chain failed)
- index `> done_n` → queued

So **`report.sh` needs no changes** — this is a pure rendering fix in the two
renderers. This preserves the contract (`contracts.md` §Reporter algorithm) that
`report.sh` is the only component that walks the filesystem and classifies state.

## Do NOT

- Do NOT modify `report.sh`. It already emits everything required (the `chain`
  record carries `phases`, `done_n`, `current`, `status`). Re-deriving chain
  membership by walking the filesystem in a renderer violates the single-source
  contract.
- Do NOT show completed phases in the grouped list. The user wants **upcoming
  phases shown and done phases hidden**. The current phase is named in the headline;
  the indented/listed phases are the strictly-upcoming (queued) ones.
- Do NOT change the `done_n/total` semantics inside the `chain` TSV record. Only the
  *display* string changes (renderer-side), to an active-phase index.
- Do NOT break `set -euo pipefail` safety in either script — guard empty-array
  expansions the way the existing code does (`[[ ${#arr[@]} -gt 0 ]]`, passing arrays
  to render helpers that tolerate zero args).
- Do NOT touch `execute-chain.sh`, `launch-chain.sh`, or `lib.sh`.

## Plan

### 1. `monitor.sh` — group chain phases, hide done, disambiguate counter

In `render_frame` (the loop over `report.sh` output, around lines 131–189):

1. **Collect chains separately from task-running entries.** Today running/waiting/
   failed chains are pushed into the shared `active` array (lines 159–162) and
   rendered as a single line by `render_active`. Instead, push their raw fields into
   a dedicated `chains_active` array (carry `name`, `cstatus`, `done_n`, `total`,
   `current`, `phases`). Leave the `complete` case unchanged — it still goes to
   `recent_raw` (lines 163–164).
2. **Build a chain-member set.** After the read loop, iterate every collected chain
   record (running/waiting/failed) and split its `phases` CSV into a
   `declare -A chain_member` set keyed by slug.
3. **Filter Pending.** When rendering pending, drop any slug present in
   `chain_member`. Easiest: build a filtered `pending_show` array after the loop
   (`for slug in "${pending[@]}"; do [[ -n "${chain_member[$slug]:-}" ]] || pending_show+=("$slug"); done`) and pass that to `render_pending`. Update the
   summary's pending count to use the filtered count.
4. **Render a chains block** (new `render_chains` helper) placed between
   `render_active` and `render_recent`. For each chain entry:
   - Headline line. Compute the active-phase index `idx=done_n` (0-based). Display:
     - `running` → `running  <name>  phase $((done_n+1))/<total>: <current>`
     - `failed`  → `failed   <name>  failed at phase $((done_n+1))/<total>: <current>` (RED)
     - `waiting` → `waiting  <name>  <current>` (current is already `after <slug>`)
     - Guard `done_n+1 > total` (shouldn't happen for active chains) by clamping to `total`.
   - Indented upcoming phases. Let `start` = `done_n` when `cstatus == waiting`
     (no phase is "current" yet), else `done_n+1`. For each phase at index `>= start`,
     print an indented `    queued  <phase-slug>` line (DIM). The current phase
     (index `done_n`, for running/failed) is already named in the headline, so it is
     NOT repeated in the list.
   - Reuse the existing color scheme (`YELLOW` for running/waiting, `RED` for failed,
     `DIM` for queued) and `EL` line-clear, matching the other render_* helpers.

Keep `render_active` for task-running entries only (it still handles the
`running` task case from line 144).

### 2. `status.sh` — same grouping, table-friendly

1. **Build the chain-member set + filter PENDING.** After the record-collection loop
   (lines 32–58), iterate `CHAINS` (all of them — running *and* complete, since an
   unarchived complete chain's phase specs may still classify pending), split each
   `phases` field, and build a `declare -A CHAIN_MEMBER`. Then rebuild `PENDING` to
   exclude members before the Pending Plans section renders (line 138).
2. **Rework the Chains table** (lines 112–123):
   - `Progress` column → active-phase phrasing derived from `cstatus`:
     - `running`/`failed` → `phase $((done_n+1))/<total>`
     - `complete` → `<total>/<total>`
     - `waiting` → `0/<total>`
   - Keep the `Current/Failed` column (`current`).
   - Rename the `Phases` column to `Upcoming` and populate it with only the
     strictly-upcoming phases (index `> done_n` for running/failed; index `>= done_n`
     for waiting; empty/`—` for complete). Join with spaces. This honors "show
     upcoming, hide done" and mirrors the monitor.
3. Leave the `failed` → `HAS_ATTENTION=true` behavior (line 120) intact.

### 3. Shared derivation note

Both scripts compute the same thing from the `chain` record (active index = `done_n`,
upcoming = phases after it). Keep the logic inline in each renderer — there is no
shared rendering lib, and the contract is that each renderer is a thin consumer of the
reporter TSV. Do not add cross-script sourcing for this.

## Files to Modify

- `.claude/skills/todo-task/monitor.sh` — add `render_chains`, collect chains into a
  dedicated array, build the chain-member set, filter pending, render upcoming phases
  indented, switch the counter to active-phase index.
- `.claude/skills/todo-task/status.sh` — build the chain-member set, filter `PENDING`,
  change the Chains table `Progress` to active-phase index and the `Phases` column to
  an `Upcoming` (queued-only) column.

## Verification

```bash
set -u
REPO="$(git rev-parse --show-toplevel)"
SKILL="$REPO/.claude/skills/todo-task"

# 1. Syntax.
bash -n "$SKILL/monitor.sh" || { echo "FAIL: monitor.sh syntax"; exit 1; }
bash -n "$SKILL/status.sh"  || { echo "FAIL: status.sh syntax"; exit 1; }

# 2. Functional fixture: a live 2-phase chain whose phases are unstarted specs.
RUN="$REPO/.todo-tasks/.running/chain-_vtest.run"
PA="$REPO/.todo-tasks/tasks/_vphase-a.md"
PB="$REPO/.todo-tasks/tasks/_vphase-b.md"
cleanup() { rm -f "$RUN" "$PA" "$PB"; }
trap cleanup EXIT
mkdir -p "$REPO/.todo-tasks/.running"
# pid=$$ keeps the chain "alive" (run_is_alive) for the duration of this run.
printf 'slug: _vtest\nworktree: /tmp/_v_nope\nbranch: x\npid: %s\nstart: now\nkind: chain\nphases: _vphase-a,_vphase-b\n' "$$" > "$RUN"
printf '# a\n' > "$PA"
printf '# b\n' > "$PB"

MOUT="$(bash "$SKILL/monitor.sh" --once)"
SOUT="$(bash "$SKILL/status.sh")"

# Phases must NOT appear under a flat pending line in either renderer.
if printf '%s\n' "$MOUT" | grep -E 'pending +_vphase' >/dev/null; then
  echo "FAIL: monitor shows chain phase under pending"; exit 1; fi
if printf '%s\n' "$SOUT" | sed -n '/Pending Plans/,/^## /p' | grep -E '_vphase' >/dev/null; then
  echo "FAIL: status shows chain phase under Pending Plans"; exit 1; fi

# Upcoming phase (_vphase-b) must be visible, grouped with the chain.
printf '%s\n' "$MOUT" | grep -q '_vphase-b' || { echo "FAIL: monitor hides upcoming phase"; exit 1; }
printf '%s\n' "$SOUT" | grep -q '_vphase-b' || { echo "FAIL: status hides upcoming phase"; exit 1; }

# Counter reads as active phase 1/2, not 0/2.
printf '%s\n' "$MOUT" | grep -Eq 'phase 1/2' || { echo "FAIL: monitor counter not active-phase"; exit 1; }
printf '%s\n' "$SOUT" | grep -Eq 'phase 1/2' || { echo "FAIL: status counter not active-phase"; exit 1; }

echo "OK: chain phases grouped, upcoming shown, done hidden, counter active-phase"
```

## Out of Scope

- The other feedback draft (`feedback-headless-run-invisible-progress`) — streaming
  tool-use to the log and the "no-op" relabel. Separate task.
- Any change to chain *execution* (`execute-chain.sh`, `launch-chain.sh`).
- Progress-bar glyphs (the original feedback mentioned a `▱▱▱▱` bar that the current
  monitor does not render — not reintroducing it here).

## Notes

- The reporter's `chain` record is the single source for per-phase state; the
  renderers only reformat it. If a future change needs richer per-phase detail
  (e.g. distinguishing a *running* current phase from a *crashed* one mid-chain),
  that belongs in `report.sh`'s `emit_chains`, not the renderers.
- Watch the `waiting` case: `current` there is the literal string `after <slug>`,
  not a phase slug, so the active-index phrasing must special-case it (don't print
  `phase 1/N: after foo`).
- `set -u` + empty associative arrays: reference members as `${CHAIN_MEMBER[$slug]:-}`.
