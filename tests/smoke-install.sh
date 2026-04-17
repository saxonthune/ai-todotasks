#!/usr/bin/env bash
# Smoke test: run install.sh in a temp repo and assert every expected file lands.
# Usage: bash tests/smoke-install.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=""
FAILURES=0

cleanup() {
  if [[ -n "$TMPDIR_TEST" ]]; then
    rm -rf "$TMPDIR_TEST"
  fi
}
trap cleanup EXIT

assert_file() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (expected '${expected}', got '${actual}')"
    FAILURES=$((FAILURES + 1))
  fi
}

# Create a throwaway git repo
TMPDIR_TEST="$(mktemp -d)"
git -C "$TMPDIR_TEST" init -q

# Run install from within the temp repo (local mode: install.sh finds skills/ dir)
(cd "$TMPDIR_TEST" && bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1)

SKILL_DIR="${TMPDIR_TEST}/.claude/skills/todo-task"

# Assert every file in SKILL_FILES landed (mirrors the array in install.sh)
assert_file "SKILL.md installed"        "${SKILL_DIR}/SKILL.md"
assert_file "lib.sh installed"          "${SKILL_DIR}/lib.sh"
assert_file "execute-plan.sh installed" "${SKILL_DIR}/execute-plan.sh"
assert_file "launch.sh installed"       "${SKILL_DIR}/launch.sh"
assert_file "launch-chain.sh installed" "${SKILL_DIR}/launch-chain.sh"
assert_file "execute-chain.sh installed" "${SKILL_DIR}/execute-chain.sh"
assert_file "status.sh installed"       "${SKILL_DIR}/status.sh"
assert_file "monitor.sh installed"      "${SKILL_DIR}/monitor.sh"

# Belt-and-suspenders: lib.sh specifically (regression for the install bug)
assert_file "lib.sh exists (regression)" "${SKILL_DIR}/lib.sh"

# Scaffolded config
assert_file "task-config.sh scaffolded" "${TMPDIR_TEST}/.todo-tasks/task-config.sh"

# Version file matches repo VERSION
EXPECTED_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
INSTALLED_VERSION="$(tr -d '[:space:]' < "${TMPDIR_TEST}/.todo-tasks/.version" 2>/dev/null || echo "")"
assert_eq ".version matches VERSION" "$INSTALLED_VERSION" "$EXPECTED_VERSION"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All assertions passed."
  exit 0
else
  echo "${FAILURES} assertion(s) failed."
  exit 1
fi
