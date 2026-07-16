# Nudge headless agents to run builds/tests in the foreground, never background-and-poll

## Motivation

A headless chain phase implemented its plan correctly (unit tests green, diff to
spec) but the orchestrator marked it `no_op` / 0 commits and the work sat
uncommitted. Root cause from the transcript: the project's build was slow (~2 min),
so the agent sensibly backgrounded it and tried to wait with `sleep 30 && tail
<output>`. The sandbox **blocks that exact pattern** and tells the caller to "use
Monitor with an until-loop" — but the headless agent's allowed tools are only
`Read,Write,Edit,Glob,Grep,Bash`, so it has **no Monitor/polling tool**. Once it
backgrounded the slow build it had no legal way to wait for it, thrashed against the
block, and ended its turn with work on disk but never committed.

The trap is the intersection of (a) slow builds make backgrounding attractive,
(b) the sandbox forbids `sleep && tail`, (c) the agent has no polling tool. Removing
any one defuses it. The cheap, robust removal is (a): tell the agent to run
build/test commands in the foreground and let them block to completion.

## Do NOT

- Do NOT give the headless agent a Monitor/polling tool or change its
  `--allowedTools` — that widens the sandbox surface. The fix is a prompt nudge.
- Do NOT tell the agent to skip verification entirely. It should still run the
  plan's `## Verification` commands — just in the foreground.
- Do NOT touch the orchestrator's own post-agent verification gate (`phase_verify`),
  classification, or reporting in this task.
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.

## Plan

### 1. `skills/todo-task/execute-plan.sh` — foreground-build clause in the agent prompt

In `phase_run_session`'s `CLAUDE_PROMPT`, near the existing verification guidance
(currently line ~261, "When done, run the commands in the plan's ## Verification
section and fix any issues." followed by the non-destructive clause at ~262), add a
clause instructing foreground execution:

> Run build, test, and verification commands in the FOREGROUND and let them block to
> completion, even if they are slow. Do NOT run them in the background and poll with
> `sleep`/`tail` — you have no polling tool in this sandbox and that pattern is
> blocked, which will strand your work uncommitted. If a command is slow, wait for
> it.

Place it as a distinct sentence in the prompt string (mind the trailing `\`
line-continuations and the surrounding quoting — the prompt is one long
double-quoted string). Keep the wording tight.

## Files to Modify

- `skills/todo-task/execute-plan.sh` — add the foreground-build clause to `CLAUDE_PROMPT` in `phase_run_session`.

## Verification

```bash
# Script still parses (prompt string quoting intact).
bash -n skills/todo-task/execute-plan.sh && echo "execute-plan OK"

# The foreground nudge is present in the agent prompt.
grep -qi 'FOREGROUND' skills/todo-task/execute-plan.sh && echo "foreground clause present"
grep -qi 'no polling tool' skills/todo-task/execute-plan.sh && echo "no-polling-tool rationale present"

# The existing non-destructive clause is still there (not clobbered).
grep -qi 'non-destructive' skills/todo-task/execute-plan.sh && echo "non-destructive clause intact"
```

## Out of Scope

- Making the agent rely on fast unit tests and defer the heavy suite to the
  orchestrator gate (a plausible larger change the source draft floated; the
  foreground nudge is the crisp high-confidence fix and is enough).
- The reporting distinction between "did work but didn't commit" (salvageable) and a
  true no-op — the `salvageable` state and the "uncommitted in worktree (salvageable)"
  note already exist in `lib.sh`/`report.sh`; confirm during triage rather than
  re-implement here.
- Any `--allowedTools` or sandbox change.

## Notes

- This shares `execute-plan.sh` with the just-merged archive-sweep task (which added
  the non-destructive clause). Cut from current trunk so that clause is present; the
  verification asserts it survives.
- The nudge is defensive prompting, not a guarantee — but it removes the most
  common trigger (backgrounding a slow build) at near-zero cost and risk.
