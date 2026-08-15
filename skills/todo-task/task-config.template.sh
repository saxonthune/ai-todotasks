#!/usr/bin/env bash
# ─── Task System Configuration ───────────────────────────────────────────────
# Project-specific settings for the todo-task execution system.
# Sourced by execute-plan.sh and status.sh.
#
# Copy this file to your project:
#   .todo-tasks/task-config.sh
# Then edit the values below to match your project.
#
# Per-task verification commands live in each plan's ## Verification section
# (a fenced bash block). This file is for project-wide operational settings only.

# Prefix for agent worktree directories (created alongside the repo root).
# Worktrees are named "<prefix>-<repo>-<slug>" so they don't collide across
# repos. Defaults to "todotask"; uncomment to override.
# WORKTREE_PREFIX="todotask"

# Budget caps for headless Claude sessions (USD)
MAX_BUDGET="10.00"
RETRY_BUDGET="6.00"

# Maximum agent turns per headless session
MAX_TURNS=200

# Maximum retry attempts when build/test fails
MAX_RETRIES=4

# Which headless agent provider to launch. Selects
# skills/todo-task/providers/<name>.sh. Defaults to "claude"; only "claude"
# ships today — a future adapter (e.g. codex) drops in as a new file with no
# other changes needed.
# TODO_TASK_PROVIDER="claude"
