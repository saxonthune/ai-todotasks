# Replace inline task-listing pipeline with an allowlistable script

## Motivation

`triage` and `execute` modes both inline the same read-only pipeline to list pending
task slugs:

```bash
ls .todo-tasks/*.md 2>/dev/null | grep -v '\.epic\.md$' | sed 's|.todo-tasks/||;s|\.md$||'
```

It appears at `skills/todo-task/SKILL.md:135` (triage Step 1) and
`skills/todo-task/SKILL.md:318` (execute, Select step).
The `ls | grep | sed` chain isn't allowlistable as a stable command, so the most common
entry point — starting triage/execute with no slug — stops to ask for approval on a
read-only listing, and the ad-hoc `sed` munging is exactly the kind of inline shell the
project conventions discourage. Move the logic into one small script (mirroring
`status.sh`) that both prompts call, and ship a first-run setup doc that suggests the
allowlist entry so the listing stops prompting.

## Do NOT

- Do NOT add `--list` as a mode on `status.sh` or any other existing script — this is a
  dedicated single-purpose script.
- Do NOT edit `.claude/settings.local.json` automatically. The allowlist is offered to
  the user via a setup doc; the user owns that decision (and the file).
- Do NOT inline the suggested allowlist rules into `SKILL.md` — they go in a SEPARATE doc
  so they don't pollute the always-loaded skill prompt. `SKILL.md` only gets a short
  one-line pointer to that doc.
- Do NOT change the listing behavior: it must still exclude `*.epic.md` files and emit
  one bare slug per line (no `.md`, no directory prefix), matching the current output.
- Do NOT touch the `monitor.sh` / `status.sh` listing logic or epic handling.

## Plan

### 1. Create `list-pending.sh`

New file `skills/todo-task/list-pending.sh`. Mirror the header convention used by
`status.sh` (lines 1-17): `#!/usr/bin/env bash`, `set -uo pipefail`, resolve
`REPO_ROOT="$(git rev-parse --show-toplevel)"` and `TODO="${REPO_ROOT}/.todo-tasks"`.
Sourcing `lib.sh` is NOT required (no helpers are used) — keep it minimal and
self-contained.

Behavior: emit pending task slugs, one per line, excluding `*.epic.md`. Reproduce the
current pipeline's output exactly. A robust implementation that avoids `sed`:

```bash
for f in "${TODO}"/*.md; do
  [[ -e "$f" ]] || continue          # no matches → glob stays literal; skip
  base="$(basename "$f" .md)"
  [[ "$base" == *.epic ]] && continue # exclude epic overview files
  echo "$base"
done
```

Make it executable (`chmod +x`).

### 2. Point `SKILL.md` at the new script

Replace the inline pipeline at both call sites with the script invocation:

- `SKILL.md:135` (triage Step 1, "If no slug provided") — replace the fenced
  `ls … | grep … | sed …` block with:
  ```bash
  bash .claude/skills/todo-task/list-pending.sh
  ```
- `SKILL.md:318` (execute, Select step) — same replacement. This line is indented inside
  a numbered list item; preserve that indentation.

### 3. Add the first-run setup doc

New file `skills/todo-task/SETUP.md`. Keep it short. It explains that the todo-task
scripts are read-only/dispatch helpers and that allowlisting them removes approval
prompts on the common entry points. Include the suggested `settings.local.json` allow
entries the user can paste, e.g.:

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(bash .claude/skills/todo-task/list-pending.sh:*)",
      "Bash(bash .claude/skills/todo-task/status.sh:*)"
    ]
  }
}
```

State plainly that this is a suggestion the user applies manually — the skill never edits
settings itself.

### 4. One-line pointer in `SKILL.md`

Near the top of `SKILL.md` (just under the routing table / intro, before the `status`
mode section), add a single line directing an agent to read `SETUP.md` on first use if
listing/status commands are prompting for approval — phrased so it does NOT inline the
allowlist content. Example:

> First-time setup: if todo-task scripts prompt for approval, read
> `.claude/skills/todo-task/SETUP.md` for a suggested allowlist (kept separate to avoid
> context pollution).

## Files to Modify

- `skills/todo-task/list-pending.sh` — NEW. Emits pending slugs, excludes epics, no sed.
- `skills/todo-task/SETUP.md` — NEW. First-run doc with suggested allowlist entries.
- `skills/todo-task/SKILL.md` — replace inline pipeline at lines ~135 and ~301 with the
  script call; add one-line pointer to `SETUP.md` near the top.

## Verification

```bash
# Script exists, is executable, and lists pending slugs without epics or .md suffix
test -x skills/todo-task/list-pending.sh
bash skills/todo-task/list-pending.sh
# No epic files leak into the listing
bash skills/todo-task/list-pending.sh | grep -q '\.epic$' && { echo "FAIL: epic leaked"; exit 1; } || echo "OK: no epics"
# Inline pipeline is gone from SKILL.md, replaced by the script call
! grep -q "grep -v '\\\\.epic\\\\.md\$'" skills/todo-task/SKILL.md && echo "OK: inline pipeline removed"
grep -c "list-pending.sh" skills/todo-task/SKILL.md   # expect >= 3 (two call sites + pointer)
# Setup doc exists and names the allowlist
test -f skills/todo-task/SETUP.md && grep -q "list-pending.sh" skills/todo-task/SETUP.md && echo "OK: SETUP.md present"
```

## Out of Scope

- Allowlisting every skill script, or editing `settings.local.json` — deferred to the
  user via `SETUP.md`.
- Refactoring `status.sh` / `monitor.sh` listing logic.
- Re-running the install script or syncing the repo-root copy of the skill (the install
  story is separate; this task edits the in-repo skill source).

## Notes

- The repo's own skill lives at `.claude/skills/todo-task/` AND the canonical source is
  `skills/todo-task/` per the repo structure. This task edits `skills/todo-task/` (the
  shipped source). The Verification block paths assume the agent runs from `REPO_ROOT`.
  If only `.claude/skills/todo-task/` exists as a working copy, apply the same edits there
  too so the running skill picks them up — but the source of truth is `skills/todo-task/`.
- `git rev-parse --show-toplevel` is already the resolution pattern in `status.sh`; reuse
  it rather than `$BASH_SOURCE` gymnastics.
</content>
</invoke>
