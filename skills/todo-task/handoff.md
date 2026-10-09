# todo-task: handoff mode

A handoff carries in-progress work across a context compaction or to a later session.
It is not a task: it has no lifecycle, `status` and `triage` never read it, and nothing
archives or deletes it. The developer removes old handoffs by hand.

Handoffs live in `.todo-tasks/handoffs/` (gitignored). Each file name starts with the
local time it was written, so sorting the names sorts the handoffs by age:

```
.todo-tasks/handoffs/2026-10-09T1543-privacy-isolated-format.md
```

Route on the word after `handoff`:

| Command | Action |
|---------|--------|
| `/todo-task handoff write {topic}` (or `handoff {topic}`) | Write a new handoff |
| `/todo-task handoff latest` | Read the newest handoff and continue from it |
| `/todo-task handoff list` | List all handoffs, newest first |

Requests in plain words map the same way: "see latest handoff", "pick up the last
handoff", or "resume from the handoff" mean `latest`; "write a handoff" means `write`.

## Write

1. Get the timestamp: `date +%Y-%m-%dT%H%M`. Do not guess the time.
2. Choose a short kebab-case slug for the topic.
3. Write `.todo-tasks/handoffs/{timestamp}-{slug}.md`. Do NOT commit it.
4. Tell the user the path, and that a later session can resume with
   `/todo-task handoff latest`.

Template:

```markdown
# Handoff {YYYY-MM-DD HH:MM}: {Title}

## Goal

{What the work is for, and what done looks like.}

## State

{What is finished, what is half-finished, and what is untouched. Name files and
functions. Say whether the working tree has uncommitted changes.}

## Decisions

- {Choices already made with the user, and why. A later session must not reopen these.}

## Next steps

1. {The next concrete action.}

## References

- {Related task slugs, specs, docs, commands to rerun.}
```

Write for a session that has none of the current context. If the work started from a
task spec, name its slug instead of copying the spec.

## Latest

```bash
bash .claude/skills/todo-task/latest-handoff.sh
```

The script prints the newest handoff's path. Read that file, tell the user which handoff
you loaded (its title and timestamp), and continue from its next steps.

If the user names a topic ("the latest privacy handoff"), run `list` and pick the newest
file whose name matches the topic.

## List

```bash
bash .claude/skills/todo-task/latest-handoff.sh --list
```

Show the paths to the user.
