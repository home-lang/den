# Built-in Commands

Den Shell provides a comprehensive set of built-in commands that are optimized for performance and integrated directly into the shell.

## Table of Contents

- [File System Commands](#file-system-commands)
  - [ls - List Directory Contents](#ls---list-directory-contents)
  - [cd - Change Directory](#cd---change-directory)
  - [pwd - Print Working Directory](#pwd---print-working-directory)
  - [tree - Directory Tree](#tree---directory-tree)
- [Search & File Tools](#search--file-tools)
  - [ft - Fuzzy File Finder](#ft---fuzzy-file-finder)
  - [grep - Text Search with Highlighting](#grep---text-search-with-highlighting)
  - [find - File Finder](#find---file-finder)
- [Productivity Commands](#productivity-commands)
  - [calc - Calculator](#calc---calculator)
  - [date - Date and Time](#date---date-and-time)
  - [seq - Sequence Generator](#seq---sequence-generator)
  - [watch - Execute Periodically](#watch---execute-periodically)
  - [base64 - Base64 Encoding/Decoding](#base64---base64-encodingdecoding)
  - [uuid - UUID Generator](#uuid---uuid-generator)
  - [json - JSON Processing](#json---json-processing)
  - [parallel - Parallel Command Execution](#parallel---parallel-command-execution)
  - [timeout - Run Command with Timeout](#timeout---run-command-with-timeout)
- [Network Commands](#network-commands)
  - [http - HTTP Requests](#http---http-requests)
  - [localip - Show Local IP](#localip---show-local-ip)
  - [ip - Show IP Address](#ip---show-ip-address)
  - [web - Open URL in Browser](#web---open-url-in-browser)
  - [net-check - Network Connectivity Check](#net-check---network-connectivity-check)
- [System Commands](#system-commands)
  - [sys-stats - System Statistics](#sys-stats---system-statistics)
  - [netstats - Network Statistics](#netstats---network-statistics)
  - [log-tail - Tail Log Files](#log-tail---tail-log-files)
  - [proc-monitor - Process Monitor](#proc-monitor---process-monitor)
  - [log-parse - Parse Structured Logs](#log-parse---parse-structured-logs)
  - [dotfiles - Dotfiles Management](#dotfiles---dotfiles-management)
- [Shell Control](#shell-control)
  - [exit - Exit Shell](#exit---exit-shell)
  - [export - Set Environment Variables](#export---set-environment-variables)
  - [alias - Create Command Aliases](#alias---create-command-aliases)
  - [reload - Reload Configuration](#reload---reload-configuration)
- [macOS Commands](#macos-commands)
  - [copyssh - Copy SSH Key](#copyssh---copy-ssh-key)
  - [reloaddns - Reload DNS](#reloaddns---reload-dns)
  - [emptytrash - Empty Trash](#emptytrash---empty-trash)
  - [show - Show Hidden Files](#show---show-hidden-files)
  - [hide - Hide Hidden Files](#hide---hide-hidden-files)
- [Developer Commands](#developer-commands)
  - [wip - Work in Progress Commit](#wip---work-in-progress-commit)
  - [code - Open in VS Code](#code---open-in-vs-code)
  - [pstorm - Open in PhpStorm](#pstorm---open-in-phpstorm)
  - [bookmark - Directory Bookmarks](#bookmark---directory-bookmarks)
  - [library - Shell Function Libraries](#library---shell-function-libraries)
  - [hook - Custom Command Hooks](#hook---custom-command-hooks)
  - [shrug - Copy Shrug Emoji](#shrug---copy-shrug-emoji)

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

### tree - Directory Tree

Display directory structure in a tree format.

#### Syntax

```bash
tree [OPTIONS] [PATH]
```

#### Options

| Flag | Description |
|------|-------------|
| `-d` | Show directories only |
| `-L N` | Limit depth to N levels |
| `-a` | Show hidden files |

#### Examples

```bash
tree
# Output:
# .
# ├── src
# │   ├── main.zig
# │   └── shell.zig
# └── build.zig

tree -L 2
# Limit to 2 levels deep

tree -d
# Show only directories

tree src -a
# Show hidden files in src directory
```

---

## Search & File Tools

### ft - Fuzzy File Finder

Fast fuzzy file finder with scoring-based matching.

#### Syntax

```bash
ft [OPTIONS] PATTERN
```

#### Options

| Flag | Description |
|------|-------------|
| `-t TYPE` | Filter by type: `f` (files) or `d` (directories) |
| `-d DEPTH` | Maximum search depth (default: 10) |
| `-n LIMIT` | Maximum number of results (default: 50) |
| `-p PATH` | Starting directory (default: current) |

#### Examples

```bash
ft main
# Find files matching "main"
# Output:
# src/main.zig (score: 100)
# docs/main.md (score: 80)

ft -t f .zig
# Find only files matching ".zig"

ft -d 3 config
# Search only 3 levels deep for "config"

ft -n 10 -p src mod
# Find top 10 matches for "mod" in src/
```

#### Scoring Algorithm

The fuzzy matcher uses a scoring system:
- **Exact match**: 100 points
- **Prefix match**: 90 points
- **Substring match**: 70 points
- **Suffix match**: 50 points
- **Fuzzy match**: 30+ points (based on consecutive matches)

Results are sorted by score, highest first.

---

### grep - Text Search with Highlighting

Search for patterns in files with colored highlighting.

#### Syntax

```bash
grep [OPTIONS] PATTERN FILE...
```

#### Options

| Flag | Description |
|------|-------------|
| `-i` | Case insensitive search |
| `-n` | Show line numbers |
| `-v` | Invert match (show non-matching lines) |
| `-c` | Count matches only |
| `-H` | Show filename for each match |
| `--color` | Enable highlighting (default) |
| `--no-color` | Disable highlighting |

#### Examples

```bash
grep fn src/main.zig
# Output with highlighted matches:
# pub fn main() !void {

grep -n TODO src/*.zig
# Show line numbers with matches

grep -i error *.log
# Case-insensitive search

grep -c import src/shell.zig
# Count number of import lines

grep -v test src/main.zig
# Show lines NOT containing "test"

grep --no-color pattern file.txt
# Plain output without colors
```

#### Highlighting

- **Matches**: Bold red
- **Line numbers**: Green
- **Filenames**: Magenta (when searching multiple files)

---

### find - File Finder

Find files by name pattern.

#### Syntax

```bash
find [PATH] -name PATTERN
```

#### Examples

```bash
find . -name "*.zig"
# Find all .zig files

find src -name "mod.zig"
# Find mod.zig in src directory
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

### base64 - Base64 Encoding/Decoding

Encode or decode data using Base64 encoding.

#### Syntax

```bash
base64 [OPTIONS] STRING
```

#### Options

| Flag | Description |
|------|-------------|
| `-d`, `--decode` | Decode Base64 input instead of encoding |

#### Examples

**Encode a string:**
```bash
base64 'Hello World'
# Output: SGVsbG8gV29ybGQ=
```

**Decode a Base64 string:**
```bash
base64 -d 'SGVsbG8gV29ybGQ='
# Output: Hello World
```

**Encoding with special characters:**
```bash
base64 'User:Password123!'
# Output: VXNlcjpQYXNzd29yZDEyMyE=
```

**Decoding back:**
```bash
base64 -d 'VXNlcjpQYXNzd29yZDEyMyE='
# Output: User:Password123!
```

#### Use Cases

- **API Authentication**: Encode credentials for Basic Authentication headers
- **Data Transfer**: Safely transmit binary data in text format
- **Configuration**: Encode sensitive data in configuration files
- **Email Attachments**: Base64 is used in MIME email encoding

#### Technical Details

- Uses standard Base64 alphabet (RFC 4648)
- Automatically handles padding with `=` characters
- Supports encoding/decoding of arbitrary length strings
- Error handling for invalid Base64 input during decoding

---

### uuid - UUID Generator

Generate a universally unique identifier (UUID) version 4.

#### Syntax

```bash
uuid
```

#### Examples

**Generate a UUID:**
```bash
uuid
# Output: df155616-5763-4a4b-b359-6719554d3928
```

**Generate multiple UUIDs:**
```bash
uuid && uuid && uuid
# Output:
# a3c2f9b1-4d7e-4a8c-9f1b-2e5d8a7c3f4b
# 7f8e2c4d-9a1b-4c5e-8d3f-6a9b2c7e4f1d
# 2b9c7e4f-1d8a-4f3e-9c2b-5a8d3f7e1c4b
```

**Use in scripts:**
```bash
export SESSION_ID=$(uuid)
echo "Session ID: $SESSION_ID"
```

#### Use Cases

- **Session IDs**: Generate unique session identifiers for web applications
- **Database Keys**: Create unique primary keys or identifiers
- **File Names**: Generate unique temporary file names
- **Request Tracking**: Track requests across distributed systems
- **Testing**: Create unique test data identifiers

#### Technical Details

- Generates UUID version 4 (random-based)
- Uses cryptographically random data from system RNG
- Properly sets version bits (4) and variant bits (RFC 4122)
- Format: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
  - Where `x` is a random hexadecimal digit
  - `4` indicates version 4
  - `y` is one of `8`, `9`, `a`, or `b` (variant bits)
- 122 bits of randomness (2^122 possible values)
- Collision probability is astronomically low

---

### json - JSON Processing

Parse and manipulate JSON data.

#### Syntax

```bash
json [OPTIONS] [FILE]
```

#### Options

| Flag | Description |
|------|-------------|
| `-p`, `--pretty` | Pretty print JSON |
| `-c`, `--compact` | Compact output |
| `-q QUERY` | JQ-style query (basic support) |

#### Examples

```bash
echo '{"name":"den"}' | json -p
# Output:
# {
#   "name": "den"
# }

json -q '.name' data.json
# Extract "name" field

json -c pretty.json
# Compact JSON output
```

---

### parallel - Parallel Command Execution

Execute multiple commands in parallel.

#### Syntax

```bash
parallel COMMAND1 ::: COMMAND2 ::: COMMAND3
```

#### Examples

```bash
parallel "sleep 1; echo one" ::: "sleep 1; echo two" ::: "sleep 1; echo three"
# All three commands run simultaneously
# Completes in ~1 second instead of ~3 seconds
```

---

### timeout - Run Command with Timeout

Execute a command with a time limit.

#### Syntax

```bash
timeout SECONDS COMMAND [ARGS...]
```

#### Examples

```bash
timeout 5 sleep 10
# Terminates after 5 seconds

timeout 30 curl https://example.com
# Timeout after 30 seconds if no response

timeout 10 ./long-running-script.sh
# Kill script if it runs longer than 10 seconds
```

#### Exit Codes

- `0`: Command completed successfully within timeout
- `124`: Command timed out
- Other: Exit code from the command

---

## Network Commands

### http - HTTP Requests

Make HTTP requests from the command line.

#### Syntax

```bash
http [METHOD] URL [OPTIONS]
```

#### Options

| Flag | Description |
|------|-------------|
| `-X METHOD` | HTTP method (GET, POST, PUT, DELETE) |
| `-H HEADER` | Add custom header |
| `-d DATA` | Request body data |
| `-o FILE` | Output to file |

#### Examples

```bash
http https://api.example.com/users
# GET request (default)

http -X POST -d '{"name":"test"}' https://api.example.com/users
# POST request with JSON body

http -H "Authorization: Bearer token" https://api.example.com/protected
# Request with custom header
```

---

### localip - Show Local IP

Display the local IP address of the machine.

#### Syntax

```bash
localip
```

#### Example

```bash
localip
# Output: 192.168.1.100
```

---

### ip - Show IP Address

Display IP address information.

#### Syntax

```bash
ip
```

#### Example

```bash
ip
# Output: Shows network interface information
```

---

### web - Open URL in Browser

Open a URL in the default web browser.

#### Syntax

```bash
web URL
```

#### Examples

```bash
web https://github.com
# Opens GitHub in default browser

web http://localhost:3000
# Opens local development server
```

---

### net-check - Network Connectivity Check

Check network connectivity to a host, optionally testing a specific port.

#### Syntax

```bash
net-check [OPTIONS] [HOST]
```

#### Options

| Flag | Description |
|------|-------------|
| `-q`, `--quiet` | Only return exit code (0=ok, 1=fail) |
| `-p`, `--port` | Check specific port connectivity |

#### Examples

```bash
net-check
# Check connectivity to google.com (default)
# Output:
# === Network Connectivity Check ===
# Connectivity Check: google.com
#   ✓ Host is reachable
# Network is reachable

net-check example.com
# Check specific host

net-check -p 443 example.com
# Check if port 443 is open on example.com
# Output:
# === Network Connectivity Check ===
# Connectivity Check: example.com
#   ✓ Host is reachable
# Port Check: example.com:443
#   ✓ Port 443 is open
# Network is reachable

net-check -q google.com && echo "Online" || echo "Offline"
# Quiet mode for scripting
```

#### Exit Codes

- `0`: Host (and port if specified) is reachable
- `1`: Connection failed

#### Use Cases

- **Health checks**: Verify connectivity before running network-dependent scripts
- **Monitoring**: Quick connectivity tests in automation
- **Debugging**: Test if specific ports are accessible

---

## System Commands

### sys-stats - System Statistics

Display system statistics including CPU, memory, disk usage, and uptime.

#### Syntax

```bash
sys-stats
```

#### Example

```bash
sys-stats
# Output:
# === System Statistics ===
#
# CPU Info:
#   Architecture: arm64
#
# Memory Info:
#   Total: 16.00 GB
#   Used: 12.34 GB
#   Free: 3.66 GB
#   Usage: 77.1%
#
# Disk Info:
#   Total: 500.00 GB
#   Free: 125.00 GB
#   Used: 375.00 GB
#   Usage: 75.0%
#
# System:
#   Uptime: 5 days, 3 hours, 45 minutes
```

#### Information Displayed

| Section | Details |
|---------|---------|
| **CPU Info** | Architecture (arm64, x86_64, etc.) |
| **Memory Info** | Total, used, free RAM and usage percentage |
| **Disk Info** | Total, used, free disk space for root volume |
| **System** | System uptime in human-readable format |

---

### netstats - Network Statistics

Display network interface information and connection statistics.

#### Syntax

```bash
netstats
```

#### Example

```bash
netstats
# Output:
# === Network Statistics ===
#
# Network Interfaces:
#   lo0: 127.0.0.1
#   en0: 192.168.1.100
#   en1: 10.0.0.50
#
# Active Connections (TCP):
#   State: ESTABLISHED - Count: 15
#   State: LISTEN - Count: 8
#   State: TIME_WAIT - Count: 3
#
# Total TCP Connections: 26
```

#### Information Displayed

| Section | Details |
|---------|---------|
| **Network Interfaces** | All network interfaces with their IP addresses |
| **Active Connections** | TCP connections grouped by state |
| **Total Connections** | Sum of all TCP connections |

---

### log-tail - Tail Log Files

Tail log files with filtering and automatic highlighting of log levels.

#### Syntax

```bash
log-tail [OPTIONS] FILE
```

#### Options

| Flag | Description |
|------|-------------|
| `-n`, `--lines N` | Show last N lines (default: 10) |
| `-f`, `--follow` | Follow file for new content (like tail -f) |
| `-g`, `--grep PATTERN` | Filter lines by pattern |
| `-H`, `--highlight PATTERN` | Highlight pattern in output |

#### Examples

```bash
log-tail /var/log/system.log
# Show last 10 lines with auto-highlighting

log-tail -n 50 app.log
# Show last 50 lines

log-tail -f server.log
# Follow log file for new entries

log-tail -g ERROR server.log
# Show only lines containing "ERROR"

log-tail -f -g "ERROR|WARN" app.log
# Follow and filter for errors and warnings

log-tail -H "timeout" access.log
# Highlight "timeout" occurrences in red
```

#### Auto-Highlighting

Log levels are automatically colorized:

| Level | Color |
|-------|-------|
| ERROR, FATAL, CRITICAL | Red (bold) |
| WARN, WARNING | Yellow (bold) |
| INFO | Green (bold) |
| DEBUG, TRACE | Dim |

#### Use Cases

- **Debugging**: Monitor application logs in real-time
- **Error tracking**: Filter for specific error patterns
- **Log analysis**: Review recent log entries with color highlighting

---

### proc-monitor - Process Monitor

Monitor system processes with filtering and color-coded CPU usage.

#### Syntax

```bash
proc-monitor [OPTIONS] [PATTERN]
```

#### Options

| Flag | Description |
|------|-------------|
| `-p`, `--pid PID` | Monitor a specific process by PID |
| `-n`, `--interval N` | Update interval in seconds (default: 2) |
| `-c`, `--count N` | Number of iterations (default: continuous) |
| `-s`, `--sort FIELD` | Sort by: cpu, mem, pid, name (default: cpu) |

#### Examples

```bash
proc-monitor
# Show top processes by CPU (updates every 2s)

proc-monitor -c 1
# Show processes once and exit

proc-monitor -p 1234
# Monitor specific process ID

proc-monitor node
# Monitor all processes matching "node"

proc-monitor -n 5 -c 10
# Update every 5 seconds, 10 iterations

proc-monitor docker
# Monitor Docker-related processes
```

#### Output Columns

| Column | Description |
|--------|-------------|
| PID | Process ID |
| %CPU | CPU usage percentage |
| %MEM | Memory usage percentage |
| RSS | Resident Set Size (actual memory used) |
| COMMAND | Process name/command |

#### Color Coding

| CPU Usage | Color |
|-----------|-------|
| >= 50% | Red (bold) |
| >= 20% | Yellow (bold) |
| < 20% | Normal |

#### Use Cases

- **Performance monitoring**: Track resource-heavy processes
- **Debugging**: Monitor specific application processes
- **System administration**: Check overall process health

---

### log-parse - Parse Structured Logs

Parse and query structured log files in JSON, key-value, or CSV formats.

#### Syntax

```bash
log-parse [OPTIONS] FILE
```

#### Options

| Flag | Description |
|------|-------------|
| `-f`, `--format FORMAT` | Log format: json, kv, csv, auto (default) |
| `-s`, `--select FIELDS` | Select specific fields (comma-separated) |
| `-w`, `--where EXPR` | Filter by field=value |
| `-c`, `--count` | Only show count of matching lines |
| `-p`, `--pretty` | Pretty print with colors |

#### Supported Formats

| Format | Example |
|--------|---------|
| **JSON** | `{"level":"INFO","msg":"Started"}` |
| **Key-Value** | `level=INFO msg="Started"` |
| **CSV** | `level,timestamp,message` (first line is header) |

#### Examples

```bash
log-parse app.log
# Auto-detect format and show all fields

log-parse -f json server.log
# Explicitly parse as JSON

log-parse -s level,message app.log
# Select only level and message fields

log-parse -w level=ERROR app.log
# Filter for error lines only

log-parse -c -w level=ERROR app.log
# Count number of errors

log-parse -p -w level=WARN app.log
# Pretty print warnings with colors
```

#### Color Coding

When using `-p/--pretty`, log levels are color-coded:

| Level | Color |
|-------|-------|
| ERROR, FATAL | Red |
| WARN | Yellow |
| INFO | Green |
| DEBUG, TRACE | Dim |

#### Use Cases

- **Log analysis**: Extract specific fields from logs
- **Error counting**: Count errors without reading full logs
- **Structured queries**: Filter logs by specific criteria

---

### dotfiles - Dotfiles Management

Manage your dotfiles with backup, linking, and editing capabilities.

#### Syntax

```bash
dotfiles <command> [args]
```

#### Commands

| Command | Description |
|---------|-------------|
| `list` | List tracked dotfiles in home directory |
| `status` | Show status of common dotfiles |
| `link <file>` | Create symlink from current dir to home |
| `unlink <file>` | Remove symlink |
| `backup <file>` | Create .bak backup of dotfile |
| `restore <file>` | Restore from .bak backup |
| `edit <file>` | Open dotfile in $EDITOR |
| `diff <file>` | Show diff between file and backup |

#### Examples

```bash
dotfiles list
# List all dotfiles in home directory

dotfiles status
# Show status of common dotfiles (.bashrc, .zshrc, etc.)

dotfiles backup .zshrc
# Create ~/.zshrc.bak

dotfiles edit .gitconfig
# Open ~/.gitconfig in your editor

dotfiles link .vimrc
# Create symlink: ~/.vimrc → $(pwd)/.vimrc

dotfiles diff .zshrc
# Show differences between .zshrc and .zshrc.bak
```

#### Status Indicators

| Status | Meaning |
|--------|---------|
| `[ok]` | File exists and is normal |
| `[symlink]` | File is a symbolic link |
| `[modified]` | Backup exists (may have changes) |
| `[missing]` | File doesn't exist |

#### Workflow Example

```bash
# 1. Backup existing dotfile
dotfiles backup .zshrc

# 2. Make changes
dotfiles edit .zshrc

# 3. View changes
dotfiles diff .zshrc

# 4. If needed, restore backup
dotfiles restore .zshrc
```

#### Use Cases

- **Dotfile management**: Track and manage configuration files
- **Safe editing**: Backup before making changes
- **Symlink setup**: Link dotfiles from a central repository

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

### reload - Reload Configuration

Reload shell configuration without restarting.

#### Syntax

```bash
reload [OPTIONS]
```

#### Options

| Flag | Description |
|------|-------------|
| `-v`, `--verbose` | Show detailed reload information |
| `--aliases` | Reload only aliases |
| `--config` | Reload only config (no aliases) |

#### Examples

```bash
reload
# Output: Configuration reloaded

reload -v
# Output:
# Configuration loaded from: den.jsonc (den.jsonc)
# Aliases reloaded from configuration
# Reload complete

reload --aliases
# Only reload aliases from config
```

#### Configuration Search Order

1. `./den.jsonc`
2. `./package.jsonc` (with "den" key)
3. `./config/den.jsonc`
4. `./.config/den.jsonc`
5. `~/.config/den.jsonc`
6. `~/package.jsonc` (with "den" key)

#### Hot Reload

Set `"hot_reload": true` in your config to automatically reload when the config file changes.

---

## macOS Commands

These commands are optimized for macOS but may work on other Unix systems.

### copyssh - Copy SSH Key

Copy your SSH public key to the clipboard.

#### Syntax

```bash
copyssh
```

#### Example

```bash
copyssh
# Copies ~/.ssh/id_rsa.pub to clipboard
# Output: SSH key copied to clipboard
```

---

### reloaddns - Reload DNS

Flush the DNS cache on macOS.

#### Syntax

```bash
reloaddns
```

#### Example

```bash
reloaddns
# Flushes DNS cache
# Output: DNS cache flushed
```

---

### emptytrash - Empty Trash

Empty the macOS Trash.

#### Syntax

```bash
emptytrash
```

#### Example

```bash
emptytrash
# Empties the Trash
```

---

### show - Show Hidden Files

Show hidden files in Finder.

#### Syntax

```bash
show
```

#### Example

```bash
show
# Makes hidden files visible in Finder
```

---

### hide - Hide Hidden Files

Hide hidden files in Finder.

#### Syntax

```bash
hide
```

#### Example

```bash
hide
# Hides hidden files in Finder (default macOS behavior)
```

---

## Developer Commands

### wip - Work in Progress Commit

Create a quick "work in progress" git commit.

#### Syntax

```bash
wip [MESSAGE]
```

#### Examples

```bash
wip
# Creates commit with message "wip"

wip "saving progress on feature"
# Creates commit with custom message
```

---

### code - Open in VS Code

Open files or directories in Visual Studio Code.

#### Syntax

```bash
code [PATH]
```

#### Examples

```bash
code .
# Open current directory in VS Code

code src/main.zig
# Open specific file
```

---

### pstorm - Open in PhpStorm

Open files or directories in PhpStorm.

#### Syntax

```bash
pstorm [PATH]
```

#### Examples

```bash
pstorm .
# Open current directory in PhpStorm

pstorm src/
# Open src directory
```

---

### bookmark - Directory Bookmarks

Manage directory bookmarks for quick navigation.

#### Syntax

```bash
bookmark [COMMAND] [NAME] [PATH]
```

#### Commands

| Command | Description |
|---------|-------------|
| `add NAME [PATH]` | Add bookmark (default: current directory) |
| `rm NAME` | Remove bookmark |
| `list` | List all bookmarks |
| `go NAME` | Go to bookmarked directory |

#### Examples

```bash
bookmark add projects ~/Documents/Projects
# Add bookmark named "projects"

bookmark list
# Show all bookmarks

bookmark go projects
# Navigate to bookmarked directory

bookmark rm projects
# Remove bookmark
```

---

### library - Shell Function Libraries

Manage shell function libraries. Libraries are collections of reusable shell functions that can be loaded into your session.

#### Syntax

```bash
library <command> [args]
```

#### Commands

| Command | Description |
|---------|-------------|
| `list` | List available libraries |
| `info <name>` | Show library information |
| `load <name\|path>` | Load a library into current session |
| `unload <name>` | Unload a library |
| `create <name>` | Create a new library template |
| `path` | Show library search paths |

#### Library Locations

Libraries are searched in the following locations:
- `~/.config/den/lib/` - User libraries
- `/usr/local/share/den/lib/` - System libraries

#### Examples

**List available libraries:**
```bash
library list
# === Shell Libraries ===
#
# User libraries: /Users/you/.config/den/lib
#   • git-helpers.den
#   • docker-utils.sh
#
# System libraries: /usr/local/share/den/lib
#   (none)
```

**Show library search paths:**
```bash
library path
# === Library Search Paths ===
#
# ✓ 1. /Users/you/.config/den/lib
# ✗ 2. /usr/local/share/den/lib
# ✗ 3. /usr/share/den/lib
```

**Create a new library:**
```bash
library create my-utils
# ✓ Created library: /Users/you/.config/den/lib/my-utils.den
#
# Next steps:
#   1. Edit: dotfiles edit /Users/you/.config/den/lib/my-utils.den
#   2. Load: source /Users/you/.config/den/lib/my-utils.den
#   3. Use:  my-utils_hello
```

**Show library info:**
```bash
library info git-helpers
# === Library: git-helpers ===
#
# Path: /Users/you/.config/den/lib/git-helpers.den
# Size: 1234 bytes
#
# Description:
#   git-helpers - Den Shell Library
#   Git workflow helper functions
#
# Functions:
#   • git_checkout_branch
#   • git_delete_merged
#   • git_rebase_main
```

**Load a library:**
```bash
library load git-helpers
# Loaded: git-helpers
```

---

### hook - Custom Command Hooks

Register and manage custom hooks that trigger before specific commands.

#### Syntax

```bash
hook <command> [args]
```

#### Commands

| Command | Description |
|---------|-------------|
| `list` | List all registered hooks |
| `add <name> <pattern> <script>` | Register a new hook |
| `remove <name>` | Remove a hook by name |
| `enable <name>` | Enable a disabled hook |
| `disable <name>` | Disable a hook |
| `test <command>` | Test which hooks would match |

#### Examples

**Register hooks for common commands:**
```bash
# Pre-push notification
hook add git:push "git push" "echo 'Pushing to remote...'"

# Pre-install notification
hook add npm:install "npm install" "echo 'Installing dependencies...'"

# Docker build notification
hook add docker:build "docker build" "echo 'Building image...'"
```

**List registered hooks:**
```bash
hook list
# === Registered Hooks ===
#
# ● git:push
#     Pattern: git push
#     Script:  echo 'Pushing to remote...'
```

**Test which hooks match a command:**
```bash
hook test "git push origin main"
# Hooks matching 'git push origin main':
#
#   ✓ git:push
#       → echo 'Pushing to remote...'
```

**Disable a hook temporarily:**
```bash
hook disable git:push
# ✓ Disabled hook 'git:push'

hook enable git:push
# ✓ Enabled hook 'git:push'
```

**Remove a hook:**
```bash
hook remove git:push
# ✓ Removed hook 'git:push'
```

#### Hook Conditions

Hooks support conditional execution based on:
- **file_exists**: Run only if a file exists
- **env_set**: Run only if an environment variable is set
- **env_equals**: Run only if an env var equals a specific value

Note: Conditions are configured programmatically through the plugin API.

---

### shrug - Copy Shrug Emoji

Copy the shrug emoji ¯\_(ツ)_/¯ to clipboard.

#### Syntax

```bash
shrug
```

#### Example

```bash
shrug
# Copies ¯\_(ツ)_/¯ to clipboard
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
