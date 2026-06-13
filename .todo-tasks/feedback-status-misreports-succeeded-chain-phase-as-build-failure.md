# status.sh misreports a succeeded chain phase as `build_failure`

## What happened

Ran a 5-phase chain (`look-and-feel-rest`, queued `--after` a standalone phase 01). All five phases ran, the chain merged cleanly into the trunk branch, and the chain log ended with:

```
═══ Chain look-and-feel-rest complete! All 5 phases succeeded. ═══
Merge: success
```

Phase 04's own `result.md` self-reports:

```
Verification: passed
Merge: clean
Surface Deviations: none
```

Running `bash .claude/skills/todo-task/status.sh` afterwards still produced:

```
### Needs Attention
| look-and-feel-04-map-screen-chrome | build_failure | 1 | Check result file. |

### Epic: Look & Feel Overhaul
| look-and-feel-04-map-screen-chrome | FAILED |
```

…while simultaneously reporting the parent chain as `COMPLETE 5/5`. I also ran the verification command (`./gradlew :composeApp:compileDebugKotlinAndroid`) against trunk after the chain merged — `BUILD SUCCESSFUL`. So phase 04 succeeded by every available signal except status.sh.

Phases 02, 03, 05, and 06 from the same chain were correctly classified as `success`. Only 04 got the false flag.

## Why it matters

After a long-running multi-phase chain, status is the first thing I check to know what landed. A false `build_failure` / `FAILED` line means I either:

1. Stop trusting status and have to read every `result.md` and the chain log to confirm, which defeats the purpose of the summary, or
2. Trust status and waste a triage cycle "investigating" a phase that actually succeeded — including being prompted by the skill's own triage flow to ask the user how to proceed with a failed agent that didn't actually fail.

Also: `--archive-success` will skip this row because it's classified as failed, so the stale entry sticks around in subsequent runs and the chain's success row drifts further from the epic table — they will keep disagreeing.

The inconsistency between two views in the same status output (chain `COMPLETE 5/5` vs. epic row `FAILED` for one of those same 5 phases) is the clearest signal that the classifier is reading different fields than the chain executor writes.

## Direction

The classifier likely greps the agent's `result.md` for failure keywords ("FAILED", "Error", "build_failure") without scoping to the verdict block — phase 04's result happens to include the word "Error" or similar inside a code block, build log, or `## Notes` (mine mentions `extractDeepLinksDebug`, gradle output, etc., which is innocuous content that could trip a naive grep). Reading the explicit `Verification: passed` / `Merge: clean` header lines, or the chain log's per-phase exit, would be more reliable. The chain executor and status.sh should agree by construction — they should read the same field.
