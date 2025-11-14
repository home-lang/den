# Built-in Commands

Den Shell provides a comprehensive set of built-in commands that are optimized for performance and integrated directly into the shell.

## Table of Contents

- [File System Commands](#file-system-commands)
  - [ls - List Directory Contents](#ls---list-directory-contents)
  - [cd - Change Directory](#cd---change-directory)
  - [pwd - Print Working Directory](#pwd---print-working-directory)
- [Productivity Commands](#productivity-commands)
  - [calc - Calculator](#calc---calculator)
  - [date - Date and Time](#date---date-and-time)
  - [seq - Sequence Generator](#seq---sequence-generator)
  - [watch - Execute Periodically](#watch---execute-periodically)
- [Shell Control](#shell-control)
  - [exit - Exit Shell](#exit---exit-shell)
  - [export - Set Environment Variables](#export---set-environment-variables)
  - [alias - Create Command Aliases](#alias---create-command-aliases)

---

## File System Commands

### ls - List Directory Contents

The `ls` command lists directory contents with support for common Unix flags and multi-column formatting.

#### Syntax

```bash
ls [OPTIONS] [PATH]
```

#### Options

| Flag | Description |
|------|-------------|
| `-a` | Show all files, including hidden files (those starting with `.`) |
| `-l` | Long format with detailed information |
| `-h` | Human-readable file sizes (with `-l`) |
| `-r` | Reverse sort order |
| `-t` | Sort by modification time, newest first |
| `-S` | Sort by file size, largest first |
| `-R` | Recursively list subdirectories |
| `-1` | List one file per line |
| `-d` | List directory itself, not its contents |

#### Examples

**Basic listing (multi-column format):**
```bash
ls
# Output (columns adapt to terminal width):
# build.zig    examples     package.json  scripts      zig-out
# docs         lib          README.md     src
```

**Show all files including hidden:**
```bash
ls -a
# Output includes .git, .gitignore, etc.
```

**Long format with detailed information:**
```bash
ls -l
# Output:
# total 5560
# -rw-r--r--  1 user  staff  12911 Nov  5 19:35 CHANGELOG.md
# -rw-r--r--  1 user  staff   1442 Nov 10 21:20 Dockerfile
# drwxr-xr-x  3 user  staff     96 Nov 10 21:20 Formula
```

**Long format with human-readable sizes:**
```bash
ls -lh
# Output:
# total 5560
# -rw-r--r--  1 user  staff   12K Nov  5 19:35 CHANGELOG.md
# -rw-r--r--  1 user  staff    1K Nov 10 21:20 Dockerfile
# drwxr-xr-x  3 user  staff   96 Nov 10 21:20 Formula
```

**Sort by time (newest first), reverse order, show all:**
```bash
ls -lart
# Shows all files, sorted by oldest first
```

**Sort by size (largest first):**
```bash
ls -lS
# Output sorted by file size, descending
```

**Recursive listing:**
```bash
ls -R
# Lists current directory and all subdirectories
```

#### Output Format

**Multi-column format** (default):
- Automatically calculates optimal column width based on terminal size
- Entries are arranged in column-major order (down then across)
- Directories are highlighted in cyan

**Long format** (`-l`):
```
[type][permissions] [links] [owner] [group] [size] [date] [name]
```

- **type**: `d` (directory), `l` (symlink), `-` (regular file)
- **permissions**: 9 characters showing read/write/execute for owner/group/others
- **links**: Number of hard links
- **owner**: File owner username
- **group**: File group name
- **size**: File size in bytes (or human-readable with `-h`)
- **date**: Modification time in "Mon DD HH:MM" format
- **name**: File or directory name (directories colored cyan)

**Total blocks:**
The "total" line shows the sum of allocated 512-byte blocks for all files, calculated from the filesystem's actual block allocation.

---

### cd - Change Directory

Change the current working directory.

#### Syntax

```bash
cd [DIRECTORY]
```

#### Examples

```bash
cd /home/user/projects      # Absolute path
cd ../..                    # Relative path
cd ~                        # Home directory
cd                          # Home directory (default)
cd -                        # Previous directory
```

---

### pwd - Print Working Directory

Display the current working directory path.

#### Syntax

```bash
pwd
```

#### Example

```bash
pwd
# Output: /Users/user/projects/den
```

---

## Productivity Commands

### calc - Calculator

Perform arithmetic calculations with support for basic operations.

#### Syntax

```bash
calc EXPRESSION
```

#### Supported Operations

- Addition: `+`
- Subtraction: `-`
- Multiplication: `*`
- Division: `/`
- Modulo: `%`
- Parentheses: `(` `)`

#### Examples

```bash
calc 2 + 2
# Output: 4

calc "10 * (5 + 3)"
# Output: 80

calc "100 / 4"
# Output: 25

calc "17 % 5"
# Output: 2
```

---

### date - Date and Time

Display current date and time information.

#### Syntax

```bash
date [FORMAT]
```

#### Formats

- No arguments: Display current date and time
- `+%s`: Unix timestamp (seconds since epoch)
- `+%Y`: Year (4 digits)
- `+%m`: Month (01-12)
- `+%d`: Day of month (01-31)
- `+%H`: Hour (00-23)
- `+%M`: Minute (00-59)
- `+%S`: Second (00-59)

#### Examples

```bash
date
# Output: 2025-01-15 14:30:45

date +%s
# Output: 1736953845

date +%Y-%m-%d
# Output: 2025-01-15
```

---

### seq - Sequence Generator

Generate sequences of numbers.

#### Syntax

```bash
seq [FIRST [INCREMENT]] LAST
```

#### Arguments

- `LAST`: Generate sequence from 1 to LAST
- `FIRST LAST`: Generate sequence from FIRST to LAST
- `FIRST INCREMENT LAST`: Generate sequence from FIRST to LAST with INCREMENT

#### Examples

```bash
seq 5
# Output:
# 1
# 2
# 3
# 4
# 5

seq 2 5
# Output:
# 2
# 3
# 4
# 5

seq 1 2 10
# Output:
# 1
# 3
# 5
# 7
# 9

seq 10 -2 0
# Output:
# 10
# 8
# 6
# 4
# 2
# 0
```

---

### watch - Execute Periodically

Execute a command repeatedly at specified intervals.

#### Syntax

```bash
watch [-n SECONDS] COMMAND
```

#### Options

- `-n SECONDS`: Interval between executions (default: 2 seconds)

#### Examples

```bash
watch -n 1 date
# Displays current time, updating every second

watch -n 5 "ls -l | wc -l"
# Counts files in directory every 5 seconds
```

---

## Shell Control

### exit - Exit Shell

Exit the Den shell.

#### Syntax

```bash
exit [CODE]
```

#### Arguments

- `CODE`: Optional exit code (default: 0)

#### Examples

```bash
exit          # Exit with code 0
exit 1        # Exit with code 1
```

---

### export - Set Environment Variables

Set environment variables for the current session and child processes.

#### Syntax

```bash
export NAME=VALUE
export NAME="VALUE WITH SPACES"
```

#### Examples

```bash
export PATH="/usr/local/bin:$PATH"
export EDITOR=vim
export NODE_ENV=production
```

---

### alias - Create Command Aliases

Create shortcuts for commonly used commands.

#### Syntax

```bash
alias NAME=COMMAND
alias NAME="COMMAND WITH ARGS"
```

#### Examples

```bash
alias ll="ls -la"
alias ..="cd .."
alias gst="git status"
```

---

## Implementation Details

### Performance Optimizations

1. **ls Multi-column Layout**
   - Dynamic terminal width detection using TIOCGWINSZ ioctl
   - Efficient column calculation to maximize screen usage
   - Column-major ordering for natural reading flow

2. **File Statistics**
   - Uses native `stat()` system calls for accurate metadata
   - Actual block count calculation using `st_blocks` field
   - Efficient single-pass directory iteration

3. **Memory Management**
   - Arena allocators for temporary allocations
   - Proper cleanup with defer patterns
   - Fixed-size buffers where appropriate to avoid dynamic allocation

### Cross-Platform Compatibility

- **Unix/Linux**: Full support for all features
- **macOS**: Full support with BSD-specific optimizations
- **Windows**: Basic support (enhanced support coming soon)

### Signal Handling

The shell properly handles POSIX signals:
- **SIGINT** (Ctrl+C): Gracefully interrupt current command
- **SIGTERM**: Clean shutdown
- **SIGWINCH**: Automatic terminal resize detection

---

## See Also

- [Shell Configuration](./config.md)
- [Plugin Development](../PLUGIN_DEVELOPMENT.md)
- [Command Execution](./ARCHITECTURE.md#command-execution)
