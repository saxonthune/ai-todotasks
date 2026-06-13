# Headless agent runs are invisible until they finish

## What happened

I launched a todo-task agent and watched it for ~25 minutes. The launch script prints its banner and that's it — the agent's `.log` file stayed at 16 lines (the banner) for the entire run. The agent process was alive (`ps` showed it sleeping at ~2% CPU), but I had no way to tell whether it was making progress, stuck retrying a rate-limited tool call, or quietly looping.

I checked the worktree mid-run: `git status` was clean, no untracked files, no commits. So from outside, the run was indistinguishable from a stuck or crashed agent. I concluded — incorrectly — that the agent was struggling, and spent ~20 minutes preparing a backup spec with finer-grained steps in case I needed to re-launch.

Roughly two minutes after I finished writing the backup spec, the agent finished and auto-merged five commits to trunk. The work was fine; my read was wrong. The wasted effort was real.

The cause is that `execute-plan.sh` invokes Claude with `--output-format json`, which only emits the final JSON result — there is no streaming progress to stdout, so the log file stays empty until the process exits. The `monitor.sh` dashboard reads the same log file and so cannot show anything more either.

## Why it matters

- **No signal to distinguish working from stuck.** A 25-minute agent and a 25-minute hung agent look identical from outside the process. The user's only options are wait indefinitely or kill speculatively — both bad.
- **Bad triage decisions follow.** I started parallel/backup work based on a wrong read of agent health. With the right signal I'd have left it alone.
- **`monitor.sh` is currently a wrapper around an empty file.** During a run, the dashboard mostly tells you "running" with no other content — which is barely more than `ps`.
- **Larger tasks are most affected.** A 3-minute task finishing with no log is fine; a 25-minute task with no log feels like a hang. So the friction grows exactly when triage costs grow.

## Direction

Two angles, either or both:

- **Stream tool-use events to the log.** If the headless invocation supported `--output-format stream-json` (or similar), the log could show "Read X / Edit Y / Bash Z" in real time. Even one line per tool call would be enough to tell working-from-stuck apart.
- **A heartbeat file the agent touches periodically.** Cheaper to implement: have the runner side-channel a `last-activity` timestamp (file mtime, separate file) updated when Claude emits anything internally. `monitor.sh` could surface "last activity: 8s ago" vs "last activity: 14m ago" — the latter signaling probable hang.

The first is the cleaner answer if the SDK supports it. The second is a fallback that works without SDK changes.

---

# Part 2: never say "no-op"

## What happened

After my agent finished and auto-merged five commits to trunk, `status.sh` reported the agent as `no_op` with `0 commits`. The work was *done* — five commits, a verified migration, tests passing. The label said "no-op."

The dashboard arrives at this label honestly: it inspects the post-merge state of the agent's branch, sees it's equal to trunk (because the merge succeeded), counts zero remaining ahead-commits, and reports `no_op`. From the script's point of view, that's literally true. From a user's point of view, "no-op" means "this run accomplished nothing," which is the opposite of what happened.

## Why it matters

- **The word is wrong for the situation.** A successful auto-merge is the *most* useful outcome. Calling it "no-op" inverts the user's mental model.
- **It triggered the wrong instinct.** Seeing `no_op / 0 commits` on a task I was already worried about, I assumed v1 had failed silently and a second agent I'd launched was now the only path forward. I had to read trunk's `git log` to discover v1 had actually landed everything. The status output was actively misleading.
- **It reads as engineer-shorthand leaking into UX.** "No-op" is a term from the script's POV ("this branch produces zero diff against trunk"). Surfacing that to a human as the *outcome label* makes the tool feel half-written. Users read top-level labels as verdicts, not as introspection notes.
- **The word itself is condescending in this context.** Telling a user their 25-minute, fully successful agent run was a "no-op" reads less like a status and more like a dismissal.
- **Reaching for jargon like "no-op" (or "bikeshed", "yak-shave", "footgun") is a tell that the writer couldn't form the actual concept in words.** Each of these is a verbal shrug — a token swapped in for the missing description of what is genuinely happening. "No-op" stands in for "the agent's branch contains commits identical to trunk after auto-merge"; "bikeshed" stands in for "we are arguing over surface details when the underlying decision is already made." The shorthand is faster to type and harder to think with. In a status dashboard the cost is highest, because the user has no way to recover the missing concept — they see the token and stop.

## Direction

Two changes, easy:

1. **Distinguish "merged-and-empty-branch" from "produced-no-work."** The first is success; the second is a real failure mode. They should not share a label.
   - If the agent's commits were merged to trunk: report `merged` (or `landed`, `complete`, `done` — anything that names the outcome).
   - If the agent ran and produced no commits *and* no merge happened: that's the actual no-op case — report `empty` or `no-changes`.
2. **Strip "no-op" from user-facing output entirely.** Use it in code, in commit messages, in internal logs — fine. Not in the dashboard, the status table, or the result summaries. Pick a word a non-engineer would read correctly.
