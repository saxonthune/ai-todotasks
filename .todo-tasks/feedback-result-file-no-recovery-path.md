# Result files have no way to reflect manual recovery

## What happened

After an agent's run crashes (in my case, the leak-detector false positive in `feedback-leak-detector-false-positive.md`), I manually inspect the worktree, verify tests pass, merge the agent's branch into trunk, clean up the worktree, and archive. The work is fully integrated — but the `.result.md` file still records `Session: failed / Verification: failed / Merge: not_attempted`, because those fields were written by `execute-plan.sh` at the moment of crash and are never revised.

The downstream cost: `monitor.sh --once` and `status.sh` both parse those fields via `classify_result` and report the slug as `crashed` / `failed`. The epic summary inherits the classification — `pg-rtp` showed "2/14 done, 3 failed" even though all five completed phases were actually integrated and passing tests on trunk. I had to hand-edit three archived `.result.md` files (rewriting `Session:`, `Verification:`, `Merge:` to `completed/passed/clean`) just to get the dashboard to reflect reality.

## Why it matters

It creates a permanent disagreement between the canonical record (the result file) and what actually happened in git. Future sessions reading status get a misleading picture of which phases are done. And it punishes the recovery path — manual recovery is already a chore; needing to also surgically edit a result file to canonical state strings (which you have to find in `lib.sh` first) is friction on top of friction.

## Direction

Two non-exclusive ideas:

1. **Auto-detect from git.** `classify_result` (or a wrapper) could check whether the agent branch was merged into trunk (`git log --merges --grep "Merge feat/.*_claude_<slug>"` or branch contains-check). If yes, override the file's classification. The result file becomes a snapshot of *the original run*, and git becomes the source of truth for *current integration state*.

2. **A `mark-recovered` helper.** `bash .claude/skills/todo-task/mark-recovered.sh <slug>` that rewrites the canonical fields and appends a note explaining the manual merge. Documented in the todo-task skill's "Manual Merge Conflict Resolution" section so users know to call it.

(1) is more robust; (2) is a smaller change and lets the user be explicit.
