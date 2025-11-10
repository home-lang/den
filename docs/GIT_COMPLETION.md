# Git Command Completion

Den provides intelligent tab completion for git commands, making it faster and easier to work with git repositories.

## Features

### 1. Git Subcommand Completion

When you type `git` followed by a space and press Tab, Den will show you available git subcommands:

```bash
$ git <TAB>
add
bisect
branch
checkout
cherry-pick
clone
commit
diff
fetch
grep
init
log
merge
mv
pull
push
rebase
reset
restore
revert
rm
show
stash
status
switch
tag
```

**Partial Matching:**
You can also type part of a subcommand and press Tab to see matching options:

```bash
$ git che<TAB>
checkout
cherry-pick
```

If there's only one match, it will auto-complete:

```bash
$ git chec<TAB>
# Becomes:
$ git checkout
```

### 2. Branch Completion

For branch-related subcommands, Den will show you available branches when you press Tab:

**Supported commands:**
- `git checkout <TAB>` - Switch to a branch
- `git branch <TAB>` - Manage branches
- `git merge <TAB>` - Merge a branch
- `git rebase <TAB>` - Rebase onto a branch
- `git switch <TAB>` - Switch branches (newer alternative to checkout)
- `git cherry-pick <TAB>` - Cherry-pick commits from a branch

**Example:**
```bash
$ git checkout <TAB>
main
origin/main
origin/feature/new-ui
origin/bugfix/login-issue
```

**How it works:**
- Shows both local and remote branches
- Runs `git branch -a --format=%(refname:short)` under the hood
- Filters out duplicate remote tracking branches
- Skips the remote HEAD pointer

### 3. Modified Files Completion

For file-related subcommands, Den will show you files that have been modified according to `git status`:

**Supported commands:**
- `git add <TAB>` - Stage files
- `git diff <TAB>` - View changes in files
- `git restore <TAB>` - Restore files
- `git reset <TAB>` - Unstage files

**Example:**
```bash
# After modifying some files:
$ git add <TAB>
src/shell.zig
src/utils/terminal.zig
docs/GIT_COMPLETION.md
```

**How it works:**
- Runs `git status --porcelain` to get modified files
- Parses the output to extract filenames
- Shows only files that match your current prefix (if any)

## Usage Examples

### Example 1: Switching Branches
```bash
$ git checkout f<TAB>
feature/new-ui
feature/dark-mode

# Press Tab again to cycle through options, or type more:
$ git checkout feature/n<TAB>
# Auto-completes to:
$ git checkout feature/new-ui
```

### Example 2: Staging Modified Files
```bash
$ git add s<TAB>
src/shell.zig
src/utils/terminal.zig

# Continue typing to narrow down:
$ git add src/s<TAB>
# Auto-completes to:
$ git add src/shell.zig
```

### Example 3: Using Partial Subcommand Matching
```bash
$ git st<TAB>
stash
status

# Type more to disambiguate:
$ git sta<TAB>
stash
status

$ git stat<TAB>
# Auto-completes to:
$ git status
```

### Example 4: Merging a Remote Branch
```bash
$ git merge origin/<TAB>
origin/main
origin/feature/new-ui
origin/bugfix/login-issue

$ git merge origin/f<TAB>
# Auto-completes to:
$ git merge origin/feature/new-ui
```

## Visual Feedback

When multiple completions are available:
- Completions are displayed one per line below your input
- The currently selected completion is highlighted with a gray background
- Press Tab repeatedly to cycle through available completions
- Press Enter to execute the command with the selected completion
- Press any other key to continue typing

## Technical Details

### Implementation

The git completion system consists of three main functions:

1. **`completeGit()`** - Main dispatcher that:
   - Parses the input to identify the git subcommand
   - Shows subcommand completions when no subcommand is typed
   - Routes to branch or file completion based on the subcommand

2. **`getGitBranches()`** - Branch completion:
   - Executes `git branch -a --format=%(refname:short)`
   - Filters and returns matching branch names
   - Handles both local and remote branches

3. **`getGitModifiedFiles()`** - File completion:
   - Executes `git status --porcelain`
   - Parses the output to extract modified filenames
   - Returns files matching the current prefix

### Performance

- Git commands are executed synchronously when Tab is pressed
- Results are cached only during the current completion session
- If git commands fail (e.g., not in a git repository), completion gracefully falls back to showing no results

### Error Handling

- If you're not in a git repository, git completions will show no results
- If git commands fail, the completion system won't crash - it simply returns an empty list
- Invalid or unrecognized git subcommands won't show completions

## Limitations

- Only the most common git subcommands are included in the completion list
- File completion only shows modified files, not all files in the repository
- Branch completion shows all branches; there's no filtering by local/remote
- Git aliases are not currently supported in completion

## Future Enhancements

Potential improvements for future versions:

- [ ] Support for git aliases
- [ ] Completion for git flags and options (e.g., `git commit --<TAB>`)
- [ ] Context-aware completion (e.g., staged files for `git reset --staged`)
- [ ] Tag completion for commands like `git tag`
- [ ] Remote name completion for push/pull commands
- [ ] Commit hash completion for commands like `git cherry-pick`
- [ ] Stash entry completion for `git stash apply`

## See Also

- [Quick Reference](QUICK_REFERENCE.md) - Complete keybinding reference
- [Line Editing](LINE_EDITING.md) - Advanced line editing features
- [Tab Completion](../README.md#tab-completion) - General tab completion features
