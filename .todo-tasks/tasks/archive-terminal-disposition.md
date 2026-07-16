# Record an archive disposition (success vs done) so archived tasks stop showing stale failure states

## Motivation

"Archived" is currently derived from file *location* (`.todo-tasks/.archived/`),
while a task's state is derived from result-file *content* (`classify_task`).
`report.sh:emit_archived` re-composes them: it re-runs `classify_task` on the
archived copies, so an archived task shows whatever its result files last derived
to. But `archive.sh` records **no disposition** when it archives — it just `cp`s the
result files and `git rm`s the originals. So when a crashed/salvageable task is
salvaged, merged by hand, and archived, its `agent.md` still says `session: failed`,
and the monitor's "Recently archived" list shows it as `crashed`/`salvageable` (red)
even though it was resolved. Re-derivation alone cannot fix this: a salvaged-and-
merged task (genuinely a success) and a `--force-failed` abandon (genuinely a
failure) both have failure-shaped result files. Only `archive.sh` knows, at archive
time, which it is.

Fix: record the **disposition** as data when archiving, and read it back instead of
re-deriving from stale files. Archived tasks then display a terminal disposition:

- resolved (success sweep, `--merged` salvage, completed chain) → **success** (green)
- `--force-failed` abandon (a reviewed failure, skipped not resolved) → **done**
  (neutral — not red, not claiming success)

## Do NOT

- Do NOT change `classify_task` / `derive_overall_state` or any LIVE task
  classification. This only changes how ARCHIVED records derive their state.
- Do NOT alter the archive eligibility rules (`--force-failed`, `--merged`, success
  sweep) — only stamp a disposition when an archive actually happens.
- Do NOT re-run `classify_task` for an archived task that has a disposition stamp —
  the stamp is authoritative (that is the whole point).
- Do NOT put any destructive command (archive.sh sweep, git rm, worktree removal) in
  this task's `## Verification` — verify with `bash -n`, `grep`, and the read-only
  `report.sh archived`. (See the non-destructive-verification rule in triage.md.)
- Do NOT edit `.claude/skills/…`. Edit tracked `skills/todo-task/…`.

## Plan

### 1. `skills/todo-task/lib.sh` — a disposition token

Add one constant near the `SM_OVERALL_*` block:

```bash
# Archive disposition (recorded by archive.sh, read by report.sh:emit_archived).
# Resolved archives reuse SM_OVERALL_SUCCESS ("success"); abandoned ones use this.
readonly SM_ARCHIVE_ABANDONED="abandoned"
```

(Resolved disposition reuses the existing `SM_OVERALL_SUCCESS`.)

### 2. `skills/todo-task/archive.sh` — stamp disposition at archive time

Give `archive_one` a disposition parameter and have it write a sidecar next to the
archived copies:

```bash
# archive_one <slug> <disposition>   disposition ∈ {success, abandoned}
archive_one() {
  local slug="$1" disposition="${2:-success}"
  ...existing cp / git rm ...
  printf '%s\n' "$disposition" > "${TODO}/.archived/${TS}-${slug}.disposition"
  ...
}
```

Pass the disposition at each call site:
- `--merged <slug>` (operator asserts merged to trunk) → `success` (resolved).
- explicit-slug branch and the sweep branch: `success` when
  `overall == "$SM_OVERALL_SUCCESS"`, else (`--force-failed` on a `force_eligible`
  failure) → `"$SM_ARCHIVE_ABANDONED"`. Compute the disposition into a local before
  calling `archive_one "$slug" "$disp"`.
- `archive_chain` → also write a `${TS}-chain-${name}.disposition` of `success`
  (completed chains are resolved).

The sidecar is a plain one-word file; it is gitignored along with the rest of
`.archived/` (nothing else to configure).

### 3. `skills/todo-task/report.sh` — read the stamp in `emit_archived`

In `emit_archived`, after recovering `ts`/`slug`, prefer the disposition sidecar over
re-deriving:

```bash
disp_file="${TODO}/.archived/${ts}-${slug}.disposition"
if [[ -f "$disp_file" ]]; then
  overall="$(<"$disp_file")"; overall="${overall//[$'\t\r\n ']/}"
elif [[ -n "$agent_md" ]]; then
  # Old archive, no stamp: best-effort — a genuine success stays success; any
  # non-success archived task is shown as abandoned/done (we cannot retroactively
  # know it was resolved).
  if [[ "$(classify_task "$agent_md" "$merge_md")" == "$SM_OVERALL_SUCCESS" ]]; then
    overall="$SM_OVERALL_SUCCESS"
  else
    overall="$SM_ARCHIVE_ABANDONED"
  fi
else
  overall="$NONE"   # ancient, no classifiable result → dim "archived"
fi
```

Keep `commits`/`notes` extraction from `agent_md` as-is. Net effect: `emit_archived`
never emits `crashed`/`salvageable`/`build_failure` again — only `success`,
`abandoned`, or `-`.

### 4. `skills/todo-task/monitor.sh` — render `abandoned` as a neutral "done"

In `render_archived_rows`, map the new token to a calm label:

```bash
if [[ "$overall" == "$NONE" ]]; then
  col="$DIM"; lbl="archived"
elif [[ "$overall" == "$SM_ARCHIVE_ABANDONED" ]]; then
  col="$DIM"; lbl="done"
else
  col="$(overall_color "$overall")"; lbl="$(overall_label "$overall")"
fi
```

`success` still routes through `overall_color`/`overall_label` → green "success".
No archived row is ever red again.

## Files to Modify

- `skills/todo-task/lib.sh` — add `SM_ARCHIVE_ABANDONED`.
- `skills/todo-task/archive.sh` — `archive_one` writes a `.disposition` sidecar; call sites pass success/abandoned; `archive_chain` stamps success.
- `skills/todo-task/report.sh` — `emit_archived` reads the stamp, falls back for old archives, never re-surfaces failure states.
- `skills/todo-task/monitor.sh` — `render_archived_rows` maps `abandoned` → neutral "done".

## Verification

```bash
# Everything parses.
bash -n skills/todo-task/lib.sh && echo "lib OK"
bash -n skills/todo-task/archive.sh && echo "archive OK"
bash -n skills/todo-task/report.sh && echo "report OK"
bash -n skills/todo-task/monitor.sh && echo "monitor OK"

# The disposition token exists and is used across the three consumers.
grep -q 'SM_ARCHIVE_ABANDONED' skills/todo-task/lib.sh && echo "token defined"
grep -q '\.disposition' skills/todo-task/archive.sh && echo "archive stamps sidecar"
grep -q '\.disposition' skills/todo-task/report.sh && echo "report reads sidecar"
grep -q 'done' skills/todo-task/monitor.sh && echo "monitor has done label"

# READ-ONLY end-to-end: emit_archived must no longer surface stale failure states.
# report.sh archived only walks .archived/ and prints — it mutates nothing.
echo "archived overall states now:"
bash skills/todo-task/report.sh archived | awk -F'\t' '{print $3}' | sort -u
# Assert none of the live-failure states leak into archived rows.
if bash skills/todo-task/report.sh archived | awk -F'\t' '{print $3}' \
     | grep -qE 'crashed|salvageable|build_failure|session_failed|merge_conflict|no_op|trunk_leak'; then
  echo "FAIL: a stale failure state still shows in archived"
else
  echo "archived shows only success/abandoned/- OK"
fi
```

## Out of Scope

- Retroactively distinguishing old salvaged-and-merged archives (resolved) from old
  `--force-failed` abandons — no stamp exists for them, so both degrade to "done".
  Only archives created after this change carry a precise disposition.
- Any change to live-task classification, buckets, or the state machine for
  non-archived tasks.
- `status.sh` (it does not render an archived list; only `monitor.sh` does).

## Notes

- This makes "archived" a genuine terminal disposition recorded in data, resolving
  the "archived is a property composed with a stale state" confusion: the stamp is
  written once, at the moment of archival, by the one component that knows the true
  outcome.
- The sidecar (not a field inside `agent.md`) keeps the disposition separate from the
  worktree-owned result files, which must stay byte-stable — and it survives even
  when a salvaged task has no `merge.md`.
- `emit_archived`'s `for spec in .archived/*.md` loop globs only `*.md`, so the
  `.disposition` sidecars are naturally ignored as record keys.
