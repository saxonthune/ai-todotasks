# Coordinate phase_merge git operations with concurrent foreground activity

## Motivation

`skills/todo-task/execute-plan.sh` `phase_merge` runs `git merge --squash` +
`git commit` against the trunk working tree (`MERGE_DIR`, around line 483). That
directory is routinely the same one the user's foreground Claude Code session is
using, which intermittently holds `.git/index.lock` during its own `git status` /
`git log` calls. A transient lock collision makes the merge fail and fall into the
conflict branch (line 503-507) with nothing useful reported — indistinguishable
from a genuine content conflict, and one of the silent-failure fingerprints the
sibling `feedback-agents-commit-but-skip-result-file` task (already landed) made
visible. A bounded, lock-aware retry recovers the collision; when it genuinely
can't, the failure should be reported as a lock collision, not a generic conflict.

## Do NOT

- Do NOT change the merge strategy — it stays `git merge --squash` + `git commit`.
- Do NOT retry a genuine content conflict. A merge that fails because of
  conflicting content must still land in the existing conflict path (abort, leave
  branch intact, `SM_MERGE_CONFLICT`). Only an `index.lock` / "another git process"
  failure is retryable.
- Do NOT touch `phase_finalize`, `status.sh`, or the classification code.
- Do NOT add an unbounded/infinite retry — cap attempts and total wait so a stuck
  lock cannot hang the run forever.
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.
- Do NOT introduce a lock file, database, or new state dir — retry in-process only.

## Plan

### 1. `skills/todo-task/execute-plan.sh` — distinguish lock failure from conflict

In `phase_merge`, the merge is currently:

```bash
      if git merge --squash "${BRANCH}" && git commit -m "feat: ${PLAN_SLUG} (agent)"; then
        ... clean/dirty handling ...
      else
        git merge --abort 2>/dev/null || true
        MERGE_STATUS="$SM_MERGE_CONFLICT"
        echo "Merge conflict! Branch ${BRANCH} left intact for manual merge."
      fi
```

Wrap the `git merge --squash` step in a bounded lock-aware retry that captures
stderr and only retries on lock contention. Suggested shape (adjust to fit the
surrounding style):

```bash
      # Bounded retry: a transient .git/index.lock from a concurrent foreground
      # git call is recoverable; a real content conflict is not. Only lock
      # failures are retried.
      merge_attempts=0
      merge_lock_blocked=false
      while :; do
        merge_attempts=$((merge_attempts + 1))
        merge_err="$(git merge --squash "${BRANCH}" 2>&1)"; merge_rc=$?
        if [[ $merge_rc -eq 0 ]]; then
          break
        fi
        if echo "$merge_err" | grep -qiE 'index\.lock|another git process|Unable to create'; then
          git merge --abort 2>/dev/null || true
          if [[ $merge_attempts -ge 5 ]]; then
            merge_lock_blocked=true
            break
          fi
          echo "git index.lock collision (attempt ${merge_attempts}/5) — retrying..."
          sleep 2
          continue
        fi
        # Non-lock failure → genuine conflict. Restore original behavior.
        echo "$merge_err"
        break
      done
```

Then branch on the outcome:

- If the merge succeeded (`merge_rc -eq 0` on the winning attempt), run
  `git commit -m "feat: ${PLAN_SLUG} (agent)"` (the commit itself can also hit the
  lock — wrap it in the same bounded retry, or reuse a small helper) and proceed
  to the existing clean/dirty conflict-marker scan.
- If `merge_lock_blocked` is true, set `MERGE_STATUS="$SM_MERGE_CONFLICT"`, ensure
  the merge is aborted, and print a DISTINCT, clearly-labelled message, e.g.
  `"Merge blocked by git index.lock after 5 attempts — a concurrent git process
  held the lock. Branch ${BRANCH} left intact; re-run merge when the tree is idle."`
  Also set a variable (e.g. `MERGE_LOCK_DETAIL`) carrying that reason.
- Otherwise (non-lock failure) keep the existing conflict behavior:
  `git merge --abort`, `MERGE_STATUS="$SM_MERGE_CONFLICT"`, the current message.

Prefer factoring the merge+commit retry into a small local helper (the repo favors
small, single-purpose units) rather than duplicating the loop for the commit.

### 2. `skills/todo-task/execute-plan.sh` — surface the lock reason

The conflict outcome writes NO `merge.md` (by design — the reporter reads the
stranded agent.md). To keep the lock case from looking generic, make the reason
visible in the run log with the distinct message above (Step 1). If a lightweight
channel exists to record the reason without disturbing the state machine (e.g.
echoing `MERGE_LOCK_DETAIL` into the finalize summary line), use it — but do not
invent a new result-file schema or state. The distinct log line is the required
minimum; anything beyond it must not change classification.

## Files to Modify

- `skills/todo-task/execute-plan.sh` — `phase_merge`: bounded lock-aware retry around `git merge --squash` (+ `git commit`), distinguishing lock contention from genuine conflict and reporting the lock case distinctly.

## Verification

```bash
# Script still parses.
bash -n skills/todo-task/execute-plan.sh && echo "execute-plan OK"

# Retry logic and lock detection are present.
grep -qiE 'index\.lock' skills/todo-task/execute-plan.sh && echo "lock detection OK"
grep -q 'merge_attempts' skills/todo-task/execute-plan.sh && echo "bounded retry OK"

# The merge strategy is unchanged (still squash + the same commit message).
grep -q 'git merge --squash' skills/todo-task/execute-plan.sh && echo "strategy unchanged OK"
grep -q 'feat: ${PLAN_SLUG} (agent)' skills/todo-task/execute-plan.sh && echo "commit msg unchanged OK"

# The genuine-conflict path still sets SM_MERGE_CONFLICT.
grep -q 'SM_MERGE_CONFLICT' skills/todo-task/execute-plan.sh && echo "conflict path intact OK"
```

## Out of Scope

- Any change to `phase_finalize`, `status.sh`, `report.sh`, or classification.
- Changing the merge strategy away from `--squash`.
- A new result-file schema or state-machine state for the lock case.
- Coordinating the *agent-branch* commits (the leak/verification-cd concern) —
  this task is only the trunk-side `phase_merge` git ops.

## Notes

- The sibling `feedback-agents-commit-but-skip-result-file` (already landed and
  archived) is what makes a merge failure visible in status at all; this task
  builds on that by keeping the lock sub-case from masquerading as a content
  conflict.
- Retry bound rationale: 5 attempts × ~2s covers the sub-second windows a
  foreground `git status`/`git log` holds `index.lock`, while capping total added
  latency to ~10s so a genuinely stuck lock still terminates the run.
- `set -uo pipefail` is active (no `-e`); capturing `$?` immediately after the
  `git merge` into `merge_rc` is required before any other command runs.
