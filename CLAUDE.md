# ai-todotasks

A task lifecycle system for Claude Code. Write task ideas as markdown, triage them into executable specs, then launch headless Claude agents to implement them in isolated git worktrees.

## Design principles

### Malleable installs

Users get real files they own, not symlinks or locked dependencies. The install script copies files into the project — users can read, modify, and extend anything. This is a DIY philosophy for the AI era: ship a great default, but never prevent someone from making it theirs.

Implications:
- Never assume files are unmodified from upstream
- Scripts should be readable and self-contained — no hidden magic
- Config is always project-local, never sourced from a remote location
- The install script should be re-runnable (update scripts, preserve config)

### File-based state machine

Task lifecycle is managed by moving markdown files through directories:
```
.todo-tasks/           — pending tasks (triaged specs ready to execute)
.todo-tasks/.running/  — currently being executed by an agent
.todo-tasks/.done/     — completed successfully
.todo-tasks/.archived/ — cleaned up
```

No database, no service, no lock files. `ls` is your dashboard.

### One commit per task

A completed task adds **exactly one commit** to trunk: the squash-merge of the agent's
work, `feat: <slug> (agent)`. Nothing else in the lifecycle commits.

This is why everything under `.todo-tasks/` except `epics/` and `task-config.sh` is
gitignored. Specs and results are real files with real durability — they are copied into
`.archived/` when a task is archived — but they never enter git history, so they cannot
generate the spec, merge-result, and archive-deletion commits that used to bracket every
task. Those three added files that the archive then deleted; their net effect on the tree
was nothing but log noise.

Two consequences to preserve when editing:

- A worktree gets its spec by **copy**, never by commit. `git worktree add` produces a
  fresh checkout that carries no ignored files, so `execute-plan.sh` copies the spec into
  the task worktree and `execute-chain.sh` copies every phase spec into the chain worktree.
  Forget the chain copy and phase 2 onward cannot find its spec.
- Never test "did this merge land?" by probing for a committed result file. Compare the
  trees instead — see `chain_merged_on_trunk` in `lib.sh`.

### Single skill, no agents

Everything is accessed through one skill: `/todo-task`. Subcommands (create, triage, execute, status, monitor, archive) route to the right behavior. Shell scripts for execution live inside the skill directory. No separate agent definition — `execute-plan.sh` invokes `claude -p` directly with an inline prompt.

### Zero dependencies

The system requires only bash, git, and the Claude CLI. No runtimes, no package managers, no build steps. Works in any project regardless of language.

## Repository structure

```
skills/todo-task/
  SKILL.md                    — skill definition, routes all subcommands
  execute-plan.sh             — core: run agent in worktree, verify, merge
  launch.sh                   — launch a single plan in background
  launch-chain.sh             — launch sequential chain of plans
  execute-chain.sh            — chain runner with resume support
  status.sh                   — report on running/done/pending tasks
  monitor.sh                  — live dashboard
  task-config.template.sh     — template copied to project on install
install.sh                    — remote installer (curl | bash)
```

## What gets installed into a project

```
.claude/skills/todo-task/     — the skill (SKILL.md + shell scripts)
.todo-tasks/                  — task files and lifecycle directories
.todo-tasks/task-config.sh    — project-specific build/test commands
.todo-tasks/.gitignore        — ignores tasks/, results/, chains/, inbox/, .running/, .done/, .archived/, *.log
```

## ⚠️ Source of truth vs. installed copy — READ THIS BEFORE EDITING THE SKILL

This repo **dogfoods its own skill**, so two copies of every skill file exist. They are
NOT the same role:

| Path | Role | Tracked? |
|------|------|----------|
| `skills/todo-task/` | **THE TEMPLATE — the source of truth. ALL edits go here.** | ✅ tracked in git |
| `.claude/skills/todo-task/` | The **installed copy** this repo runs when you invoke `/todo-task`. A dogfood artifact. | ❌ gitignored (`.claude/` is in the root `.gitignore`) |

Rules that follow from this — do not violate them:

- **Edit `skills/todo-task/` only.** It is the tracked source. Never hand-edit
  `.claude/skills/todo-task/` expecting it to persist — it is gitignored, so the change is
  invisible to git and will be lost on the next reinstall.
- **Task specs MUST name `skills/todo-task/…` in "Files to Modify" and verification** —
  never `.claude/skills/…`. The installed copy is gitignored, so it is **absent from the
  git worktrees** that headless agents run in: a spec pointing at `.claude/skills/…` will
  not find the file in the worktree, and any file an agent writes there is untracked and
  never merges back.
- **After changing the skill, refresh the installed copy** so the running `/todo-task`
  actually uses the new code:
  ```bash
  bash install.sh --force        # re-copy template → .claude/skills/todo-task/
  ```
  (`install.sh` copies `skills/todo-task/` → `.claude/skills/todo-task/`. The two are real,
  separate copies so this repo exercises the same install path every other project gets —
  do not link them, which would hide install bugs here. `install.sh` refuses to run when the
  destination resolves to the source.)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/saxonthune/ai-todotasks/main/install.sh | bash
```

This copies files into your project. You own every file it creates.

## Configuration

Edit `.todo-tasks/task-config.sh` to set your project's build and test commands. This file is created from a template on install and never overwritten on update.

## Task lifecycle

1. **Create** — `/todo-task create <description>` files a task idea
2. **Triage** — `/todo-task triage <slug>` refines it into an executable spec
3. **Execute** — `/todo-task execute <slug>` launches a headless agent
4. **Status** — `/todo-task status` shows what's running/done/pending
5. **Archive** — `/todo-task archive` cleans up completed tasks

## Working on this repo

- **Edit the template `skills/todo-task/`, never the gitignored install `.claude/skills/todo-task/`** — see the "Source of truth vs. installed copy" section above. Reinstall (`bash install.sh --force`) to refresh the running copy after a change.
- All scripts must work when copied into a project (no references back to this repo)
- `task-config.sh` resolution order: `${REPO_ROOT}/.todo-tasks/task-config.sh` first, then fall back to `${SCRIPT_DIR}/task-config.sh`
- Test changes by installing into a scratch repo and running the full lifecycle
- The `agents/` directory and `skills/execute-plan/` are legacy — all functionality lives in `skills/todo-task/`

## Searching and reading files

Shell hygiene rules — use the dedicated tools and avoid command forms that
trigger approval prompts — live in the user-level `~/.claude/CLAUDE.md`, shared
across all repos.
