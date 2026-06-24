# finalize-chain.sh — clear the orphaned run-record after an out-of-band chain merge

## Motivation

When a chain defers its final merge (`awaiting-merge`/`conflict`) and a human completes the
merge by hand, nothing clears `.todo-tasks/.running/chain-<name>.run`. The dead run-record
lingers and the chain shows on the dashboard forever. (Reported in
`feedback-manual-chain-merge-orphans-run-record`, folded into this phase.)

Phases 1–2 make the lingering state legible: such a chain now classifies as `finalizable`
(dead run-record + work present on trunk HEAD) instead of `failed`. This phase adds the one
genuinely missing **mutation** — the documented one-shot that turns a `finalizable` chain
into a clean `complete` one — and points the deferred-merge messages at it. Mutation stays
behind a script (the project's mutation API: `execute-*.sh` create, `archive.sh` remove,
now `finalize-chain.sh` finalize); no stored state is introduced.

This is Phase 3 of the `chain-state-machine` epic. **Triage against the declared Surfaces
of Phases 1 and 2, not live code.** Guaranteed to exist:

- From Phase 1: `chain_merged_on_trunk <repo_root> <phases_csv>` (0 iff all phases on trunk
  HEAD); `write_chain_definition <dest_path> <name> <phases_csv> [after]` (writes the trunk
  definition, uncommitted, byte-compatible with `do_post_merge_success`);
  `SM_CHAIN_FINALIZABLE="finalizable"`.
- From Phase 2: a `finalizable` chain renders distinctly and `report.sh` emits it.

If a symbol is not in those Surfaces, treat it as nonexistent.

## Do NOT

- Do NOT remove a worktree, delete a branch, or clear a run-record **before** confirming
  the chain actually landed on trunk via `chain_merged_on_trunk`. Refuse loudly otherwise —
  never destroy unmerged work. (Mirror `archive.sh`'s stance on `salvageable`.)
- Do NOT run destructive git (`reset --hard`, `clean`, `checkout -- .`). Finalize only
  removes the chain's own worktree/branch/run-record and writes the definition.
- Do NOT auto-finalize from `archive.sh`'s sweep or from `report.sh`. Finalization asserts
  "a human merged this out-of-band" — it must be an explicit, deliberate invocation.
- Do NOT re-implement the chain-definition format inline — call Phase 1's
  `write_chain_definition`. Also adopt it in `execute-chain.sh:do_post_merge_success`
  (replace the inline block) so there is a single writer.
- Do NOT change classification or rendering — those are Phases 1–2. This phase adds a
  script + messages + docs (+ the `write_chain_definition` adoption).

## Plan

### 1. New script: `skills/todo-task/finalize-chain.sh <name>`

Standard preamble (mirror `archive.sh:22-25`): resolve `SCRIPT_DIR`, `REPO_ROOT`, `TODO`,
`source lib.sh`. Then:

1. `run="${TODO}/.running/chain-${name}.run"`. If missing → print
   "No run-record for chain '<name>' (already finalized?)" and exit 0 (idempotent).
2. If `run_is_alive "$run"` → refuse: "Chain '<name>' is still running." exit 1.
3. Read `phases`, `worktree`, `branch` (`read_run_field`); also `after`/`waiting_for` if
   present (for the definition's `after:` line).
4. **Merge guard:** if NOT `chain_merged_on_trunk "$REPO_ROOT" "$phases"` → refuse with the
   exact command and do nothing destructive:
   ```
   Chain '<name>' does not appear merged on trunk (phase results missing from HEAD).
   Merge it first, then re-run finalize-chain:
     git merge --squash <branch> && git commit -m 'feat: chain-<name> (agent)'
   ```
   exit 1.
5. **Finalize (merged confirmed):**
   - `write_chain_definition "${TODO}/chains/${name}.md" "$name" "$phases" "$after"`, then
     `git -C "$REPO_ROOT" add` + commit it (`todotask: chain definition <name>`), guarded
     by a `diff --cached --quiet` check like `archive.sh:72-74`.
   - Remove the breadcrumb if present: `${worktree}/.todo-tasks/results/<name>.conflict.md`
     departs with the worktree; nothing extra needed.
   - `[[ -n "$worktree" && -d "$worktree" ]] && git worktree remove --force "$worktree"`.
   - `[[ -n "$branch" ]] && git branch -D "$branch"` (ignore failure — may already be gone).
   - `clear_run_record "$name" chain`; `rm -f "${TODO}/.running/chain-${name}.log"`.
   - Print "Finalized chain '<name>' — definition written, worktree/branch/run-record
     cleared. Run /todo-task status; archive.sh will sweep it as complete."

After this, `report.sh` emits the chain as `complete` (definition present, run-record gone)
and the normal `archive.sh` sweep archives it + members.

### 2. `execute-chain.sh` — point deferred/conflict messages at finalize

In both flag-exit messages (`awaiting-merge` ~371-375 and `conflict` ~335-339), append a
line after the `git merge --squash` instruction:

```
After completing the merge, finalize: bash .claude/skills/todo-task/finalize-chain.sh <name>
```

(Use the actual chain name. This closes the loop the original report flagged: the message
told you how to merge but not how to clear the run-record.)

### 3. `execute-chain.sh` — adopt `write_chain_definition`

In `do_post_merge_success` (~291-308), replace the inline definition-writing block with a
call to `write_chain_definition` + the existing add/commit. Output must stay identical
(verify by diffing a produced definition before/after if practical).

### 4. `SKILL.md` — document finalize-chain

In the "Manual Merge Conflict Resolution" section (and/or a new "Finalizing a deferred
chain" note), replace the manual `git worktree remove` / `git branch -d` / `archive.sh`
sequence **for chains** with: "run `bash .claude/skills/todo-task/finalize-chain.sh <name>`
after you complete the merge." Keep the single-task manual steps as-is.

## Files to Modify

- `.claude/skills/todo-task/finalize-chain.sh` — NEW.
- `.claude/skills/todo-task/execute-chain.sh` — deferred/conflict messages point at
  finalize; `do_post_merge_success` adopts `write_chain_definition`.
- `.claude/skills/todo-task/SKILL.md` — document the finalize step for chains.

## Verification

```bash
bash -n .claude/skills/todo-task/finalize-chain.sh
bash -n .claude/skills/todo-task/execute-chain.sh

# Refuses an unmerged chain (no destructive action). Craft a fake run-record pointing at a
# bogus worktree with phases whose results are NOT on HEAD; expect non-zero + the merge hint.
bash -c '
  set -e
  TODO=.todo-tasks
  mkdir -p "$TODO/.running"
  printf "slug: chain-zzfake\nworktree: /nonexistent\nbranch: nope\npid: 1\nkind: chain\nphases: zz-nope-phase\n" > "$TODO/.running/chain-zzfake.run"
  if bash .claude/skills/todo-task/finalize-chain.sh zzfake; then echo "BUG: finalized unmerged"; exit 1; fi
  test -f "$TODO/.running/chain-zzfake.run"   # run-record must be untouched
  rm -f "$TODO/.running/chain-zzfake.run"
  echo "refusal-guard OK"
'

# finalize uses the shared helpers, not an inline definition or destructive git.
grep -q 'write_chain_definition' .claude/skills/todo-task/finalize-chain.sh
grep -q 'chain_merged_on_trunk' .claude/skills/todo-task/finalize-chain.sh
! grep -qE 'reset --hard|git clean|checkout -- \.' .claude/skills/todo-task/finalize-chain.sh
grep -q 'finalize-chain.sh' .claude/skills/todo-task/execute-chain.sh
```

## Out of Scope

- Auto-detection/auto-finalization in `archive.sh` or `report.sh`. Finalize is explicit.
- Any classifier/renderer change (Phases 1–2).

## Notes

- The PID-1 guard in the verification fixture: `run_is_alive` checks `kill -0 <pid>`. PID 1
  exists, so the fixture would read as "alive" and hit the still-running refusal before the
  merge guard. Use a definitely-dead PID instead (e.g. a large unused PID) so the test
  exercises the merge guard specifically; adjust the fixture accordingly during
  implementation.
- Idempotency matters: a second `finalize-chain <name>` after success should no-op cleanly
  (run-record already gone → step 1 exits 0).
