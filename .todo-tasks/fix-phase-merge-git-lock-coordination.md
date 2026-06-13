# Coordinate `phase_merge` git operations with concurrent foreground activity

## Motivation

`skills/todo-task/execute-plan.sh` `phase_merge` runs `cd "${MERGE_DIR}" && git merge --squash ... && git commit ...` (lines ~398-400) against the trunk working tree. That directory is routinely the same one the user's foreground Claude Code session is using — which intermittently holds `.git/index.lock` during its own `git status` / `git log` calls. A transient lock collision aborts the merge with nothing useful reported, which is one of the paths that leads to the silent-failure fingerprint fixed in `feedback-agents-commit-but-skip-result-file`.

## Scope

- Add lock-aware retry (bounded, with explicit logging) around the `git merge --squash` and `git commit` calls in `phase_merge`.
- Report the lock-collision case explicitly in the result file so it stops looking like a generic merge failure.

## Out of Scope

- Any changes to `phase_finalize` or `status.sh`.
- Changing the merge strategy itself (still `--squash`).

## Notes

- Sibling task `feedback-agents-commit-but-skip-result-file` must land first — it makes this failure mode visible in status.
