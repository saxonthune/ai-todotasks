#!/usr/bin/env bash
set -euo pipefail

# ─── ai-todotasks installer ─────────────────────────────────────────────────
# Installs the todo-task system into a project by creating symlinks
# from .claude/ to the ai-todotasks source directory.
#
# Usage:
#   From your project root:
#     /path/to/ai-todotasks/install.sh
#
#   Or with git subtree (after adding):
#     bash .todo-task-system/install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(pwd)"

echo "═══ ai-todotasks installer ═══"
echo ""
echo "Source:  ${SCRIPT_DIR}"
echo "Target:  ${PROJECT_ROOT}"
echo ""

# ─── Validate ────────────────────────────────────────────────────────────────

if [[ ! -d "${PROJECT_ROOT}/.git" ]]; then
  echo "ERROR: Not a git repository. Run this from your project root."
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/skills/todo-task/SKILL.md" ]]; then
  echo "ERROR: Can't find ai-todotasks source files at ${SCRIPT_DIR}"
  exit 1
fi

# ─── Create .claude directories ──────────────────────────────────────────────

mkdir -p "${PROJECT_ROOT}/.claude/skills"
mkdir -p "${PROJECT_ROOT}/.claude/agents"

# ─── Symlink skills ──────────────────────────────────────────────────────────

# Compute relative path from .claude/skills/ to the source
SKILLS_REL=$(python3 -c "import os.path; print(os.path.relpath('${SCRIPT_DIR}/skills', '${PROJECT_ROOT}/.claude/skills'))" 2>/dev/null \
  || python -c "import os.path; print(os.path.relpath('${SCRIPT_DIR}/skills', '${PROJECT_ROOT}/.claude/skills'))" 2>/dev/null \
  || realpath --relative-to="${PROJECT_ROOT}/.claude/skills" "${SCRIPT_DIR}/skills")

AGENTS_REL=$(python3 -c "import os.path; print(os.path.relpath('${SCRIPT_DIR}/agents', '${PROJECT_ROOT}/.claude/agents'))" 2>/dev/null \
  || python -c "import os.path; print(os.path.relpath('${SCRIPT_DIR}/agents', '${PROJECT_ROOT}/.claude/agents'))" 2>/dev/null \
  || realpath --relative-to="${PROJECT_ROOT}/.claude/agents" "${SCRIPT_DIR}/agents")

# todo-task skill
if [[ -L "${PROJECT_ROOT}/.claude/skills/todo-task" ]]; then
  echo "Updating symlink: .claude/skills/todo-task"
  rm "${PROJECT_ROOT}/.claude/skills/todo-task"
elif [[ -d "${PROJECT_ROOT}/.claude/skills/todo-task" ]]; then
  echo "WARNING: .claude/skills/todo-task exists as a directory. Skipping (remove it manually to use symlink)."
  SKIP_SKILL=true
fi

if [[ "${SKIP_SKILL:-}" != "true" ]]; then
  ln -s "${SKILLS_REL}/todo-task" "${PROJECT_ROOT}/.claude/skills/todo-task"
  echo "Linked: .claude/skills/todo-task"
fi

# execute-plan scripts
if [[ -L "${PROJECT_ROOT}/.claude/skills/execute-plan" ]]; then
  echo "Updating symlink: .claude/skills/execute-plan"
  rm "${PROJECT_ROOT}/.claude/skills/execute-plan"
elif [[ -d "${PROJECT_ROOT}/.claude/skills/execute-plan" ]]; then
  echo "WARNING: .claude/skills/execute-plan exists as a directory. Skipping (remove it manually to use symlink)."
  SKIP_EXEC=true
fi

if [[ "${SKIP_EXEC:-}" != "true" ]]; then
  ln -s "${SKILLS_REL}/execute-plan" "${PROJECT_ROOT}/.claude/skills/execute-plan"
  echo "Linked: .claude/skills/execute-plan"
fi

# plan-executor agent
if [[ -L "${PROJECT_ROOT}/.claude/agents/plan-executor.md" ]]; then
  rm "${PROJECT_ROOT}/.claude/agents/plan-executor.md"
elif [[ -f "${PROJECT_ROOT}/.claude/agents/plan-executor.md" ]]; then
  echo "WARNING: .claude/agents/plan-executor.md exists as a file. Skipping."
  SKIP_AGENT=true
fi

if [[ "${SKIP_AGENT:-}" != "true" ]]; then
  ln -s "${AGENTS_REL}/plan-executor.md" "${PROJECT_ROOT}/.claude/agents/plan-executor.md"
  echo "Linked: .claude/agents/plan-executor.md"
fi

# ─── Create task-config.sh if missing ────────────────────────────────────────

# task-config.sh must be a real file (not symlinked) because it's project-specific.
# It lives alongside the symlinked execute-plan scripts, so we need it in the
# actual resolved directory.
CONFIG_TARGET="${PROJECT_ROOT}/.claude/skills/execute-plan/task-config.sh"
# Since execute-plan is a symlink, task-config.sh needs to go in the source dir
# OR we need a project-local override. For now, check if one exists in the source.
# The real task-config.sh should be project-local, not in the shared repo.

# We put task-config.sh in the project root's .claude/skills/execute-plan/
# But that's a symlink... so we need a different approach.
# Solution: the scripts look for task-config.sh via SCRIPT_DIR, which resolves
# through the symlink to the ai-todotasks source. We need the project to have
# its own config that the scripts can find.
#
# Best approach: scripts check for a project-local config first.
# For now, we'll note this in the output.

if [[ ! -f "${PROJECT_ROOT}/todo-tasks/task-config.sh" ]]; then
  mkdir -p "${PROJECT_ROOT}/todo-tasks"
  cp "${SCRIPT_DIR}/skills/execute-plan/task-config.template.sh" "${PROJECT_ROOT}/todo-tasks/task-config.sh"
  echo ""
  echo "Created: todo-tasks/task-config.sh (from template)"
  echo "  >>> Edit this file to set your project's build/test commands <<<"
fi

# ─── Create todo-tasks directory ─────────────────────────────────────────────

mkdir -p "${PROJECT_ROOT}/todo-tasks"

if [[ ! -f "${PROJECT_ROOT}/todo-tasks/.gitignore" ]]; then
  cat > "${PROJECT_ROOT}/todo-tasks/.gitignore" << 'EOF'
# Lifecycle directories — local-only state
.running/
.done/
.archived/

# Logs
*.log
EOF
  echo "Created: todo-tasks/.gitignore"
fi

echo ""
echo "═══ Installation complete ═══"
echo ""
echo "Next steps:"
echo "  1. Edit todo-tasks/task-config.sh with your project's build/test commands"
echo "  2. Create a task:  /todo-task create <description>"
echo "  3. Groom it:       /todo-task groom <slug>"
echo "  4. Execute it:     /todo-task execute <slug>"
echo ""
echo "Note: The execute-plan scripts source task-config.sh from their own"
echo "directory (SCRIPT_DIR). Since that's a symlink to the shared repo,"
echo "you may need to update the scripts to also check for a project-local"
echo "config. See intention.md for the planned fix."
