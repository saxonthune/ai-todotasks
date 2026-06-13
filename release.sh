#!/usr/bin/env bash
# Compute the next CalVer version and write it to VERSION.
#
# Scheme: YYYY.MM.DD for the first release of a day, then a lowercase
# letter suffix (a, b, c, ...) for each same-day re-release. The current
# VERSION file is the source of truth — no git tags required.
#
# This only bumps VERSION. Add your CHANGELOG entry, then commit yourself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

today="$(date +%Y.%m.%d)"
current=""
[[ -f "$VERSION_FILE" ]] && current="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [[ "$current" == "$today"* ]]; then
  # Same-day release: bump the letter suffix.
  suffix="${current#"$today"}"
  if [[ -z "$suffix" ]]; then
    next="a"
  elif [[ "$suffix" == [a-y] ]]; then
    # advance one letter: a->b, ... y->z
    next="$(printf "\\$(printf '%03o' "$(( $(printf '%d' "'$suffix") + 1 ))")")"
  elif [[ "$suffix" == "z" ]]; then
    echo "error: already at ${today}z — 26 releases today is plenty. Bump manually." >&2
    exit 1
  else
    echo "error: unexpected suffix '${suffix}' in VERSION. Bump manually." >&2
    exit 1
  fi
  new="${today}${next}"
else
  new="$today"
fi

printf '%s\n' "$new" > "$VERSION_FILE"
echo "VERSION: ${current:-<none>} -> ${new}"
echo "Next: add a '## ${new}' section to CHANGELOG.md, then commit."
