# Consolidate repo structure

## Motivation

The repo currently has two skill directories (`skills/todo-task/` and `skills/execute-plan/`) plus a dead `agents/plan-executor.md`. The design has been simplified: one skill (`todo-task`) with all shell scripts inside it, no separate agent. The task root is also changing from `todo-tasks/` to `.todo-tasks/`.

## Do NOT

- Delete or modify `install.sh` — that's a separate task
- Change any shell script logic or behavior — this is purely a file-move and path-update task
- Add new features, comments, or refactoring beyond what's needed for the move
- Touch `CLAUDE.md` or `intention.md`

## Plan

### 1. Move shell scripts into `skills/todo-task/`

Move every `.sh` file and `task-config.template.sh` from `skills/execute-plan/` into `skills/todo-task/`:

```
skills/execute-plan/execute-plan.sh      → skills/todo-task/execute-plan.sh
skills/execute-plan/launch.sh            → skills/todo-task/launch.sh
skills/execute-plan/launch-chain.sh      → skills/todo-task/launch-chain.sh
skills/execute-plan/execute-chain.sh     → skills/todo-task/execute-chain.sh
skills/execute-plan/status.sh            → skills/todo-task/status.sh
skills/execute-plan/monitor.sh           → skills/todo-task/monitor.sh
skills/execute-plan/task-config.template.sh → skills/todo-task/task-config.template.sh
```

### 2. Delete legacy files and directories

- Delete `skills/execute-plan/` entirely (including `task-config.sh` — it's a project-specific file that shouldn't be in the source repo)
- Delete `agents/plan-executor.md`
- Delete `agents/` directory

### 3. Update path references in all shell scripts

Every script uses `SCRIPT_DIR` to find sibling scripts. Since they're all moving to the same directory, `SCRIPT_DIR` references to sibling scripts should still work. But update any that reference the old `execute-plan/` path explicitly.

Specific changes needed:

**`skills/todo-task/execute-plan.sh`** (line 40):
- Change: `source "${SCRIPT_DIR}/task-config.sh"`
- To: source config from `${REPO_ROOT}/.todo-tasks/task-config.sh` first, fall back to `${SCRIPT_DIR}/task-config.sh`

**`skills/todo-task/status.sh`** (line 17-18):
- Change: `CONFIG="${SCRIPT_DIR}/task-config.sh"`
- To: check `${REPO_ROOT}/.todo-tasks/task-config.sh` first, fall back to `${SCRIPT_DIR}/task-config.sh`

**`skills/todo-task/monitor.sh`** (line 3):
- Change: `TODO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/todo-tasks"`
- To: `TODO="$(git rev-parse --show-toplevel)/.todo-tasks"`

### 4. Update `todo-tasks/` → `.todo-tasks/` in all shell scripts

Every script references `todo-tasks/` as the task root. Global find-and-replace in these files:
- `execute-plan.sh`: references `todo-tasks/` in PLAN_SOURCE_FILE, mkdir, mv, PLAN_FILE, result paths
- `launch.sh`: references `todo-tasks/.running`
- `launch-chain.sh`: references `todo-tasks/.running`
- `execute-chain.sh`: references `todo-tasks/` throughout (the `TODO` variable)
- `status.sh`: references `todo-tasks` (the `TODO` variable)
- `monitor.sh`: already handled in step 3

### 5. Update `skills/todo-task/SKILL.md`

Update all path references:
- `bash .claude/skills/execute-plan/status.sh` → `bash .claude/skills/todo-task/status.sh`
- `bash .claude/skills/execute-plan/monitor.sh` → `bash .claude/skills/todo-task/monitor.sh`
- `bash .claude/skills/execute-plan/execute-plan.sh` → `bash .claude/skills/todo-task/execute-plan.sh`
- `bash .claude/skills/execute-plan/launch-chain.sh` → `bash .claude/skills/todo-task/launch-chain.sh`
- `todo-tasks/` → `.todo-tasks/` everywhere in the file
- Remove the "Manual Merge Conflict Resolution" reference to `tinyforum-agent-{slug}` worktree path — use generic `{worktree-path}` instead

### 6. Update `task-config.template.sh` header comment

Change:
```
# Copy this file to your project:
#   .claude/skills/execute-plan/task-config.sh
```
To:
```
# Copy this file to your project:
#   .todo-tasks/task-config.sh
```

## Files to Modify

- `skills/todo-task/SKILL.md` — update all path references
- `skills/todo-task/execute-plan.sh` — (moved from execute-plan/) update config resolution + todo-tasks paths
- `skills/todo-task/launch.sh` — (moved) update todo-tasks paths
- `skills/todo-task/launch-chain.sh` — (moved) update todo-tasks paths
- `skills/todo-task/execute-chain.sh` — (moved) update todo-tasks paths
- `skills/todo-task/status.sh` — (moved) update config resolution + todo-tasks paths
- `skills/todo-task/monitor.sh` — (moved) update TODO path
- `skills/todo-task/task-config.template.sh` — (moved) update header comment

## Files to Delete

- `skills/execute-plan/` — entire directory
- `agents/plan-executor.md`
- `agents/` — entire directory

## Verification

- `ls skills/todo-task/` shows SKILL.md + all 7 .sh files
- `ls skills/execute-plan/ 2>/dev/null` returns nothing (deleted)
- `ls agents/ 2>/dev/null` returns nothing (deleted)
- `grep -r 'execute-plan' skills/todo-task/` returns zero matches (all references updated)
- `grep -r 'todo-tasks/' skills/todo-task/` returns zero matches (all changed to .todo-tasks/)
- `grep -r 'plan-executor' skills/` returns zero matches
- `bash -n skills/todo-task/*.sh` — all scripts pass syntax check

## Out of Scope

- Rewriting `install.sh` (separate task)
- Changing script logic or behavior
- Modifying CLAUDE.md
