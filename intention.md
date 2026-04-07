# ai-todotasks — Intention

## What this is

A task lifecycle system for Claude Code. You write task ideas as markdown files, triage them into executable specs, then launch headless Claude agents to implement them in isolated git worktrees. The system tracks state by moving files through directories (pending → running → done → archived).

It was extracted from [tinyForum](https://github.com/saxonthune/tinyForum) where it was developed and battle-tested.

## What it does

- **Create**: quickly file a task idea as a markdown file
- **Triage**: interactively refine a task into a spec that a headless agent can execute without asking questions — research the codebase, present a briefing, resolve design decisions with the user, then write the executable plan
- **Execute**: launch a headless Claude agent in a git worktree that implements the plan, verifies build/tests, retries on failure, and squash-merges on success
- **Chain**: run multiple plans sequentially with resume support
- **Status/Monitor**: comprehensive reporting and live dashboards

## How it's installed

Users add this repo as a **git subtree** in their project, then run `install.sh` which creates **symlinks** from `.claude/` into the subtree directory.

```bash
# Add to project
git subtree add --prefix=.todo-task-system git@github.com:saxonthune/ai-todotasks.git main --squash

# Install (creates symlinks + todo-tasks/ directory)
bash .todo-task-system/install.sh

# Push a fix back upstream
git subtree push --prefix=.todo-task-system git@github.com:saxonthune/ai-todotasks.git main

# Pull updates from upstream
git subtree pull --prefix=.todo-task-system git@github.com:saxonthune/ai-todotasks.git main --squash
```

Symlinks mean edits flow through to the subtree directory, so `git subtree push` sends fixes upstream without a copy step.

### What gets symlinked (shared, generic)

```
.claude/skills/todo-task/       → .todo-task-system/skills/todo-task/
.claude/skills/execute-plan/    → .todo-task-system/skills/execute-plan/
.claude/agents/plan-executor.md → .todo-task-system/agents/plan-executor.md
```

### What stays project-local

```
todo-tasks/                  — task files (the actual work)
todo-tasks/task-config.sh    — project-specific build/test commands, budgets
todo-tasks/.gitignore        — ignores .running/, .done/, .archived/, *.log
```

## Work needed before this is ready

### 1. Fix task-config.sh resolution

**Problem**: The shell scripts find `task-config.sh` via `SCRIPT_DIR` (the directory the script lives in). When `execute-plan/` is a symlink, `SCRIPT_DIR` resolves to the ai-todotasks source directory — not the project. So the scripts won't find the project-local `task-config.sh`.

**Fix**: Update the scripts to check for config in this order:
1. `${REPO_ROOT}/todo-tasks/task-config.sh` (project-local)
2. `${SCRIPT_DIR}/task-config.sh` (fallback to source dir, for development)
3. Fail with a clear error if neither exists

This is the most important fix — without it, the system won't pick up project-specific build commands.

### 2. Remove task-config.sh from the symlinked directory

Once the resolution order is fixed, `task-config.sh` shouldn't ship in `skills/execute-plan/` at all (only the template should exist). The install script already copies the template to `todo-tasks/task-config.sh`. The scripts should never source config from their own directory in production — only from the project root.

### 3. Remove the tinyForum-specific reference in SKILL.md

The triage step references `.carta/MANIFEST.md` which is tinyForum-specific. This line should either be removed or made conditional (check if the file exists before referencing it).

**Edit**: In `skills/todo-task/SKILL.md`, Step 3 of the triage mode currently says:
> 1. **Check `.carta/MANIFEST.md`** — use the tag index to map task keywords to relevant docs.

This was already removed in the extracted version. Verify it's gone.

### 4. Make install.sh idempotent and robust

Current install script works for first install. Needs polish:
- Running it twice should be safe (update symlinks, don't duplicate config)
- Handle the case where `.claude/` has other content (don't clobber)
- Detect if running inside a subtree vs. from an external path and adjust relative paths accordingly

### 5. Add uninstall.sh

Remove symlinks and optionally remove `todo-tasks/` scaffolding. Should warn before deleting task files.

### 6. Add a version marker

Write a `.todo-task-version` file during install so users can check if they're up to date. The install script could compare versions and warn if the installed version is behind the source.

### 7. Write a README

Cover:
- What this is and why it exists
- Prerequisites (Claude Code CLI, git)
- Installation via git subtree
- Quick start (create → triage → execute → status)
- Configuration (task-config.sh options)
- Contributing fixes back upstream

### 8. Test with a fresh project

Install into a blank repo and run the full lifecycle (create, triage, execute, status, archive) to verify everything works end-to-end without tinyForum-specific assumptions.

## Design decisions

- **Symlinks over copies**: edits in the consuming repo flow through to the subtree, making upstream pushes trivial. Claude Code confirms it follows symlinks for skill/agent discovery.
- **Git subtree over submodules**: files are real files in the repo history, no `.gitmodules` to manage, contributors don't need to know about the subtree.
- **Config lives in `todo-tasks/`**: keeps all task-related state in one directory. The alternative (`.claude/skills/execute-plan/task-config.sh`) doesn't work with symlinks.
- **Shell scripts over Node/Python**: zero dependencies beyond bash, git, and the Claude CLI. Works in any project regardless of language.
