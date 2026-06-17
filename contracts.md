# Contracts

Design contracts for the file-based todotask state machine. This document records
what we have **decided** and what remains **open** before implementation. It is a
living design doc, not user-facing instructions.

## Purpose

Re-architect todotask state so that:

- All three entities (task, chain, epic) are expressed as plain files (unix philosophy).
- Git itself is the mechanism that transports state updates — no cross-boundary edits.
- Merges of state files are conflict-free by construction.
- `main`'s working tree never accumulates hundreds of todotask files.

## Core invariants

Two rules make git merge conflicts structurally impossible. A conflict requires
*divergent edits to the same region of the same file*; both rules remove that.

1. **One writer per file.** Every file has exactly one component permitted to write it.
2. **Transition by new file, not by edit.** State changes create a new uniquely-named
   file; they never mutate a shared one (the maildir / append-only pattern).

Corollary: **derive, don't store.** Mutable progress (a chain's completed phases, a
task's lifecycle phase, an epic's rollup) is *computed* from which files exist — never
written into a mutable field. Directory-as-state (moving files between `.running/`,
`.done/`) is itself a divergent edit under merge and is therefore abandoned.

Everything about *finished* work is derivable from durable files. The **one** thing that
is not — **liveness** (is a process actually running right now) — is the only thing that
needs an ephemeral signal; see *Run-record* below.

## Entities

### Task

The atomic unit.

- **Draft (pre-lifecycle):** `inbox/{slug}.md` — a filed idea that has not been triaged.
  Lives in the **gitignored** `inbox/`. `create` writes here; it is a personal scratchpad,
  never committed, and never seen by the merge-transport. See *Draft inbox* below.
- **Definition:** `tasks/{slug}.md` — the spec. Authored by triage (promoted from the draft),
  immutable while running.
- **Outcome (split by epistemic owner):**
  - `{slug}.agent.md` — facts the worktree knows in isolation. Fields: `session:`,
    `verification:`, `commits:`, `branch:`, `surface deviations:` + a prose summary.
    Written by the agent **inside its own worktree**, committed on its own branch, carried
    to trunk by the merge.
  - `{slug}.merge.md` — facts only trunk knows *after* the merge. Fields: `merge:`,
    `trunk:` (+ optional conflict detail). Written by the **orchestrator** on trunk.
- **Phase:** derived from file presence (see *Reporter algorithm*).

### Chain

A runtime convenience: make several changes in one launch. The mutable manifest is
**eliminated**.

- **Definition:** one authored file — fields: `chain:`, `phases: a,b,c` (ordered),
  optional `after:` dependency, + prose. Immutable after launch.
- **Progress:** derived — a phase is complete iff its result file exists and classifies
  as success; `current` = first phase without one; `status` = all-success → complete /
  any-fail → failed / else running.
- **Transport:** sequential, so no concurrency to protect. All phases share **one** chain
  worktree + branch and commit onto it in order (code + each phase's `agent.md`). The chain
  merges to trunk **once, at completion** — atomic all-or-nothing. While running or if it
  fails mid-chain, all phase results live in the chain worktree and are found via the
  run-record. Chain definition files live only on trunk (written by the orchestrator).

### Epic

A grouping with shared prose context.

- **Definition:** `epics/{epic}.md` — fields: `epic:`, `members: a,b,c` (slug list), + prose.
  Membership is an **explicit slug list**, not a filename-prefix glob.
- **Rollup:** derived from classifying each member's result.

### Identity

The **slug is the stable id**, fixed at creation and immutable — rename is not an in-place
operation (rename = archive old + create new). Membership references slugs; since slugs
never change, references never break. A `YYYYMMDD-` prefix may be added at creation for sort
and uniqueness (the existing archive convention). No separate/opaque ID system.

## Transport: git, not direct writes

- **Worktree agent → trunk: forbidden.** It is sandboxed; it only writes its own worktree
  on its own branch.
- **Orchestrator → trunk: allowed.** It lives on trunk and owns it — a single serial writer.

The agent reports by committing `{slug}.agent.md` on its branch; the orchestrator's merge
carries it to trunk. This is *why* active state must be tracked (not gitignored): a
gitignored file cannot ride a commit, which would force the forbidden direct write.

Because every result file is uniquely named and single-writer, merges are always unions —
never collisions.

## Run-record (the only ephemeral state)

Durable files can derive everything except **liveness**. To supply it, the orchestrator
writes a **gitignored** run-record when it launches a phase: `.running/{slug}.run`,
containing the worktree path, branch, PID, and start time.

It provides exactly two things, both deterministic:

- **Liveness:** run-record present + PID alive → running; PID dead + no result → crashed.
- **Failure location:** because the worktree path is *recorded*, the reporter can read
  `agent.md` directly from that worktree even when a merge failed and the result never
  reached trunk. This dissolves the stranded-result problem — nothing is guessed.

The orchestrator writes the run-record (allowed); the reporter only reads it (allowed). No
worktree agent ever writes it. It is recomputable, never merged, and lives only locally.

## Draft inbox (untriaged tasks)

A filed idea is not yet work. Until it is triaged it has no place in the tracked record and
no business generating git history.

- `create` writes `inbox/{slug}.md`, a **gitignored** draft. No commit — it is a local note.
- `triage` **promotes** the draft: writes the executable spec to `tasks/{slug}.md` (a tracked
  path) and deletes the draft. Triage does **not** commit — the spec sits uncommitted, which
  is fine: it does not block launching (see below) and is committed lazily at execute time.
- The **orchestrator commits the spec at launch**, as its first action, *before* the worktree
  is cut. This is required for correctness, not bookkeeping: an uncommitted (untracked) spec
  would collide with the squash-merge ("untracked working tree file would be overwritten by
  merge") once the agent branch carries the same path. Committing it first makes the path
  identical on both sides, so the merge is a clean no-op for the spec.
- Ideas that are filed and never triaged — and specs triaged but never executed — touch git
  **zero** times.

Why launching isn't blocked: the dirty-tree guard **excludes `.todo-tasks/`** (pathspec
`:(exclude).todo-tasks`). Uncommitted todotask state (drafts, the just-promoted spec, stranded
results) never trips it; the guard still catches uncommitted *code*. This is safe because the
worktree agent never edits `.todo-tasks/` — the only `.todo-tasks/` writes on its branch are
the orchestrator's uniquely-named result files, which cannot collide.

Tradeoff (accepted): drafts are **local-only** — a teammate cloning the repo does not see
another's untriaged inbox. For a solo, malleable-install tool the inbox is *your* scratchpad,
so this is the intended behavior, not a limitation. (Executed specs *do* land on trunk via the
launch commit, so the shared record of real work is preserved.)

The reporter reads the gitignored `inbox/` (read-only, like `.running/`) and surfaces drafts
as a distinct **draft** phase, so `ls`/status still shows filed-but-untriaged ideas without
them riding git.

## Reporter algorithm

A single state-reading script is the only component that walks the filesystem and
classifies state. Coarse phase comes from **file presence**; outcome detail comes from
**`key: value` fields**; liveness comes from the **run-record**. Per task:

1. no spec, no draft → does not exist
2. `agent.md` + `merge.md` present → **done**; classify success/failure via fields
3. run-record present + PID alive → **running**
4. run-record present + PID dead + no result → **crashed**
5. spec present (in `tasks/`) → **pending**
6. draft only (in gitignored `inbox/`, no spec) → **draft**

A 0-commit run whose worktree contains uncommitted changes classifies as `salvageable`
(attention bucket) rather than `no_op` or `session_failed`. This state is intentionally
excluded from `--force-failed` auto-archiving — recovery is a human action.

For unmerged/failed tasks the reporter reads `agent.md` from the run-record-pointed
worktree. All renderers (status, monitor) consume the reporter's output; none walk the
filesystem or parse formats themselves.

## State-encoding rules

- **Directory location: categorization only, never lifecycle.** Stable buckets
  (`tasks/`, `results/`, `chains/`, `epics/`, gitignored `inbox/`, `.running/`, `.archived/`)
  are fine. Pending/running/done are **never** represented by moving files between directories.
- **File presence: the primary lifecycle signal** (`test -f`, no parsing).
- **`key: value` fields: outcome detail only** (success/failure classification).
- **Run-record: liveness only.**

The only move of a **tracked** file is **archive** (`git rm` on trunk by the orchestrator —
serial, single-writer, conflict-free). Triage's promotion (`inbox/{slug}.md` →
`tasks/{slug}.md`) is a plain local move of a *gitignored, uncommitted* draft, so it is not a
tracked-file move at all and is unconstrained. The spec only becomes tracked when the
orchestrator commits it at launch (a normal serial on-trunk commit, like the result files).
Lifecycle *within* the tracked record (pending/running/done) is still pure derivation, never
a move.

## Compatibility

**Clean break.** No old-format fallbacks. Every reader targets the new layout only.

## Archive and the policy boundary

- **We ship:** an archive script. Archive = `git rm` the tracked active files; a physical
  copy lands in the **gitignored `.archived/`**. Files leave `main`'s working tree; the
  local dashboard still sees them.
- **The consuming repo optionally adds:** a branch-protection rule rejecting merges that
  still contain active `.todo-tasks/` files. We do **not** ship this rule — running archive
  is what makes a branch pass it. (Malleable-install philosophy: provide capability, not policy.)
- The concern is *file count in the working tree*, not commits in history, so `git rm` fully
  addresses it; we do not depend on three-dot net-zero diffs.

## Lifecycle

0. create writes `inbox/{slug}.md` (gitignored draft) — no commit
1. triage promotes the draft → `tasks/{slug}.md` (tracked path, uncommitted), removing the
   draft — no commit
2. orchestrator commits the spec on trunk (lazily, at launch), then creates a worktree +
   branch from trunk
3. agent does the work **and** writes `{slug}.agent.md` in its worktree, commits on its branch — *no trunk write*
4. orchestrator merges branch → working branch (the merge transports `agent.md`)
5. orchestrator writes `{slug}.merge.md` on the working branch
6. status/monitor *derive* state from the tracked files — `ls` is the dashboard
7. archive (by rule or command): `git rm` spec + result files → gitignored `.archived/`
8. *(consumer repo, optional)* branch rule blocks merge until step 7 has run

---

## Resolved decisions

The eight previously-open items, now decided:

1. **Chain cursor & locking** → derive `current`/`status` from result files; **liveness**
   comes from the gitignored run-record. (See *Run-record*, *Reporter algorithm*.)
2. **Stranded results on merge failure** → the run-record records the worktree path; the
   reporter reads `agent.md` from there regardless of merge state. (See *Run-record*.)
3. **Chain transport** → one shared worktree + branch, sequential commits, single atomic
   merge at completion. (See *Chain*.)
4. **File schemas** → flat `key: value` fields + prose; membership = comma-separated slug
   list. (See *Task*, *Chain*, *Epic*.)
5. **ID scheme** → the slug is the stable, immutable id; optional `YYYYMMDD-` prefix. (See
   *Identity*.)
6. **Failure surfacing** → the reporter classifies and surfaces all failures, reading
   stranded results via the run-record. (See *Reporter algorithm*.)
7. **Migration** → clean break, no old-format fallbacks. (See *Compatibility*.)
8. **Directory layout & "running"** → directories are stable categories; lifecycle is file
   presence; "running" is the gitignored run-record, not a directory move. (See
   *State-encoding rules*.)

## Still to specify during implementation

Not architectural — work these out while building:

- **Archive trigger rules per outcome.** Clean completion auto-archives; decide whether
  failures stay tracked for review or also archive (and on what command).
- **Reporter output format** (e.g. TSV vs. JSON lines) consumed by status/monitor.
- **Verification placement** — confirmed it runs in the worktree and lands in `agent.md`;
  nail down the exact field/format.
