# Changelog

## 2026.06.13

**Clean break — re-architected state as tracked files (derive, don't store).** No
old-format fallback ships. **Drain all in-flight work before updating:** finish or archive
any running tasks/chains on the old layout first — the new tooling does not read
`.done/`, `*.result.md`, or `chain-*.manifest`.

- Change: lifecycle is now **derived from file presence**, never from moving files between
  directories. `.done/` is removed. New tracked layout: `tasks/{slug}.md`,
  `results/{slug}.agent.md` (worktree-owned), `results/{slug}.merge.md` (trunk-owned),
  `chains/{chain}.md`, `epics/{epic}.md`. The only ephemeral state is the gitignored
  run-record `.running/{slug}.run` (liveness + worktree location).
- Change: git merge is the state transport — the agent commits `agent.md` on its branch and
  the squash-merge carries it to trunk; the orchestrator writes `merge.md` on trunk. No
  worktree-agent→trunk edits. `agent.md` is authored by the orchestrator from inside the
  worktree (reliable formatting, single writer), not by the headless agent.
- Add: `report.sh` — the single state-reader/classifier (TSV output). `status.sh`,
  `monitor.sh`, and `list-pending.sh` are now pure renderers over it.
- Add: stranded-result recovery — a failed merge's `agent.md` is read directly from the
  worktree via the run-record, so failed/conflicted runs never disappear from status.
- Add: `archive.sh` — the only file-mover, via `git rm`; copies land in gitignored
  `.archived/`. Clean successes and completed chains auto-archive; failures stay tracked for
  review until `archive.sh --force-failed`.
- Change: epic membership is an explicit `members: a,b,c` slug list, not a filename prefix.
- Change: chains drop the mutable manifest; progress is derived and the chain definition is
  written to trunk only on clean completion.
- Add: gitignored **inbox** for untriaged drafts. `create` writes `inbox/{slug}.md` (local,
  never committed); `triage` promotes it to a tracked `tasks/{slug}.md` (uncommitted); the
  orchestrator commits the spec to trunk automatically at launch, before cutting the
  worktree. You never hand-commit task files, and filed-but-unexecuted ideas never touch git
  history. New reporter `draft` phase + `list-drafts.sh`.
- Change: the dirty-tree launch guard now ignores `.todo-tasks/` (an uncommitted spec or
  stranded result no longer blocks a launch; uncommitted *code* still does).

## 2026.04.17

- Fix: `lib.sh` is now included in fresh installs (was previously missing, breaking all agent execution).
- Change: Verification commands are now defined per-task in each plan's `## Verification` section (fenced bash block), not globally via `INSTALL_CMD`/`BUILD_CMD`/`TEST_CMD`. Existing installs need to ensure their triaged plans have a proper Verification block. Migration: edit each plan in `.todo-tasks/` to include a fenced `bash` block under `## Verification`.
- Add: `tests/smoke-install.sh` — bash smoke test that runs `install.sh` in a temp repo and asserts all expected files land.

## 2026.04.07

- Rename 'groom' subcommand to 'triage' across all files

## 2026.04.06

- Initial release
- Task lifecycle: create, triage, execute, status, monitor
- curl-pipe-bash installer with malleable installs
- Self-refreshing TUI monitor dashboard
