#!/usr/bin/env bash
# ─── Task System Configuration ───────────────────────────────────────────────
# Project-specific settings for novelisual.

# Prefix for agent worktree directories (created alongside the repo root)
WORKTREE_PREFIX="agent"

# Command to install dependencies in a fresh worktree
INSTALL_CMD="make install"

# Command to verify the implementation (must exit 0 on success)
BUILD_CMD="make lint"
TEST_CMD="make test"

# Budget caps for headless Claude sessions (USD)
MAX_BUDGET="5.00"
RETRY_BUDGET="3.00"

# Maximum retry attempts when build/test fails
MAX_RETRIES=4
