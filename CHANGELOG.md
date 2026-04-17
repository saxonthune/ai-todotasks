# Changelog

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
