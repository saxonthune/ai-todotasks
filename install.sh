#!/usr/bin/env bash
set -euo pipefail

# ─── ai-todotasks installer ─────────────────────────────────────────────────
# Usage (remote):
#   curl -fsSL https://raw.githubusercontent.com/saxonthune/ai-todotasks/main/install.sh | bash
#
# Usage (local, from repo root):
#   bash install.sh [--force|--update]
#
# Flags:
#   --force    Overwrite existing skill files (never overwrites task-config.sh)
#   --update   Alias for --force

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force|--update) FORCE=true ;;
  esac
done

PROJECT_ROOT="$(pwd)"

# ─── Validate git repo ───────────────────────────────────────────────────────

if [[ ! -d "${PROJECT_ROOT}/.git" ]] && [[ ! -f "${PROJECT_ROOT}/.git" ]]; then
  echo "ERROR: Not a git repository. Run this from your project root."
  exit 1
fi

# ─── Detect local vs remote mode ─────────────────────────────────────────────
# Local mode: script is running from within the source repo (skills/ dir present)
# Remote mode: script was piped from curl — download tarball from GitHub

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

REMOTE_MODE=true
if [[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/skills/todo-task/SKILL.md" ]]; then
  REMOTE_MODE=false
fi

# ─── Header ──────────────────────────────────────────────────────────────────

echo "ai-todotasks installer"
echo "======================"
echo ""

INSTALLED_FILES=()
SKIPPED_FILES=()
SCAFFOLDED_FILES=()

# ─── Acquire source files ────────────────────────────────────────────────────

TMPDIR_CREATED=""
SOURCE_DIR=""

cleanup() {
  if [[ -n "$TMPDIR_CREATED" ]]; then
    rm -rf "$TMPDIR_CREATED"
  fi
}
trap cleanup EXIT

if $REMOTE_MODE; then
  echo "Source: remote: github.com/saxonthune/ai-todotasks@main"
  echo ""

  TMPDIR_CREATED="$(mktemp -d)"
  TARBALL="${TMPDIR_CREATED}/ai-todotasks.tar.gz"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/saxonthune/ai-todotasks/archive/refs/heads/main.tar.gz" -o "$TARBALL"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "https://github.com/saxonthune/ai-todotasks/archive/refs/heads/main.tar.gz" -O "$TARBALL"
  else
    echo "ERROR: Neither curl nor wget found. Cannot download files."
    exit 1
  fi

  tar -xzf "$TARBALL" -C "$TMPDIR_CREATED"
  SOURCE_DIR="${TMPDIR_CREATED}/ai-todotasks-main"
else
  echo "Source: local: ${SCRIPT_DIR}/skills/todo-task"
  echo ""
  SOURCE_DIR="$SCRIPT_DIR"
fi

# ─── Copy skill files ─────────────────────────────────────────────────────────

SKILL_FILES=(
  "skills/todo-task/SKILL.md"
  "skills/todo-task/execute-plan.sh"
  "skills/todo-task/launch.sh"
  "skills/todo-task/launch-chain.sh"
  "skills/todo-task/execute-chain.sh"
  "skills/todo-task/status.sh"
  "skills/todo-task/monitor.sh"
)

mkdir -p "${PROJECT_ROOT}/.claude/skills/todo-task"

for rel in "${SKILL_FILES[@]}"; do
  src="${SOURCE_DIR}/${rel}"
  filename="$(basename "$rel")"
  dst="${PROJECT_ROOT}/.claude/skills/todo-task/${filename}"

  if [[ ! -f "$src" ]]; then
    echo "WARNING: Source file not found: $src"
    continue
  fi

  if [[ -f "$dst" ]] && ! $FORCE; then
    SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
  else
    cp "$src" "$dst"
    if [[ "$filename" == *.sh ]]; then
      chmod +x "$dst"
    fi
    INSTALLED_FILES+=(".claude/skills/todo-task/${filename}")
  fi
done

# ─── Scaffold .todo-tasks/ ───────────────────────────────────────────────────

mkdir -p "${PROJECT_ROOT}/.todo-tasks"

# task-config.sh — never overwrite (always preserve user config)
CONFIG_DST="${PROJECT_ROOT}/.todo-tasks/task-config.sh"
CONFIG_SRC="${SOURCE_DIR}/skills/todo-task/task-config.template.sh"

if [[ ! -f "$CONFIG_DST" ]]; then
  if [[ -f "$CONFIG_SRC" ]]; then
    cp "$CONFIG_SRC" "$CONFIG_DST"
  else
    echo "WARNING: task-config.template.sh not found, skipping task-config.sh"
  fi
  SCAFFOLDED_FILES+=(".todo-tasks/task-config.sh (edit this with your build/test commands)")
fi

# .gitignore — only create if missing
GITIGNORE_DST="${PROJECT_ROOT}/.todo-tasks/.gitignore"
if [[ ! -f "$GITIGNORE_DST" ]]; then
  cat > "$GITIGNORE_DST" << 'GITIGNORE'
.running/
.done/
.archived/
*.log
GITIGNORE
  SCAFFOLDED_FILES+=(".todo-tasks/.gitignore")
fi

# ─── Output summary ──────────────────────────────────────────────────────────

if [[ ${#INSTALLED_FILES[@]} -gt 0 ]]; then
  echo "Installed:"
  for f in "${INSTALLED_FILES[@]}"; do
    echo "  $f"
  done
  echo ""
fi

if [[ ${#SCAFFOLDED_FILES[@]} -gt 0 ]]; then
  echo "Scaffolded:"
  for f in "${SCAFFOLDED_FILES[@]}"; do
    echo "  $f"
  done
  echo ""
fi

if [[ ${#SKIPPED_FILES[@]} -gt 0 ]]; then
  echo "Skipped (already exist):"
  for f in "${SKIPPED_FILES[@]}"; do
    echo "  $f"
  done
  echo "  (pass --force or --update to overwrite)"
  echo ""
fi

echo "Next steps:"
echo "  1. Edit .todo-tasks/task-config.sh with your project's build/test commands"
echo "  2. Create a task:  /todo-task create <description>"
echo "  3. Groom it:       /todo-task groom <slug>"
echo "  4. Execute it:     /todo-task execute <slug>"
