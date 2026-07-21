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
#   --update   Interactive update: release notes plus per-file diffs with y/n prompts
#
# Every mode reports the version it is installing from and to.

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

# ─── Layout scaffolding (shared by fresh, --force, and --update) ──────────────
# Creates the tracked lifecycle dirs + the gitignored inbox, and OVERWRITES the
# project-local .todo-tasks/.gitignore (tool-managed — this is how new ignore
# rules propagate on update). The repo's ROOT .gitignore is never touched.
# task-config.sh is handled separately (preserve-only — it is user config).
scaffold_layout() {
  mkdir -p "${PROJECT_ROOT}/.todo-tasks"

  # Tracked lifecycle directories. Git won't track empty dirs, so seed each with
  # a .gitkeep. Lifecycle is derived from file presence within these stable
  # categories — never from moving files between directories.
  local d dir
  for d in tasks results chains epics; do
    dir="${PROJECT_ROOT}/.todo-tasks/${d}"
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      touch "${dir}/.gitkeep"
      SCAFFOLDED_FILES+=(".todo-tasks/${d}/")
    fi
  done

  # inbox/ holds untriaged drafts (filed by `create`). Gitignored and local-only
  # — a filed idea is not yet work and never touches git history.
  mkdir -p "${PROJECT_ROOT}/.todo-tasks/inbox"

  # Inner .gitignore — always overwrite so updated ignore rules land. This is the
  # tool's file, distinct from the repo's root .gitignore (which we never edit).
  local gitignore_dst="${PROJECT_ROOT}/.todo-tasks/.gitignore"
  local existed=true
  [[ -f "$gitignore_dst" ]] || existed=false
  cat > "$gitignore_dst" << 'GITIGNORE'
inbox/
.running/
.archived/
*.log
.version
GITIGNORE
  if [[ "$existed" == "false" ]]; then
    SCAFFOLDED_FILES+=(".todo-tasks/.gitignore")
  else
    UPDATED_FILES+=(".todo-tasks/.gitignore")
  fi
}

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

# ─── Version transition ──────────────────────────────────────────────────────
# Read before anything writes .version, and report in every mode — a stale install
# is otherwise invisible, since .version is gitignored and shows up in no diff.

VERSION_FILE="${PROJECT_ROOT}/.todo-tasks/.version"

INSTALLED_VER=""
AVAILABLE_VER=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VER="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -f "${SOURCE_DIR}/VERSION" ]] && AVAILABLE_VER="$(tr -d '[:space:]' < "${SOURCE_DIR}/VERSION")"

if [[ -z "$INSTALLED_VER" ]]; then
  echo "Fresh install: ${AVAILABLE_VER:-unknown}"
elif [[ "$INSTALLED_VER" == "$AVAILABLE_VER" ]]; then
  echo "Installed version ${INSTALLED_VER} is already current."
else
  echo "Updating: ${INSTALLED_VER} → ${AVAILABLE_VER:-unknown}"
fi
echo ""

# write_version
# Writes .version and reports what landed. Called once per run, after the files copy.
write_version() {
  if [[ -z "$AVAILABLE_VER" ]]; then
    echo "No VERSION file in source — left .todo-tasks/.version unchanged."
    return
  fi
  echo "$AVAILABLE_VER" > "$VERSION_FILE"
  echo "Wrote .todo-tasks/.version: ${AVAILABLE_VER}"
}

# ─── Skill files list ────────────────────────────────────────────────────────

SKILL_FILES=(
  "skills/todo-task/SKILL.md"
  "skills/todo-task/SETUP.md"
  "skills/todo-task/create.md"
  "skills/todo-task/triage.md"
  "skills/todo-task/execute.md"
  "skills/todo-task/REFERENCE.md"
  "skills/todo-task/lib.sh"
  "skills/todo-task/report.sh"
  "skills/todo-task/execute-plan.sh"
  "skills/todo-task/launch.sh"
  "skills/todo-task/launch-chain.sh"
  "skills/todo-task/execute-chain.sh"
  "skills/todo-task/status.sh"
  "skills/todo-task/monitor.sh"
  "skills/todo-task/list-pending.sh"
  "skills/todo-task/list-drafts.sh"
  "skills/todo-task/archive.sh"
)

mkdir -p "${PROJECT_ROOT}/.claude/skills/todo-task"

# ─── Interactive update mode ──────────────────────────────────────────────────

if $UPDATE; then
  if [[ -z "$INSTALLED_VER" ]]; then
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
  YES_ALL=false
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
        if $YES_ALL; then
          cp "$src" "$dst"
          if [[ "$filename" == *.sh ]]; then
            chmod +x "$dst"
          fi
          UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
        else
          echo "--- .claude/skills/todo-task/${filename}"
          diff -u "$dst" "$src" | head -20 || true
          echo ""
          read -r -p "Update .claude/skills/todo-task/${filename}? [y/N/a=yes to all] " answer </dev/tty
          if [[ "$answer" == "a" ]] || [[ "$answer" == "A" ]]; then
            YES_ALL=true
            cp "$src" "$dst"
            if [[ "$filename" == *.sh ]]; then
              chmod +x "$dst"
            fi
            UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
          elif [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
            cp "$src" "$dst"
            if [[ "$filename" == *.sh ]]; then
              chmod +x "$dst"
            fi
            UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
          else
            SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
          fi
        fi
      else
        SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
      fi
    fi
  done

  # Step D: Scaffold/refresh layout (new dirs + refreshed inner .gitignore).
  # Existing installs picking up this update get the new tracked directories and
  # the latest ignore rules.
  scaffold_layout

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

  write_version

  exit 0
fi

# ─── Copy skill files (fresh install or --force) ──────────────────────────────

YES_ALL=false
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
    if $YES_ALL; then
      cp "$src" "$dst"
      if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
      UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
    else
      echo "--- .claude/skills/todo-task/${filename}"
      diff -u "$dst" "$src" | head -20 || true
      echo ""
      read -r -p "Update .claude/skills/todo-task/${filename}? [y/N/a=yes to all] " answer </dev/tty
      if [[ "$answer" == "a" ]] || [[ "$answer" == "A" ]]; then
        YES_ALL=true
        cp "$src" "$dst"
        if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
        UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
      elif [[ "$answer" == "y" ]] || [[ "$answer" == "Y" ]]; then
        cp "$src" "$dst"
        if [[ "$filename" == *.sh ]]; then chmod +x "$dst"; fi
        UPDATED_FILES+=(".claude/skills/todo-task/${filename}")
      else
        SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
      fi
    fi
  else
    # Non-interactive — can't prompt, skip
    SKIPPED_FILES+=(".claude/skills/todo-task/${filename}")
  fi
done

# ─── Scaffold .todo-tasks/ ───────────────────────────────────────────────────

mkdir -p "${PROJECT_ROOT}/.todo-tasks"

# Lifecycle dirs, inbox, and the tool-managed inner .gitignore (always refreshed).
scaffold_layout

# task-config.sh — never overwrite (always preserve user config)
CONFIG_DST="${PROJECT_ROOT}/.todo-tasks/task-config.sh"
CONFIG_SRC="${SOURCE_DIR}/skills/todo-task/task-config.template.sh"

if [[ ! -f "$CONFIG_DST" ]]; then
  if [[ -f "$CONFIG_SRC" ]]; then
    cp "$CONFIG_SRC" "$CONFIG_DST"
  else
    echo "WARNING: task-config.template.sh not found, skipping task-config.sh"
  fi
  SCAFFOLDED_FILES+=(".todo-tasks/task-config.sh (operational settings: budget, retries, worktree prefix)")
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

write_version
echo ""

echo "Next steps:"
echo "  1. Review .todo-tasks/task-config.sh (budget, retries, worktree prefix)"
echo "  2. Create a task:  /todo-task create <description>"
echo "  3. Triage it:      /todo-task triage <slug>"
echo "  4. Execute it:     /todo-task execute <slug>"
