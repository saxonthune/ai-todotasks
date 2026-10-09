#!/usr/bin/env bash
set -uo pipefail

# Print the newest handoff's path, or with --list every handoff, newest first.
# Order comes from the timestamp prefix in each file name, not from mtime: editing an
# old handoff must not make it "latest".
#
# Usage: latest-handoff.sh [--list]

REPO_ROOT="$(git rev-parse --show-toplevel)"
HANDOFFS="${REPO_ROOT}/.todo-tasks/handoffs"

shopt -s nullglob
files=("$HANDOFFS"/*.md)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No handoffs in .todo-tasks/handoffs/" >&2
  exit 1
fi

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${files[@]}" | sort -r
else
  printf '%s\n' "${files[@]}" | sort | tail -n 1
fi
