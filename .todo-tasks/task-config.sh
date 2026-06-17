#!/usr/bin/env bash
# ─── Task System Configuration ───────────────────────────────────────────────
# Project-specific settings for ai-todotasks itself.

# Prefix for agent worktree directories (created alongside the repo root).
# Worktrees are named "<prefix>-<repo>-<slug>". Defaults to "todotask".
# WORKTREE_PREFIX="todotask"

# Command to install dependencies in a fresh worktree
INSTALL_CMD="true"

# Command to verify the implementation (must exit 0 on success)
BUILD_CMD="bash -n skills/todo-task/*.sh"
TEST_CMD="true"

# Budget caps for headless Claude sessions (USD)
MAX_BUDGET="5.00"
RETRY_BUDGET="3.00"

# Maximum agent turns per headless session
MAX_TURNS=100

# Maximum retry attempts when build/test fails
MAX_RETRIES=2
