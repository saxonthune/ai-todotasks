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
#   --force    Overwrite existing skill files non-interactively (never overwrites task-config.sh)
#   --update   Interactive update: show version info, release notes, per-file diffs with y/n prompts

FORCE=false
UPDATE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --update) UPDATE=true ;;
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
UPDATED_FILES=()

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

# ─── Skill files list ────────────────────────────────────────────────────────

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

# ─── Interactive update mode ──────────────────────────────────────────────────

if $UPDATE; then
  VERSION_FILE="${PROJECT_ROOT}/.todo-tasks/.version"
  AVAILABLE_VERSION_FILE="${SOURCE_DIR}/VERSION"

  INSTALLED_VER=""
  AVAILABLE_VER=""

  if [[ -f "$AVAILABLE_VERSION_FILE" ]]; then
    AVAILABLE_VER="$(cat "$AVAILABLE_VERSION_FILE" | tr -d '[:space:]')"
  fi

  if [[ -f "$VERSION_FILE" ]]; then
    INSTALLED_VER="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
    echo "Installed: ${INSTALLED_VER}"
    echo "Available: ${AVAILABLE_VER:-unknown}"
    echo ""

    if [[ -n "$AVAILABLE_VER" ]] && [[ "$INSTALLED_VER" == "$AVAILABLE_VER" ]]; then
      echo "Already up to date."
      exit 0
    fi
  else
    echo "No version found (pre-versioning install). Showing all changes."
    echo ""
  fi

  # Step B: Release notes
  CHANGELOG_SRC="${SOURCE_DIR}/CHANGELOG.md"
  if [[ -f "$CHANGELOG_SRC" ]] && [[ -n "$INSTALLED_VER" ]]; then
    # Print changelog sections with version > installed version
    NEW_SECTIONS=""
    in_section=false
    section_ver=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^##[[:space:]]([0-9]{4}\.[0-9]{2}\.[0-9]{2}[a-z]?)$ ]]; then
        section_ver="${BASH_REMATCH[1]}"
        if [[ "$section_ver" > "$INSTALLED_VER" ]]; then
          in_section=true
          NEW_SECTIONS+="${line}"$'\n'
        else
          in_section=false
        fi
      elif $in_section; then
        NEW_SECTIONS+="${line}"$'\n'
      fi
    done < "$CHANGELOG_SRC"

    if [[ -n "$NEW_SECTIONS" ]]; then
      echo "What's new:"
      echo "$NEW_SECTIONS"
    fi
  elif [[ -f "$CHANGELOG_SRC" ]] && [[ -z "$INSTALLED_VER" ]]; then
    echo "What's new:"
    cat "$CHANGELOG_SRC"
    echo ""
  fi

  # Step C: Per-file prompts
  # Detect if stdin is a terminal
  INTERACTIVE_STDIN=true
  if [[ ! -t 0 ]]; then
    INTERACTIVE_STDIN=false
    echo "Non-interactive stdin detected. Skipping existing files."
    echo "Run 'bash install.sh --update' locally for interactive mode, or use --force to overwrite all."
    echo ""
  fi

  for rel in "${SKILL_FILES[@]}"; do
    src="${SOURCE_DIR}/${rel}"
    filename="$(basename "$rel")"
    dst="${PROJECT_ROOT}/.claude/skills/todo-task/${filename}"

    if [[ ! -f "$src" ]]; then
      echo "WARNING: Source file not found: $src"
      continue
    fi

    if [[ ! -f "$dst" ]]; then
      # New file — auto-install without prompt
      cp "$src" "$dst"
      if [[ "$filename" == *.sh ]]; then
        chmod +x "$dst"
      fi
      INSTALLED_FILES+=(".claude/skills/todo-task/${filename} (new)")
    elif diff -q "$dst" "$src" >/dev/null 2>&1; then
      # Identical — skip silently
      SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
    else
      # Differs — show diff and prompt
      if $INTERACTIVE_STDIN; then
        echo "--- .claude/skills/todo-task/${filename}"
        diff -u "$dst" "$src" | head -20 || true
        echo ""
        read -r -p "Update .claude/skills/todo-task/${filename}? [y/N] " answer </dev/tty
        if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
          cp "$src" "$dst"
          if [[ "$filename" == *.sh ]]; then
            chmod +x "$dst"
          fi
          UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
        else
          SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
        fi
      else
        SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
      fi
    fi
  done

  # Step D: Write new version
  mkdir -p "${PROJECT_ROOT}/.todo-tasks"
  if [[ -n "$AVAILABLE_VER" ]]; then
    echo "$AVAILABLE_VER" > "${PROJECT_ROOT}/.todo-tasks/.version"
  fi

  # Update summary
  echo ""
  if [[ ${#INSTALLED_FILES[@]} -gt 0 ]]; then
    echo "New files installed:"
    for f in "${INSTALLED_FILES[@]}"; do
      echo "  $f"
    done
    echo ""
  fi

  if [[ ${#UPDATED_FILES[@]} -gt 0 ]]; then
    echo "Updated:"
    for f in "${UPDATED_FILES[@]}"; do
      echo "  $f"
    done
    echo ""
  fi

  if [[ ${#SKIPPED_FILES[@]} -gt 0 ]]; then
    echo "Skipped (unchanged or declined):"
    for f in "${SKIPPED_FILES[@]}"; do
      echo "  $f"
    done
    echo ""
  fi

  exit 0
fi

# ─── Copy skill files (fresh install or --force) ──────────────────────────────

for rel in "${SKILL_FILES[@]}"; do
  src="${SOURCE_DIR}/${rel}"
  filename="$(basename "$rel")"
  dst="${PROJECT_ROOT}/.claude/skills/todo-task/${filename}"

  if [[ ! -f "$src" ]]; then
    echo "WARNING: Source file not found: $src"
    continue
  fi

  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
    INSTALLED_FILES+=(".claude/skills/todo-task/${filename}")
  elif $FORCE; then
    cp "$src" "$dst"
    if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
    INSTALLED_FILES+=(".claude/skills/todo-task/${filename}")
  elif diff -q "$src" "$dst" >/dev/null 2>&1; then
    # Identical — skip silently
    SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
  elif [[ -t 0 ]]; then
    echo "--- .claude/skills/todo-task/${filename}"
    diff -u "$dst" "$src" | head -20 || true
    echo ""
    read -r -p "Update .claude/skills/todo-task/${filename}? [y/N] " answer </dev/tty
    if [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
      cp "$src" "$dst"
      if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
      UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
    else
      SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
    fi
  else
    # Non-interactive — can't prompt, skip
    SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
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
.version
GITIGNORE
  SCAFFOLDED_FILES+=(".todo-tasks/.gitignore")
fi

# Write installed version
VERSION_SRC="${SOURCE_DIR}/VERSION"
if [[ -f "$VERSION_SRC" ]]; then
  cp "$VERSION_SRC" "${PROJECT_ROOT}/.todo-tasks/.version"
fi

# ─── Output summary ──────────────────────────────────────────────────────────

if [[ ${#INSTALLED_FILES[@]} -gt 0 ]]; then
  echo "Installed:"
  for f in "${INSTALLED_FILES[@]}"; do
    echo "  $f"
  done
  echo ""
fi

if [[ ${#UPDATED_FILES[@]} -gt 0 ]]; then
  echo "Updated:"
  for f in "${UPDATED_FILES[@]}"; do
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
  echo "Skipped (unchanged or declined):"
  for f in "${SKIPPED_FILES[@]}"; do
    echo "  $f"
  done
  echo "  (pass --force to overwrite all)"
  echo ""
fi

echo "Next steps:"
echo "  1. Edit .todo-tasks/task-config.sh with your project's build/test commands"
echo "  2. Create a task:  /todo-task create <description>"
echo "  3. Triage it:      /todo-task triage <slug>"
echo "  4. Execute it:     /todo-task execute <slug>"
