#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

today="$(date +%Y.%m.%d)"
current="$(tr -d '[:space:]' < "$VERSION_FILE")"

current_date="${current%[a-z]}"
current_suffix="${current#"$current_date"}"

if [[ "$current_date" != "$today" ]]; then
  new="$today"
elif [[ -z "$current_suffix" ]]; then
  new="${today}a"
else
  new="${today}$(echo "$current_suffix" | tr 'a-y' 'b-z')"
fi

printf '%s\n' "$new" > "$VERSION_FILE"
echo "$current -> $new"
