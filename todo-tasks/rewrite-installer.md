# Rewrite install.sh as remote curl-pipe-bash installer

## Motivation

The current `install.sh` assumes it's run from within a git subtree and creates symlinks. The new design uses a remote installer that downloads files and copies them as real files the user owns ("malleable installs"). Users should be able to install with a single curl command.

## Do NOT

- Use symlinks — copy real files
- Modify anything in `skills/` — only touch `install.sh` at the repo root
- Add dependencies beyond bash, curl/wget, git, and standard Unix tools
- Overwrite `task-config.sh` if it already exists (preserve user config on re-runs)
- Overwrite `SKILL.md` or any `.sh` file if it already exists and `--force` was not passed (malleable installs — user may have customized)

## Plan

### 1. Rewrite `install.sh` as a self-contained remote installer

The script should work when piped from curl:
```bash
curl -fsSL https://raw.githubusercontent.com/saxonthune/ai-todotasks/main/install.sh | bash
```

And also when run locally (for development):
```bash
bash install.sh
```

### 2. Detection: remote vs local

At the top, detect whether the script is running from within the source repo or as a remote download:

- If `skills/todo-task/SKILL.md` exists relative to the script location → **local mode** (use local files as source)
- Otherwise → **remote mode** (download a tarball from GitHub)

### 3. Remote download

In remote mode:
1. Create a temp directory
2. Download the GitHub tarball: `curl -fsSL https://github.com/saxonthune/ai-todotasks/archive/refs/heads/main.tar.gz`
3. Extract to temp dir
4. Set SOURCE_DIR to the extracted directory (it'll be `ai-todotasks-main/`)
5. Clean up temp dir on exit (trap EXIT)

### 4. Copy files into the project

From SOURCE_DIR, copy into CWD (which must be a git repo root):

```
SOURCE_DIR/skills/todo-task/SKILL.md           → .claude/skills/todo-task/SKILL.md
SOURCE_DIR/skills/todo-task/execute-plan.sh    → .claude/skills/todo-task/execute-plan.sh
SOURCE_DIR/skills/todo-task/launch.sh          → .claude/skills/todo-task/launch.sh
SOURCE_DIR/skills/todo-task/launch-chain.sh    → .claude/skills/todo-task/launch-chain.sh
SOURCE_DIR/skills/todo-task/execute-chain.sh   → .claude/skills/todo-task/execute-chain.sh
SOURCE_DIR/skills/todo-task/status.sh          → .claude/skills/todo-task/status.sh
SOURCE_DIR/skills/todo-task/monitor.sh         → .claude/skills/todo-task/monitor.sh
```

For each file: if it already exists and `--force` was not passed, skip it and print a message saying so. This respects user modifications.

### 5. Scaffold `.todo-tasks/`

- Create `.todo-tasks/` directory
- Copy `task-config.template.sh` → `.todo-tasks/task-config.sh` (only if it doesn't exist)
- Create `.todo-tasks/.gitignore` (only if it doesn't exist):
  ```
  .running/
  .done/
  .archived/
  *.log
  ```

### 6. Support `--force` flag

When `--force` is passed, overwrite all files except `task-config.sh`. Print what was overwritten.

### 7. Support `--update` flag

Alias for `--force` — makes the intent clearer for users updating.

### 8. Output

Print clear output:
```
ai-todotasks installer
======================
Source: [local: ./skills/todo-task | remote: github.com/saxonthune/ai-todotasks@main]

Installed:
  .claude/skills/todo-task/SKILL.md
  .claude/skills/todo-task/execute-plan.sh
  ... (list each file)

Scaffolded:
  .todo-tasks/task-config.sh (edit this with your build/test commands)
  .todo-tasks/.gitignore

Next steps:
  1. Edit .todo-tasks/task-config.sh with your project's build/test commands
  2. Create a task:  /todo-task create <description>
  3. Groom it:       /todo-task groom <slug>
  4. Execute it:     /todo-task execute <slug>
```

If files were skipped (already exist), note that `--force` can be used to overwrite.

## Files to Modify

- `install.sh` — complete rewrite

## Verification

- `bash -n install.sh` — passes syntax check
- Running `bash install.sh` from the repo root (local mode) creates the expected file structure
- Running it twice without `--force` skips existing files and doesn't error
- Running it twice with `--force` overwrites scripts but preserves `task-config.sh`
- `.todo-tasks/task-config.sh` is never overwritten regardless of flags

## Out of Scope

- Uninstall script
- Version checking
- Modifying the skill or shell scripts themselves
