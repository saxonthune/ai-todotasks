---
name: User commits themselves
description: Saxon prefers to make git commits himself — don't stage/commit on his behalf
type: feedback
---

Do not run git add or git commit. Prepare the files and let the user commit.

**Why:** User rejected a git add command and said "then I'll commit" — wants to control git operations directly.

**How to apply:** When files are ready, tell the user what to commit. Don't run git add/commit.
