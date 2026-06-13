#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TODO="${REPO_ROOT}/.todo-tasks"

for f in "${TODO}"/*.md; do
  [[ -e "$f" ]] || continue         # no matches → glob stays literal; skip
  base="$(basename "$f" .md)"
  [[ "$base" == *.epic ]] && continue  # exclude epic overview files
  echo "$base"
done
