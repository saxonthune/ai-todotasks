#!/usr/bin/env bash
# Regression for saxonthune/ai-todotasks#2:
# "## Surface Deviations" bodies that start with "None." plus confirming prose
# must classify as none, not declared.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/skills/todo-task/lib.sh"

failures=0

assert_state() {
  local label="$1" body="$2" want="$3"
  local got
  got="$(surface_deviation_state "$body")"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $label -> $want"
  else
    echo "FAIL: $label (expected '$want', got '$got')"
    failures=$((failures + 1))
  fi
}

# Extract the same way execute-plan.sh does, then classify.
classify_result() {
  local claude_result="$1"
  local dev_body
  dev_body=$(printf '%s\n' "$claude_result" | awk '
    /^## Surface Deviations[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ')
  surface_deviation_state "$dev_body"
}

assert_result() {
  local label="$1" result="$2" want="$3"
  local got
  got="$(classify_result "$result")"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $label -> $want"
  else
    echo "FAIL: $label (expected '$want', got '$got')"
    failures=$((failures + 1))
  fi
}

# Helper: exact None / empty
assert_state "bare None." $'None.' none
assert_state "bare None" $'None' none
assert_state "empty body" '' none
assert_state "blank lines only" $'\n\n' none

# Issue #2 repro: None. plus confirming sentences and bullets
assert_state "None. with trailing prose" \
  $'None. All declared Surface items are present exactly as specified:\n- item exists\n- item behaves as declared' \
  none

assert_state "None. explanation (plan had no Surface)" \
  $'None. The plan had no declared Surface block.' \
  none

assert_state "lowercase none with em dash prose" \
  $'none — nothing diverged' \
  none

# Real deviations must stay declared
assert_state "real rename deviation" \
  $'Renamed getFoo to fetchFoo; callers updated.' \
  declared

assert_state "Nonexistent must not match None prefix" \
  $'Nonexistent enum removed, broke MapScreen — fixed it.' \
  declared

# Full execute-plan extraction path (issue #2 reproduce steps)
assert_result "pipeline: None. plus bullets" \
  $'## Summary\nDone.\n\n## Surface Deviations\n\nNone. All declared Surface items are present exactly as specified:\n- item exists\n- item behaves as declared\n\n## Commits\nx' \
  none

assert_result "pipeline: real deviation" \
  $'## Surface Deviations\nAdded an undeclared helper.\n## Notes\nn/a' \
  declared

if [[ "$failures" -ne 0 ]]; then
  echo "surface-deviation-state: $failures failure(s)"
  exit 1
fi

echo "surface-deviation-state ok"
