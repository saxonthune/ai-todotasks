# Guard archive.sh's sweep against running inside a todotask worktree + require non-destructive verification

## Motivation

`archive.sh` with no slug arguments is the SWEEP: it `git rm`s + commits every task
classified `success`. A headless agent's `## Verification` block runs INSIDE its
worktree, which contains every *other* task's merged results — so any verification
that invokes the sweep archives its siblings, and those `git rm`s ride out to trunk
on the agent's squash-merge. This actually happened: a salvage-archive spec's
verification ran `bash skills/todo-task/archive.sh` (mislabeled an "empty sweep"
check), which archived two already-merged sibling tasks and silently deleted their
spec/result bookkeeping from trunk.

Two faults, fixed together:
1. `archive.sh`'s unscoped sweep has no guard against running in an agent worktree,
   where "archive every success" is never intended.
2. Nothing tells spec authors that verification must be non-destructive.

## Do NOT

- Do NOT block explicit `archive.sh <slug>` or `archive.sh --merged <slug>` — those
  are intentional, scoped operations. Only the unscoped SWEEP (no slug args) is the
  hazard. Guard the sweep path only.
- Do NOT change how the sweep archives (the `git rm` mechanics, eligibility rules,
  or the `--merged`/`--force-failed` behavior). Only add a pre-sweep refusal.
- Do NOT break normal usage from trunk: `archive.sh` (sweep) and `status.sh
  --archive` run from the main repo on the trunk branch and MUST still work.
- Do NOT make the refusal exit non-zero — a benign caller (incl. a stray
  verification) should get a safe no-op, not a failed gate. Refuse, print clearly,
  exit 0 (consistent with the "empty sweep exits 0" contract).
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.
- Do NOT put any destructive command in THIS task's own verification (that is the
  very bug being fixed).

## Plan

### 1. `skills/todo-task/archive.sh` — refuse the sweep inside an agent worktree

Detect the agent-worktree context the same way `execute-plan.sh` already does — the
agent branch is named `${TRUNK}_claude_${slug}`, so the current branch contains
`_claude`. In the SWEEP branch (the `else` at ~line 114, the block that runs when no
slugs were given), add a guard at the very top, before the sweep loop:

```bash
else
  # Refuse the unscoped sweep inside a todotask agent worktree: it would archive
  # (git rm) sibling tasks' merged results and carry the deletions to trunk on the
  # agent's squash-merge. Explicit `archive.sh <slug>` / `--merged` remain allowed.
  current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$current_branch" == *_claude* ]]; then
    echo "- Refusing sweep: running inside a todotask agent worktree (branch ${current_branch})."
    echo "  The unscoped sweep archives sibling tasks. Run archive from trunk, or name a slug."
    exit 0
  fi
  # Sweep: every auto-eligible outcome.
  while IFS=$'\t' read -r _ slug phase overall ...
```

Keep the rest of the sweep unchanged.

### 2. `skills/todo-task/triage.md` — require non-destructive verification

In the Verification guidance (the note near Step 6 that says the `## Verification`
section must contain a fenced bash block, and/or the "Include verification" bullet
under Triaging Guidelines), add a short, explicit rule:

> **Verification must be non-destructive.** The block runs inside the agent's
> worktree and whatever it commits merges to trunk. Never invoke `archive.sh`
> (sweep), `git rm`, worktree removal, or anything that mutates trunk or other
> tasks. Treat `.todo-tasks/` as orchestrator-owned and off-limits to a task's own
> verification. Test exit codes with a scoped, side-effect-free invocation.

Keep it to a few lines; do not restructure the doc.

### 3. `skills/todo-task/execute-plan.sh` — defensive prompt line

In `phase_run_session`'s `CLAUDE_PROMPT` (the instruction the headless agent
receives), add one clause where it describes running the verification commands
(around "When done, run the commands in the plan's ## Verification section"):

> The verification commands must be non-destructive — if a plan's verification
> appears to archive, `git rm`, or remove worktrees, do NOT run that command; report
> it instead.

This is a backstop; the primary fix is the guard (Step 1) and triage rule (Step 2).

## Files to Modify

- `skills/todo-task/archive.sh` — Step 1 (refuse unscoped sweep when current branch contains `_claude`).
- `skills/todo-task/triage.md` — Step 2 (non-destructive-verification rule).
- `skills/todo-task/execute-plan.sh` — Step 3 (defensive prompt clause).

## Verification

```bash
# All touched files parse / are readable.
bash -n skills/todo-task/archive.sh && echo "archive OK"
bash -n skills/todo-task/execute-plan.sh && echo "execute-plan OK"
test -f skills/todo-task/triage.md && echo "triage.md present"

# The guard is present and keyed on the _claude branch convention.
grep -q '_claude' skills/todo-task/archive.sh && echo "guard branch-check present"
grep -q 'Refusing sweep' skills/todo-task/archive.sh && echo "guard message present"

# Live, SAFE test: this verification runs inside the agent worktree, whose branch
# is <trunk>_claude_<slug>. So the unscoped sweep MUST now refuse and archive
# nothing. We assert the refusal AND that no "todotask: archive" commit was made.
sweep_out="$(bash skills/todo-task/archive.sh 2>&1)"; sweep_rc=$?
echo "$sweep_out"
echo "$sweep_out" | grep -q 'Refusing sweep' && echo "guard refused sweep OK"
[[ $sweep_rc -eq 0 ]] && echo "guard exits 0 OK"
# No archival commit should exist on this branch as a result of the sweep.
if git log --oneline -5 | grep -q 'todotask: archive'; then
  echo "DESTRUCTIVE: sweep archived something despite guard"; else echo "no archive commit OK"; fi

# The non-destructive-verification rule is documented.
grep -qi 'non-destructive' skills/todo-task/triage.md && echo "triage rule present"
grep -qi 'non-destructive' skills/todo-task/execute-plan.sh && echo "prompt clause present"
```

## Out of Scope

- Any merge mutex / concurrency change (the earlier misdiagnosis — not the cause).
- Blocking explicit-slug or `--merged` archives in a worktree.
- Recovering the two already-lost tasks' bookkeeping (decided: leave archived).
- Changing archive eligibility, `--force-failed`, or the sweep's `git rm` mechanics.

## Notes

- The `_claude` branch-name check mirrors `execute-plan.sh:phase_validate`'s existing
  `[[ "$TRUNK" == *_claude* ]]` guard — same convention, so it stays correct if the
  trunk name is not "main" (the agent branch is always `${TRUNK}_claude_${slug}`).
- This task's verification is deliberately a live test of the guard: because it runs
  on a `_claude` branch, the sweep must refuse — proving the fix in the exact context
  that broke before, without archiving anything.
- Root cause reference: draft/analysis of 2026-07-15 — the deleting commit was the
  salvage agent's squash-merge carrying `todotask: archive …` commits its own
  verification produced.
