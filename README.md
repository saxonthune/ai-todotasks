# ai-todotasks

A task lifecycle system for Claude Code. Write task ideas as markdown, triage them into executable specs, then launch headless Claude agents to implement them in isolated git worktrees.

## Install

From the root of your project:

```bash
curl -fsSL https://raw.githubusercontent.com/saxonthune/ai-todotasks/main/install.sh | bash
```

This copies the `todo-task` skill into `.claude/skills/` and scaffolds `.todo-tasks/` for task files. Every file is yours to edit.

To update an existing install:

```bash
curl -fsSL https://raw.githubusercontent.com/saxonthune/ai-todotasks/main/install.sh | bash -s -- --update
```

## Usage

```
/todo-task create <description>   # file a task idea
/todo-task triage <slug>          # refine into an executable spec
/todo-task execute <slug>         # launch a headless agent in a worktree
/todo-task status                 # what's running, done, pending
/todo-task monitor                # live dashboard
/todo-task archive                # clean up completed tasks
```

Tasks move through directories as they progress: `.todo-tasks/` → `.running/` → `.done/` → `.archived/`. No database, no service — `ls` is the dashboard.

## Configuration

Edit `.todo-tasks/task-config.sh` to set build and test commands for your project. Created from a template on install, never overwritten.

## Requirements

Bash, git, and the Claude CLI. Nothing else.
