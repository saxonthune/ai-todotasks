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
| `/todo-task handoff compact` | Rewrite the newest handoff to its progress and next steps, before `/compact` |
| `/todo-task handoff latest` | Read the newest handoff and continue from it |
| `/todo-task handoff list` | List all handoffs, newest first |

Requests in plain words map the same way: "see latest handoff", "pick up the last
handoff", "resume from the handoff", or "continue" right after a compaction mean
`latest`; "compact the handoff" means `compact`; "write a handoff" means `write`.

A typical loop across a context compaction:

1. The user asks to compact the handoff. The agent rewrites it (see Compact below).
2. The user runs `/compact`.
3. The user asks to continue. The agent reads the newest handoff and resumes from its
   next steps.

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

## Progress

- [x] {Finished step — name files and functions}
- [ ] {Remaining step}

{Commits made, latest check or test results, and whether the working tree has
uncommitted changes.}

## Decisions

- {Choices already made with the user, and why. A later session must not reopen these.}

## Next steps

1. {The next concrete action.}

## References

- {Related task slugs, specs, docs, commands to rerun.}
```

Write for a session that has none of the current context. If the work started from a
task spec, name its slug instead of copying the spec.

## Compact

Compacting a handoff rewrites it so the session after `/compact` can resume from it
alone. The current session still holds the full context, so this is the last chance to
record what that context knows.

1. Find the handoff: the one this session wrote or resumed from, or else the newest
   (`latest-handoff.sh`). If none exists, write one first (see Write).
2. Rewrite that file in place. Keep its file name, so it stays the same handoff and stays
   newest. Under the title, add or replace the line `Compacted: {date +'%Y-%m-%d %H:%M'}`.
3. Bring every section up to date with this session's work, then cut it down:
   - **Goal** and **Decisions** — keep, updated. Decisions stop the next session from
     reopening settled questions.
   - **Progress** — checkable indicators, not narrative: steps done and remaining as a
     checklist, commits made (hash and subject), tests or checks with their latest
     result, and whether the working tree has uncommitted changes. A handoff written
     before this section existed may have a `## State` section; replace it.
   - **Next steps** — the intended next actions, in order, concrete enough to start on
     without asking. Put the very next action first.
   - **References** — keep what the next steps need; drop the rest.
   - Drop history: dead ends, how a problem was found, and details of finished steps,
     unless a next step depends on them.
4. Tell the user the handoff is compacted, with its path, and that they can run
   `/compact` and then ask to continue.

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
