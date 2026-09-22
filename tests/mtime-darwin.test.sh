#!/usr/bin/env bash
# report.sh mtime must be a real epoch on macOS, not "now".
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
report="$root/skills/todo-task/report.sh"
work=$(mktemp -d)

set +e
stat -c %Y /bin/bash >"$work/red.out" 2>"$work/red.err"
red=$?
set -e
[ "$red" -ne 0 ]
grep -q "illegal option" "$work/red.err"

NOW=$(date +%s)
old=$(stat -c %Y /bin/bash 2>/dev/null || echo "$NOW")
[ "$old" = "$NOW" ]

funcs=$(awk '
  /^mtime\(\) \{/ {p=1}
  p {print}
  /^}$/ && p {exit}
' "$report")
eval "$funcs"
got=$(mtime /bin/bash)
want=$(stat -f %m /bin/bash)
[ "$got" = "$want" ]
[ "$got" != "$NOW" ]
echo "mtime darwin ok (stat -c exit $red, epoch $got)"
rm -rf "$work"
