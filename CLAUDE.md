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
.todo-tasks/.gitignore        — ignores .running/, .done/, .archived/, *.log
```

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

- All scripts must work when copied into a project (no references back to this repo)
- `task-config.sh` resolution order: `${REPO_ROOT}/.todo-tasks/task-config.sh` first, then fall back to `${SCRIPT_DIR}/task-config.sh`
- Test changes by installing into a scratch repo and running the full lifecycle
- The `agents/` directory and `skills/execute-plan/` are legacy — all functionality lives in `skills/todo-task/`

## Searching and reading files

Use the dedicated tools — they're allowlisted and don't trigger approval prompts. Shell pipelines that wrap file access (`cd`, `xargs`, `sh -c`, output redirection, `find … | cat`) do trigger prompts. This list grows as new anti-patterns surface.

- DON'T `find … -name '*.sh' | xargs cat` — DO use Glob to list, then Read each file (Read takes parallel calls).
- DON'T `cd some/dir && cmd` — DO pass absolute paths; for unavoidable multi-step shell use a single subshell `(cd dir && cmd)`.
- DON'T `find … | xargs -I{} sh -c '…'` — DO use Glob/Grep, or Read files individually.
- DON'T `grep -r pattern path/` — DO use the Grep tool.
- DON'T `cat file` to read — DO use the Read tool.
- DON'T loop the shell over files (`for f in …; do cat $f; done`) — variable expansion blocks auto-approval; DO issue parallel Read calls, one per file.
- DON'T lead a command with `cd` (e.g. `cd repo && grep … && echo …`) — mixing a directory change with output redirection bypasses path resolution and blocks auto-approval; DO pass absolute paths to each command, or wrap unavoidable multi-step shell in a single subshell `(cd dir && cmd)`.
