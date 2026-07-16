# Chain reports "failed" after all phases actually succeeded and merged

## Motivation

A 2-phase chain ran where **both phases completed, verified, and merged cleanly
into the chain branch** — but `execute-plan.sh` hit a shell syntax error *after*
the final phase's successful merge and exited non-zero. `execute-chain.sh` decides
phase success/failure **solely from execute-plan's exit code**, so it declared the
phase failed, aborted the chain, and **never merged the chain branch into trunk** —
stranding all completed work on the chain branch. `status.sh` then displayed the
impossible `phase 3/2`. Recovery required manual git surgery.

The durable fix is to make the chain trust the **result files on disk** (which
already record the truth, and which the chain's own resume logic already reads)
rather than an exit code that can be corrupted by any post-merge crash. We also
make a stranded-but-complete chain recoverable by simply re-running it, fix the
out-of-range progress display, and add a syntax-lint guard so a `bash -n`-detectable
error can't ship again.

Note on the concrete line-605 error: the current source passes `bash -n` cleanly
and the error is not reproducible — it was either already fixed or lived in a
modified install copy. We do NOT chase that specific line. The result-file-truth
fix protects against *any* post-merge crash regardless of cause, which is the
correct guarantee.

## Do NOT

- Do NOT try to "fix line 605" of `execute-plan.sh` — there is no syntax error in
  the current source (`bash -n` passes). Chasing a non-reproducible line number is
  wrong. The fix lives in `execute-chain.sh` (trust result files) and `status.sh`.
- Do NOT change how `execute-plan.sh` writes `agent.md` / `merge.md` or how
  `report.sh` classifies state. Those are correct; the chain just ignores them on
  its failure path.
- Do NOT install a git hook automatically or modify `install.sh` to enforce
  linting. Ship the lint script as an owned, runnable file (DIY/malleable
  philosophy) — the user wires it into CI/pre-commit themselves.
- Do NOT introduce a database, lock file, or new state directory. State stays
  derived from files.
- Do NOT remove the unconditional worktree recreation for chains that have NO
  completed phases — a genuinely-fresh restart must still start clean. Only
  preserve a worktree that contains at least one successfully-classified phase.
- Do NOT make a phase that genuinely failed (no clean merge) be treated as success.
  The result-file classification (`classify_task`) is the sole arbiter.

## Plan

### 1. `execute-chain.sh` — trust result files over exit code (false-failure fix)

In the phase loop (currently around lines 206-220), execute-plan is run as
`if bash execute-plan.sh ...; then "succeeded"; else "failed, stop chain"; fi`.
Change the failure branch so that a non-zero exit is reconciled against the phase's
result files before aborting. The chain worktree results dir is already available
as `CHAIN_RESULTS` (`${CHAIN_WORKTREE}/.todo-tasks/results`), `classify_task` and
`$SM_OVERALL_SUCCESS` are already in scope (sourced from `lib.sh`, and already used
by the resume check at line ~197).

Replace the `if/else` with `if/elif/else`:

```bash
  if bash "${SCRIPT_DIR}/execute-plan.sh" "${slug}" \
       --trunk-dir "${CHAIN_WORKTREE}" \
       --trunk-branch "${CHAIN_BRANCH}" \
       --no-guard; then
    echo "Phase ${slug} succeeded."
  elif [[ "$(classify_task "${CHAIN_RESULTS}/${slug}.agent.md" "${CHAIN_RESULTS}/${slug}.merge.md")" == "$SM_OVERALL_SUCCESS" ]]; then
    echo "Phase ${slug} exited non-zero but its result files classify success"
    echo "(merged cleanly into the chain branch). Treating phase as succeeded and continuing."
  else
    echo "Phase ${slug} failed. Stopping chain."
    echo ""
    echo "═══ Chain ${CHAIN_NAME} stopped at phase ${phase_num}/${total} ═══"
    echo "Failed phase: ${slug}"
    echo "Remaining: ${PHASES[*]:$((i+1))}"
    exit 1
  fi
```

Rationale: `execute-plan.sh` writes and commits `{slug}.merge.md` into the chain
worktree's results (`execute-plan.sh:525`) on a clean merge, BEFORE any later
cleanup/finalize step that could crash. So a post-merge crash leaves the truth on
disk; the chain must believe it.

### 2. `execute-chain.sh` — resume on re-run (recovery fix)

Today the "Create Chain Worktree" block (currently lines ~157-173) **unconditionally**
removes any existing chain worktree and `git branch -D`s the chain branch before
`git worktree add -b`. That destroys stranded completed work, so a crashed chain
cannot be recovered by re-running. Add a resume guard.

Just before the recreation block, detect a resumable chain: the chain worktree
exists AND at least one phase already classifies success in its results:

```bash
RESUME_CHAIN=false
if git worktree list | grep -q "${CHAIN_WORKTREE}" && [[ -d "${CHAIN_RESULTS}" ]]; then
  for slug in "${PHASES[@]}"; do
    if [[ "$(classify_task "${CHAIN_RESULTS}/${slug}.agent.md" "${CHAIN_RESULTS}/${slug}.merge.md")" == "$SM_OVERALL_SUCCESS" ]]; then
      RESUME_CHAIN=true
      break
    fi
  done
fi
```

Then gate the recreation:

```bash
echo "── Creating chain worktree ──"

if [[ "$RESUME_CHAIN" == "true" ]]; then
  echo "Existing chain worktree has completed phases — resuming and preserving work."
  echo "Chain worktree: ${CHAIN_WORKTREE}"
  echo ""
else
  if git worktree list | grep -q "${CHAIN_WORKTREE}"; then
    echo "Removing existing chain worktree..."
    git worktree remove --force "${CHAIN_WORKTREE}" 2>/dev/null || true
  fi
  if git branch --list "${CHAIN_BRANCH}" | grep -q "${CHAIN_BRANCH}"; then
    echo "Deleting existing chain branch..."
    git branch -D "${CHAIN_BRANCH}" 2>/dev/null || true
  fi
  git worktree add -b "${CHAIN_BRANCH}" "${CHAIN_WORKTREE}" "${REAL_TRUNK}"
  echo "Chain worktree created at ${CHAIN_WORKTREE}"
  echo ""
fi
```

The run-record write that follows (lines ~175-184) stays as-is — it overwrites with
the current pid/phases, which is correct on resume. The existing phase-loop resume
check (line ~197) then skips already-successful phases, and the final-merge block
re-attempts the chain→trunk merge. Net effect: re-running `launch-chain.sh` with the
same chain name and phases recovers a stranded chain with no manual git.

Note: `CHAIN_RESULTS` is defined near the top of the script (line ~75). Confirm the
resume guard is placed AFTER that definition (it is, since recreation is below it).

### 3. `status.sh` — clamp out-of-range progress display

At line ~137 the chain progress phrasing is:

```bash
      running|failed) _progress="phase $((done_n+1))/${total}" ;;
```

When every phase succeeded (`done_n == total`) but the chain is marked `failed`
(crash in the chain's own final-merge region, before the trunk definition is
written), this prints the impossible `phase 3/2`. Clamp it:

```bash
      running|failed)
        if (( done_n >= total )); then
          _progress="${total}/${total}"
        else
          _progress="phase $((done_n+1))/${total}"
        fi
        ;;
```

A `failed` chain showing `2/2` correctly communicates "all phases done, final merge
is what failed" — which points the user straight at re-running to recover.

### 4. New file: `skills/todo-task/lint-syntax.sh` — bash -n guard

Create a small, self-contained, owned script that runs `bash -n` over every shell
script in the skill directory and fails on any syntax error. Follow the repo's
"many small single-purpose scripts" convention and the no-magic style of the
existing scripts.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Syntax-check every shell script in the skill directory with `bash -n`.
# Run manually, or wire into CI / a pre-commit hook:
#   bash .claude/skills/todo-task/lint-syntax.sh
# Exits non-zero if any script fails to parse.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for f in "${SCRIPT_DIR}"/*.sh; do
  [[ -e "$f" ]] || continue
  if bash -n "$f"; then
    echo "ok    $(basename "$f")"
  else
    echo "FAIL  $(basename "$f")"
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo ""
  echo "Syntax errors found. Fix the files above before shipping."
  exit 1
fi

echo ""
echo "All skill scripts parse cleanly."
```

Note: this mirrors the repo's copied-into-project model — `SCRIPT_DIR` resolves
relative to the script, so it works both in this repo and in any install. Do not
glob the project root; only lint the skill dir's own `*.sh`.

### 5. `SKILL.md` — document chain recovery by re-run

In the "Manual Merge Conflict Resolution" area (or a short new note near the chain
docs), add a brief note that a chain left `failed` with all phases done (final merge
crashed/stranded) is recovered by **re-running the same `launch-chain.sh` command** —
completed phases are skipped and only the final chain→trunk merge is re-attempted.
Keep it to a few lines; do not restructure the doc.

## Files to Modify

- `skills/todo-task/execute-chain.sh` — Step 1 (result-files-over-exit-code in the phase loop) + Step 2 (resume guard around worktree recreation).
- `skills/todo-task/status.sh` — Step 3 (clamp `phase N/total` so it never exceeds total).
- `skills/todo-task/lint-syntax.sh` — Step 4 (NEW: `bash -n` over skill scripts).
- `skills/todo-task/SKILL.md` — Step 5 (short note: recover a stranded chain by re-running launch-chain).

## Verification

```bash
# 1. All skill scripts parse cleanly (this also exercises the new lint script).
bash skills/todo-task/lint-syntax.sh

# 2. Explicit syntax checks on the edited orchestrator + renderer.
bash -n skills/todo-task/execute-chain.sh && echo "execute-chain.sh OK"
bash -n skills/todo-task/status.sh && echo "status.sh OK"

# 3. The lint script must FAIL on a deliberately broken script (negative test).
tmp="$(mktemp -d)"; printf 'if true; then\n' > "$tmp/broken.sh"
if bash -n "$tmp/broken.sh" 2>/dev/null; then echo "NEGATIVE TEST FAILED"; else echo "negative test OK (bash -n catches broken script)"; fi
rm -rf "$tmp"

# 4. Confirm the false-failure reconciliation and resume guard are present.
grep -q "classify success" skills/todo-task/execute-chain.sh && echo "Step 1 present"
grep -q "RESUME_CHAIN" skills/todo-task/execute-chain.sh && echo "Step 2 present"

# 5. Confirm the progress clamp is present.
grep -q "done_n >= total" skills/todo-task/status.sh && echo "Step 3 present"
```

## Out of Scope

- The actual line-605 syntax error in `execute-plan.sh` (not reproducible; the
  durable fix supersedes it).
- Auto-installing a git pre-commit hook or modifying `install.sh`.
- Changes to `report.sh` classification, `execute-plan.sh` result-writing, or the
  trunk-sync conflict-resolution agent.
- Recovering a chain whose worktree was already fully removed (the stranded case
  this task targets keeps the worktree present).

## Notes

- Load-bearing fact: `execute-plan.sh:525` writes & commits `{slug}.merge.md` into
  `${MERGE_DIR}/.todo-tasks/results` (the chain worktree for a chain phase) on a
  clean merge, before any finalize step. This is why result-file classification is
  trustworthy even when execute-plan later crashes. If a future change moves merge.md
  writing to *after* finalize, Step 1's guarantee weakens — keep them ordered.
- Reviewer watch-points: (a) the resume guard must only trigger when a phase
  actually classifies success, so a phase-1 failure with no completed work still
  recreates fresh; (b) the `elif` in Step 1 must not mask a real failure — it only
  rescues when `classify_task` returns `$SM_OVERALL_SUCCESS`; (c) `set -euo pipefail`
  is active — the `if/elif/else` around `bash execute-plan.sh` correctly neutralizes
  `set -e` for that command, so no `set +e` juggling is needed.
- This is a standalone task (not a chain/epic phase), so no "Surface after this
  phase" block is required.
