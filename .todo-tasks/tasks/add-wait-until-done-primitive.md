# Add a blocking `wait.sh` primitive and a `launch.sh --watch` flag

## Motivation

Every launch ends with the same dead-end handoff: "here's a log path, check it
yourself." An orchestrating session (or any automation) that launches background
work has no join point — it either polls `status.sh` by hand on a timer or
hand-rolls a PID loop. The PID approach is subtly wrong: `launch.sh`/`launch-chain.sh`
print a short-lived launcher PID that exits before the work finishes, so a
`while kill -0 <pid>` watcher returns prematurely and reports "done" before the
run actually ends. The phase/agent PIDs change between chain phases and the
run-record is cleared on completion, so there is no stable PID to watch.

The robust join point keys off the **file-derived classification** (`report.sh`,
the single classifier) rather than any PID — it is correct across phase
transitions, worktree churn, and run-record clearing, and it covers success,
failure, and crash uniformly. This task ships that as `wait.sh <name>` plus a
`launch.sh --watch` convenience flag, and points the skill's launch report step at
it instead of `tail -f`.

This consolidates two drafts: `feedback-launch-watch-until-done` (single-launch
watch) and `feedback-wait-for-chain-completion` (scriptable chain join). One
primitive, auto-detecting task vs chain, serves both.

## Do NOT

- Do NOT watch a PID to decide completion. Derive terminal state from `report.sh`
  output only. PIDs are unstable across phases and cleared on completion.
- Do NOT re-implement classification in `wait.sh`. Read the record `report.sh`
  already emits and map its `phase`/`overall` (task) or `status` (chain) to
  terminal-or-not. `wait.sh` is a pure poller over the reporter.
- Do NOT block forever with no escape — support an optional `--timeout`. Default
  is unbounded (a launched run should reach a terminal state), but a caller must
  be able to bound it.
- Do NOT change the exit-code contract: `0` = success, non-zero = anything else
  (ready-for-review, conflict, crash, build/session failure, timeout). Keep it
  binary; a caller does `wait.sh x && next`. Print a final status line naming the
  actual state so a human/log can still tell timeout from completed-not-success.
- Do NOT make `--watch` change launch semantics — the run still executes exactly
  as today; `--watch` only makes `launch.sh` block on `wait.sh` afterward and
  propagate its exit code.
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.

## Plan

### 1. New file: `skills/todo-task/wait.sh`

A small, self-contained, owned script (follow the repo's script conventions:
`#!/usr/bin/env bash`, `set -uo pipefail`, `SCRIPT_DIR`/`REPO_ROOT` resolution,
`source lib.sh`). Contract:

```
Usage: wait.sh <name> [--timeout SECONDS] [--interval SECONDS]
  <name>      a task slug OR a chain name (auto-detected)
  --timeout   max seconds to wait before giving up (default: unbounded)
  --interval  poll interval in seconds (default: 5)
Exit: 0 if the run reached SUCCESS; non-zero otherwise (incl. timeout).
```

Behavior:

1. **Detect kind.** Chain if `.todo-tasks/.running/chain-<name>.run` exists OR
   `.todo-tasks/chains/<name>.md` exists; otherwise treat `<name>` as a task slug.
2. **Poll loop** (sleep `--interval` between iterations, respecting `--timeout`):
   - Task: run `report.sh task`, `awk -F'\t'` for the row whose slug matches, read
     its `phase` (col 3) and `overall` (col 4).
     - `phase` ∈ {`done`, `crashed`} → terminal. Exit `0` iff
       `overall == "$SM_OVERALL_SUCCESS"`, else exit `1`.
     - `phase` ∈ {`running`, `pending`} → keep waiting.
     - row absent → keep waiting (until timeout), it may not have registered yet.
   - Chain: run `report.sh chain`, match the chain name, read `status` (col 3).
     - `status == "complete"` → exit `0`.
     - `status` ∈ {`failed`, `conflict`, `awaiting-merge`, `finalizable`} →
       terminal, exit `1`.
     - `status` ∈ {`running`, `waiting`} → keep waiting.
3. **Timeout.** If `--timeout` elapses before a terminal state, print a clear
   `TIMEOUT` status line and exit non-zero (use exit code `1` to honor the binary
   contract; the printed line distinguishes it for humans).
4. **Final status line.** On every exit, print one line naming the outcome, e.g.
   `wait: <name> → success (exit 0)` / `→ merge_conflict (exit 1)` /
   `→ timeout after Ns (exit 1)`. This is the draft's "final status line on exit."

Use the `SM_OVERALL_SUCCESS` / `SM_CHAIN_COMPLETE` constants from `lib.sh` — do not
hardcode the strings.

### 2. `skills/todo-task/launch.sh` — add `--watch`

Parse a `--watch` flag in the arg loop (alongside `--no-merge`). After the
existing background launch (the `nohup … &` at line 38 and the echo lines), if
`--watch` was set, block on the new primitive and exit with its code:

```bash
if [[ "$WATCH" == "true" ]]; then
  echo ""
  echo "Watching until ${PLAN_SLUG} reaches a terminal state..."
  exec bash "${SCRIPT_DIR}/wait.sh" "${PLAN_SLUG}"
fi
```

(`exec` so `launch.sh`'s exit code is `wait.sh`'s. `--watch` composes with
`--no-merge`; a `--no-merge` run reaches `ready_for_review`, which is non-success,
so `--watch --no-merge` exits non-zero — correct per the contract.)

### 3. `skills/todo-task/launch-chain.sh` — add `--watch`

Mirror Step 2: parse `--watch`, and after the chain is launched in the background,
if set, `exec bash "${SCRIPT_DIR}/wait.sh" "${CHAIN_NAME}"`. Place the watch AFTER
the launch/echo so the run-record and background process exist before `wait.sh`
starts polling. (Read the script first to match its existing arg-parsing and the
variable holding the chain name.)

### 4. `skills/todo-task/execute.md` — arm the watcher in the launch report step

In the **Report** step (the section telling the user to `tail -f` the log and
re-run status), add the watch option as the recommended way to block until done:
mention `launch.sh {slug} --watch` (foreground, blocks and exits with the outcome)
and `bash .claude/skills/todo-task/wait.sh {slug}` (run in a background shell to
watch an already-launched run). Keep `tail -f` as the live-log option. Do not
restructure the doc — add the watch as the primary "wait for completion" path.

## Files to Modify

- `skills/todo-task/wait.sh` — NEW: blocking poller over `report.sh`; auto-detects task vs chain; exit 0=success/non-zero=else; `--timeout`/`--interval`.
- `skills/todo-task/launch.sh` — parse `--watch`; `exec wait.sh` after launch.
- `skills/todo-task/launch-chain.sh` — parse `--watch`; `exec wait.sh <chain>` after launch.
- `skills/todo-task/execute.md` — launch report step arms the watcher instead of only suggesting `tail -f`.

## Verification

```bash
# All touched scripts parse.
bash -n skills/todo-task/wait.sh && echo "wait OK"
bash -n skills/todo-task/launch.sh && echo "launch OK"
bash -n skills/todo-task/launch-chain.sh && echo "launch-chain OK"

# wait.sh usage/contract surface is present.
grep -q 'Usage: wait.sh' skills/todo-task/wait.sh && echo "usage OK"
grep -q -- '--timeout' skills/todo-task/wait.sh && echo "timeout flag OK"
grep -q 'SM_OVERALL_SUCCESS' skills/todo-task/wait.sh && echo "uses success constant OK"
grep -q 'report.sh' skills/todo-task/wait.sh && echo "polls reporter OK"

# --watch is wired into both launchers.
grep -q -- '--watch' skills/todo-task/launch.sh && echo "launch --watch OK"
grep -q -- '--watch' skills/todo-task/launch-chain.sh && echo "chain --watch OK"
grep -q 'wait.sh' skills/todo-task/launch.sh && echo "launch arms wait OK"

# wait.sh exits non-zero for an unknown name within a short timeout (never hangs
# the gate). Unknown slug → row absent → waits → times out → non-zero.
if timeout 20 bash skills/todo-task/wait.sh __no_such_task__ --timeout 3 --interval 1; then
  echo "UNKNOWN-NAME GUARD FAILED (should be non-zero)"
else
  echo "unknown-name times out non-zero OK"
fi

# The skill's launch report step references the watcher.
grep -q 'wait.sh' skills/todo-task/execute.md && echo "execute.md armed OK"
```

## Out of Scope

- Real pub/sub or a daemon — polling under the hood is fine.
- Distinct exit codes per terminal state (deliberately binary 0/non-zero).
- A `monitor.sh` rewrite — it stays the human TUI; `wait.sh` is its scriptable
  sibling.
- Notifying/desktop alerts on completion.

## Notes

- The two consumed drafts (`feedback-launch-watch-until-done`,
  `feedback-wait-for-chain-completion`) are deleted at triage time — this spec
  supersedes both.
- Keying off `report.sh` (not a PID) is the load-bearing decision: it is why the
  watcher is correct across chain phase transitions and after the run-record is
  cleared on completion. A PID-based watcher was the exact bug both drafts hit.
- `--timeout` uses wall-clock elapsed vs a start stamp; poll with `sleep`
  `--interval`. `wait.sh` runs in the OUTER orchestrating session (which can run a
  background shell), not inside the sandboxed headless agent — so `sleep` polling
  is legal here (unlike the in-agent slow-build case tracked separately).
