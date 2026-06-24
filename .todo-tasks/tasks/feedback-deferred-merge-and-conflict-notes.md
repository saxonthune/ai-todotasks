# Deferred / conflicted chain merges must not read as "failed", and should try harder to merge

## Motivation

A fully-implemented, fully-tested chain whose **final trunk merge was deferred** —
because the trunk *working tree* was dirty from a concurrent session — is currently
surfaced on the dashboard as `failed`, with no breadcrumb explaining what is safe to
do. The operator has to tail the run log to discover the work actually succeeded, then
hand-roll `git merge --squash`, remove the worktree/branch, and delete the run-record.

The mislabel is a three-layer story in the code:

- `execute-chain.sh:286-294` — if the trunk working tree is dirty, it prints manual
  instructions, leaves the run-record, and `exit 1`. The real-conflict path
  (`:326-332`) likewise `exit 1`s.
- `report.sh:199-202` (`emit_chains`) — *any* chain with a run-record and a **dead PID**
  is unconditionally classified `status="failed"`. It cannot tell "deferred-but-safe"
  from "crashed".
- `status.sh:163` and `monitor.sh` (`:364`, `:421`) — `failed` sets `HAS_ATTENTION` and
  renders red. No `awaiting-merge` / `conflict` chain status exists anywhere.

The current `git diff --quiet`-style gate is **too broad**: it bails whenever the trunk
working tree is dirty *at all*. In a monorepo with multiple chains running concurrently in
separate sections, that means an unrelated session's WIP in section Y blocks a chain that
only touches section X — even though those merges never collide. The deciding question is
**"does *this* merge conflict?"**, not "is the tree dirty?".

So the new model is: **always attempt the merge; only raise the flag if it would actually
fail.** The safe way to attempt without risking a concurrent session's uncommitted work is
`git merge-tree` — a dry-run that computes the merge result purely from git objects and
**never touches the working tree**. A clean probe means the chain merges without conflict;
we then run the real `git merge --squash`, which succeeds for disjoint sections and only
refuses when a chain-touched file is *itself* uncommitted-dirty (a genuine overlap).

(Note the "advanced trunk" case already works today — `execute-chain.sh:267` pre-syncs
`REAL_TRUNK` into the chain branch, and a trunk that merely moved forward merges normally.)

## Do NOT

- Do NOT gate the merge on whether the working tree is dirty. That is the bug. Always
  attempt the merge; decide on the *outcome* of the attempt, not on tree-dirtiness.
- Do NOT probe by mutating the working tree (no trial `git merge --no-commit`, no
  `git stash`). Use `git merge-tree`, which is side-effect-free. A concurrent session's
  uncommitted work must never be at risk.
- Do NOT run destructive recovery (`git reset --hard`, `git checkout -- .`, `git clean`)
  on any failure path — that would nuke a concurrent session's WIP. A `git merge --squash`
  that refuses due to WIP overlap makes no changes, so there is nothing to clean up.
- Do NOT use `git commit` (which would sweep a concurrent session's *staged* WIP into the
  agent's squash commit). On the proceed path, commit with an **explicit pathspec** of the
  chain's changed files: `git commit -m '...' -- "${CHAIN_PATHS[@]}"`.
- Do NOT classify a deferred-but-safe chain as `failed`. `failed` stays reserved for a
  true crash (dead run-record with **no** `merge_state` marker).
- Do NOT change `phase_merge` in `execute-plan.sh`, single-plan classification in `lib.sh`
  `classify_overall`, or the `archive.sh` cleanup flow. This task is the chain final-merge
  path and its reporting only.
- Do NOT change the merge strategy — still `git merge --squash`.
- Do NOT touch the `git merge ${REAL_TRUNK}` final-sync step or its resolver-agent
  (`execute-chain.sh:266-281`).

## Plan

### 1. Add chain merge-state vocabulary and a note-writer to `lib.sh`

Near the other `SM_*` constants (`lib.sh:5-42`), add two chain-merge-state strings used
as the run-record `merge_state:` field value and as chain statuses downstream:

```sh
readonly SM_CHAIN_AWAITING_MERGE="awaiting-merge"
readonly SM_CHAIN_CONFLICT="conflict"
```

Add a small single-purpose helper that writes the structured breadcrumb note. Path is
`${TODO}/results/${name}.conflict.md` (the predictable place the draft asks for). It is
written **uncommitted** — the chain is not on trunk yet, and the renderers read the
filesystem, not git.

```sh
# write_chain_merge_note <results_dir> <chain_name> <branch> <state> <paths> <summary>
# Structured breadcrumb so the trunk agent/human resolves without log-spelunking.
write_chain_merge_note() {
  local dir="$1" name="$2" branch="$3" state="$4" paths="$5" summary="$6"
  mkdir -p "$dir"
  {
    echo "# Chain ${name}: ${state}"
    echo ""
    echo "state: ${state}"
    echo "branch: ${branch}"
    echo ""
    echo "## Merge command"
    echo ""
    echo '```sh'
    echo "git merge --squash ${branch} && git commit -m 'feat: chain-${name} (agent)'"
    echo '```'
    echo ""
    echo "## Conflicting / overlapping paths"
    echo ""
    if [[ -n "$paths" ]]; then printf '%s\n' "$paths" | sed 's/^/- /'; else echo "- (none)"; fi
    echo ""
    echo "## What this chain changed"
    echo ""
    echo "${summary}"
  } > "${dir}/${name}.conflict.md"
}
```

(Match the existing function style in `lib.sh`. Keep it terse and self-documenting.)

### 2. Rework the chain final-merge in `execute-chain.sh` (lines ~284-333)

Delete the dirty-tree gate at `:286-294` entirely. The merge is **always attempted** via a
side-effect-free probe, and the decision is made on the probe/merge *outcome*.

New control flow for the section starting at `MERGE_STATUS="failed"` (`:284`):

1. Compute `CHAIN_PATHS` once (used both as the commit pathspec and to populate the
   breadcrumb): `mapfile -t CHAIN_PATHS < <(git diff --name-only "${REAL_TRUNK}...${CHAIN_BRANCH}")`.

2. **Probe (no side effects):** run `git merge-tree --write-tree "${REAL_TRUNK}" "${CHAIN_BRANCH}"`.
   - Non-zero exit → a genuine **content conflict** against committed trunk. Set
     `MERGE_STATUS="${SM_CHAIN_CONFLICT}"`, write the run-record marker + breadcrumb (the
     conflicting paths come from the merge-tree conflict output), print the manual command,
     `exit 1`. Do NOT touch the working tree.
   - `git merge-tree` unsupported (old git, the `--write-tree` form errors) → skip the
     probe and fall through to step 3; rely on the real merge's own success/failure.

3. **Clean probe → real merge:** `git merge --squash "${CHAIN_BRANCH}"`.
   - **Success** → `git commit -m "feat: chain-${CHAIN_NAME} (agent)" -- "${CHAIN_PATHS[@]}"`,
     set `MERGE_STATUS="success"`, and run the post-success block (chain-definition write +
     worktree/branch/run-record cleanup). This is the path that lets two disjoint-section
     chains both land without blocking each other.
   - **Refusal/failure** → the only way this happens after a clean probe is a chain-touched
     file that is *itself* uncommitted-dirty (real overlap with a concurrent session). Git
     refuses up front and makes no changes, so there is nothing to abort or reset. Set
     `MERGE_STATUS="${SM_CHAIN_AWAITING_MERGE}"` (work is safe on the branch; it can merge
     once the other session commits), capture the offending paths (e.g. intersect
     `CHAIN_PATHS` with `git status --porcelain` paths), write the run-record marker +
     breadcrumb, print the manual command, `exit 1`.

Keep the existing clean-tree success branch's behavior (chain-definition write +
worktree/branch/run-record cleanup) — factor it into a shared block/function the success
path calls rather than duplicating it.

In the two flag exits (`conflict`, `awaiting-merge`), **write the run-record `merge_state:`
field** so the
reporter can classify the dead run-record. Append to the existing run-record (do not
rewrite it — `execute-chain.sh` owns it):

```sh
echo "merge_state: ${MERGE_STATUS}" >> "$(run_record_path "${CHAIN_NAME}" chain)"
```

And call `write_chain_merge_note` with the chain's results dir
(`${CHAIN_WORKTREE}/.todo-tasks/results` — the worktree still exists), the branch, the
state, the overlap/conflict paths, and a one-line summary (e.g. the chain's phase list
and changed-file count). Keep the human-readable `echo` instructions too.

### 3. Classify the new states in `report.sh` `emit_chains` (lines 193-206)

For a chain whose run-record has a **dead PID**, read the marker before defaulting to
`failed`:

```sh
local mstate; mstate="$(read_run_field "$run" merge_state)"
if [[ -n "$mstate" ]]; then
  status="$mstate"          # awaiting-merge | conflict
else
  status="failed"           # genuine crash — no marker was written
fi
```

`done_n`/`total` already compute from `phase_success` over the worktree results, so a
deferred chain correctly shows all phases done. Leave that intact.

### 4. Render the new states in `status.sh` (chain block, lines 128-165)

- Progress phrasing (`:136-141`): for `awaiting-merge` and `conflict`, show
  `${done_n}/${total}` (all phases done) — not `phase $((done_n+1))/${total}`.
- After the chain row, when `cstatus == awaiting-merge`, print a line with the exact
  merge command (reconstruct from `name`/`branch`, matching the note), and do **NOT** set
  `HAS_ATTENTION`. When `cstatus == conflict`, set `HAS_ATTENTION=true` and point at
  `results/${name}.conflict.md`.
- Update the `[[ "$cstatus" == "failed" ]] && HAS_ATTENTION=true` line (`:163`) so it does
  not also fire for `awaiting-merge`.

### 5. Render the new states in `monitor.sh` (lines ~359-380 and ~412-430)

- Color: `awaiting-merge` → yellow/cyan (not red); `conflict` and `failed` → red.
- Add `case` arms for `awaiting-merge` ("ready to merge — phase N/N") and `conflict`
  ("merge conflict — phase N/N") in both the active block and `render_chains`, mirroring
  the existing `running`/`failed`/`waiting` arms.

## Files to Modify

- `.claude/skills/todo-task/lib.sh` — two `SM_CHAIN_*` constants + `write_chain_merge_note` helper.
- `.claude/skills/todo-task/execute-chain.sh` — safety pre-check, proceed-if-safe merge with pathspec commit, `merge_state` run-record marker, breadcrumb note; factor the post-success block so clean and safe-dirty paths share it.
- `.claude/skills/todo-task/report.sh` — `emit_chains` reads `merge_state` for dead run-records.
- `.claude/skills/todo-task/status.sh` — render `awaiting-merge` (command, no attention) and `conflict` (attention); progress phrasing.
- `.claude/skills/todo-task/monitor.sh` — color + `case` arms for the two new chain statuses.

## Verification

```bash
# All modified scripts parse.
bash -n .claude/skills/todo-task/lib.sh
bash -n .claude/skills/todo-task/execute-chain.sh
bash -n .claude/skills/todo-task/report.sh
bash -n .claude/skills/todo-task/status.sh
bash -n .claude/skills/todo-task/monitor.sh

# New vocabulary is wired through every layer.
grep -q 'SM_CHAIN_AWAITING_MERGE' .claude/skills/todo-task/lib.sh
grep -q 'write_chain_merge_note' .claude/skills/todo-task/lib.sh
grep -q 'merge_state' .claude/skills/todo-task/execute-chain.sh
grep -q 'merge_tree\|merge-tree' .claude/skills/todo-task/execute-chain.sh
grep -q 'merge_state' .claude/skills/todo-task/report.sh
grep -q 'awaiting-merge' .claude/skills/todo-task/status.sh
grep -q 'awaiting-merge' .claude/skills/todo-task/monitor.sh

# Guardrails: failed stays for true crashes only; phase_merge untouched.
grep -q 'status="failed"' .claude/skills/todo-task/report.sh
```

## Out of Scope

- Cleaning up the orphaned run-record after a human finalizes a deferred chain — that is
  the sibling draft `feedback-manual-chain-merge-orphans-run-record`. This task makes the
  state legible (`awaiting-merge`); a `finalize-chain` / `archive.sh` change is the
  follow-up. (Note: the `awaiting-merge` state defined here is what that task keys off.)
- Single-plan (`phase_merge`) deferral/conflict reporting in `execute-plan.sh`.
- The `phase_merge` git-lock retry (`fix-phase-merge-git-lock-coordination`).
- Renaming user-facing "no-op" (`feedback-headless-run-invisible-progress`).

## Notes

- `git merge-tree --write-tree` needs git ≥ 2.38 (2022). If unavailable, skip the probe
  and attempt the real `git merge --squash` directly — it is itself safe (it refuses
  rather than clobbering uncommitted work, and we run no destructive recovery). The probe
  is an optimization that classifies content-conflicts as `conflict` up front; without it,
  a content conflict surfaces as the real merge failing and is flagged `awaiting-merge`
  instead. Acceptable degradation.
- The breadcrumb `results/${name}.conflict.md` is written **uncommitted** by design (the
  chain isn't on trunk). It is a transient file the eventual finalize step removes. A
  reviewer should confirm it doesn't get accidentally `git add`-ed by the proceed path's
  pathspec commit (the pathspec is the chain's files only).
- Hard to unit-test in isolation — full confidence comes from a scratch-repo chain run
  with the trunk working tree deliberately dirtied in (a) a disjoint file → expect the
  merge to proceed, and (b) a chain-touched file → expect `awaiting-merge` + breadcrumb.
- Watch the `git status --porcelain` parsing for paths with spaces; quote consistently and
  prefer `-z`/NUL handling if the existing scripts already do.
