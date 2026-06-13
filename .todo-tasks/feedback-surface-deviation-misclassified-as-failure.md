# Surface deviation makes a successful agent show as build_failure

## What happened

An agent finished a task cleanly — its result file said `Verification: passed`,
`Merge: clean`, `BUILD SUCCESSFUL`, and the commit was merged to trunk as HEAD. The only
unusual thing: the agent had to edit one file that my plan's "Files to Modify" list
omitted (deleting an enum broke a screen the plan forgot to list). The agent did the right
thing — fixed it, and honestly recorded it under a `## Surface Deviations` heading.

`status.sh` then reported that agent as **`build_failure`**, in a "Needs Attention" table,
with the note "Surface deviations declared — re-triage downstream." The header metadata
showed `**Surface Deviations**: declared` even though the result body said
"Surface Deviations: None. The plan had no declared Surface block."

`--archive-success` skipped it ("not successful"), so it stuck around as a permanent
attention item until I manually verified the build, hand-moved the files to `.archived/`,
and reconciled the date-prefix naming myself.

## Why it matters

A declared scope deviation is not a build failure — the build passed. Conflating the two
sends a clean, merged success into the failure path: it can't be auto-archived, it shows a
scary `build_failure` state, and it implies the work is broken when it isn't. I had to do a
full manual investigation (read the result, recompile trunk, grep the codebase) just to
establish the agent had in fact succeeded. That's exactly the investigation the status
classification is supposed to save me.

It also punishes honesty: an agent that transparently flags an out-of-scope edit gets its
run marked failed, while one that silently makes the same edit would show as `success`.

## Direction

`build_failure` should reflect the build. A declared surface/scope deviation on an
otherwise-passing run might warrant its own lighter state (e.g. `success-with-deviations`)
that is still archivable by `--archive-success` but carries the "re-triage downstream"
note. Also worth reconciling the contradiction between the header `Surface Deviations:
declared` and a body that says `None`.
