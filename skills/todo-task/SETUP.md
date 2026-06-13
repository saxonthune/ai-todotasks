# todo-task first-run setup

The todo-task skill calls a small set of read-only scripts (`list-pending.sh`, `status.sh`)
every time you run `triage` or `execute` with no slug argument. Without an allowlist entry,
Claude will prompt for approval on each call.

## Suggested allowlist

Add the entries below to your project's `.claude/settings.local.json` (create the file if
it doesn't exist). This is a suggestion — the skill never edits settings itself. You decide
what to allow.

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

These entries cover only the two listing/dispatch helpers. All other scripts (`launch.sh`,
`execute-plan.sh`, etc.) are left unapproved so you retain explicit control over anything
that mutates state.
