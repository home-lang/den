# Advanced Usage

This guide covers advanced features, optimization techniques, and power-user workflows in Den Shell.

## Table of Contents

1. [Advanced Scripting](#advanced-scripting)
2. [Performance Optimization](#performance-optimization)
3. [Memory Management](#memory-management)
4. [Concurrency & Parallelism](#concurrency--parallelism)
5. [Plugin Development](#plugin-development)
6. [Shell Integration](#shell-integration)
7. [Debugging & Profiling](#debugging--profiling)
8. [Custom Completions](#custom-completions)
9. [Advanced Job Control](#advanced-job-control)
10. [Security Best Practices](#security-best-practices)

## Advanced Scripting

### Complex Variable Expansion

```bash
# String manipulation
STRING="Hello World"
echo ${STRING:0:5}        # "Hello" (substring)
echo ${STRING#Hello }     # "World" (remove prefix)
echo ${STRING%World}      # "Hello " (remove suffix)
echo ${STRING/World/Den}  # "Hello Den" (replace)

# Array-like expansion
FILES=(*.zig)
echo ${FILES[0]}          # First file
echo ${#FILES[@]}         # Number of files

# Indirect expansion
VAR_NAME="HOME"
echo ${!VAR_NAME}         # Value of $HOME
```

### Advanced Arithmetic

```bash
# Binary operations
echo $((0xFF))            # 255 (hex)
echo $((0777))            # 511 (octal)
echo $((2#1010))          # 10 (binary)

# Bitwise operations
echo $((5 & 3))           # 1 (AND)
echo $((5 | 3))           # 7 (OR)
echo $((5 ^ 3))           # 6 (XOR)
echo $((5 << 1))          # 10 (left shift)
echo $((5 >> 1))          # 2 (right shift)

# Comparison in arithmetic
echo $((10 > 5))          # 1 (true)
echo $((10 == 5))         # 0 (false)
```

### Error Handling Patterns

```bash
#!/usr/bin/env den

# Exit on error with cleanup
trap cleanup EXIT
trap 'error_handler $? $LINENO' ERR

cleanup() {
    echo "Cleaning up..."
    # Remove temporary files
    rm -f /tmp/script.$$.*
}

error_handler() {
    echo "Error $1 on line $2"
    exit $1
}

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Your script here
```

### Advanced Control Flow

```bash
# Case statements
case "$1" in
    start)
        echo "Starting service"
        ;;
    stop)
        echo "Stopping service"
        ;;
    restart)
        echo "Restarting service"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

# Select menus
select OPTION in "Build" "Test" "Deploy" "Quit"; do
    case $OPTION in
        "Build") zig build ;;
        "Test") zig build test ;;
        "Deploy") ./deploy.sh ;;
        "Quit") break ;;
    esac
done
```

### Advanced Functions

```bash
# Local variables
function deploy() {
    local ENV="$1"
    local VERSION="$2"

    if test -z "$ENV" -o -z "$VERSION"; then
        echo "Usage: deploy <env> <version>"
        return 1
    fi

    echo "Deploying $VERSION to $ENV"
}

# Return values
function get_version() {
    cat VERSION
}

VERSION=$(get_version)

# Function with defaults
function build() {
    local target="${1:-ReleaseFast}"
    local output="${2:-./zig-out/bin/den}"

    zig build -Doptimize=$target -Doutput=$output
}
```

## Performance Optimization

### Command Execution Optimization

```bash
# Avoid subshells when possible
# Bad (spawns subshell)
COUNT=$(cat file.txt | wc -l)

# Good (uses builtin)
read COUNT < <(wc -l < file.txt)

# Use builtins over external commands
# Bad
/usr/bin/test -f file.txt

# Good
test -f file.txt
```

### Pipeline Optimization

```bash
# Minimize pipeline stages
# Bad (3 processes)
cat file.txt | grep pattern | wc -l

# Better (2 processes)
grep pattern file.txt | wc -l

# Best (1 process with builtin)
grep -c pattern file.txt
```

### Glob Optimization

```bash
# Use specific patterns
# Slow (searches everything)
find . -name "*.zig"

# Fast (glob expansion)
ls **/*.zig

# Even faster (limited scope)
ls src/**/*.zig
```

### Caching Strategies

```bash
# Cache command lookups
hash zig
hash git
hash npm

# Cache heavy computations
if test ! -f .cache/result; then
    expensive_computation > .cache/result
fi
RESULT=$(cat .cache/result)

# Cache file lists
FILE_LIST=/tmp/files.$$
ls -1 *.zig > $FILE_LIST
while read file; do
    process "$file"
done < $FILE_LIST
rm $FILE_LIST
```

## Memory Management

### Memory-Efficient Patterns

```bash
# Stream large files instead of loading
# Bad (loads entire file)
CONTENT=$(cat large_file.txt)
echo "$CONTENT" | grep pattern

# Good (streams)
grep pattern large_file.txt

# Process line by line
while IFS= read -r line; do
    process "$line"
done < large_file.txt
```

### Resource Cleanup

```bash
# Ensure cleanup with trap
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Use the temp directory
cd $TEMP_DIR
# ... do work ...
# Cleanup happens automatically
```

### Background Job Management

```bash
# Limit concurrent jobs
MAX_JOBS=4
JOB_COUNT=0

for file in *.zig; do
    # Wait if at limit
    while test $JOB_COUNT -ge $MAX_JOBS; do
        wait -n  # Wait for any job
        JOB_COUNT=$((JOB_COUNT - 1))
    done

    # Start background job
    process "$file" &
    JOB_COUNT=$((JOB_COUNT + 1))
done

# Wait for remaining jobs
wait
```

## Concurrency & Parallelism

### Parallel Command Execution

```bash
# Run commands in parallel
command1 &
command2 &
command3 &
wait  # Wait for all

# Parallel processing with builtin
parallel "process {}" ::: *.zig

# Parallel pipeline
cat list.txt | parallel -j4 process
```

### Thread Pool Usage

Den automatically uses thread pools for:
- History indexing
- Tab completion generation
- Plugin operations

Configure thread pool:

```jsonc
{
  "concurrency": {
    "threadPoolSize": 4,
    "maxBackgroundJobs": 10
  }
}
```

### Lock-Free Operations

```bash
# Atomic file operations
# Use temp file + rename for atomicity
echo "data" > file.tmp
mv file.tmp file.txt  # Atomic on POSIX

# Avoid race conditions
# Bad (race between test and create)
if test ! -f lock; then
    touch lock
fi

# Good (atomic test-and-set)
if ln -s $$ lock 2>/dev/null; then
    # Got lock
    trap "rm -f lock" EXIT
fi
```

## Plugin Development

### Creating a Plugin

```zig
// src/plugins/my_plugin.zig
const std = @import("std");
const plugin = @import("../plugins/interface.zig");

pub const MyPlugin = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*MyPlugin {
        const self = try allocator.create(MyPlugin);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *MyPlugin) void {
        self.allocator.destroy(self);
    }

    pub fn onCommand(self: *MyPlugin, cmd: []const u8) !void {
        // Called before command execution
        std.debug.print("Executing: {s}\n", .{cmd});
    }

    pub fn onComplete(self: *MyPlugin, partial: []const u8) ![][]const u8 {
        // Return completion suggestions
        var suggestions = std.ArrayList([]const u8).init(self.allocator);
        // ... add suggestions ...
        return suggestions.toOwnedSlice();
    }
};
```

### Plugin Configuration

```jsonc
{
  "plugins": {
    "enabled": ["my-plugin"],
    "my-plugin": {
      "option1": "value1",
      "option2": true
    }
  }
}
```

### Plugin Hooks

Available hooks:
- `onCommand`: Before command execution
- `onComplete`: During tab completion
- `onPrompt`: Before displaying prompt
- `onExit`: Before shell exit

## Shell Integration

### Vim Integration

```vim
" In ~/.vimrc
" Use Den for shell commands
set shell=/path/to/den

" Quick terminal
nnoremap <leader>t :terminal den<CR>
```

### Tmux Integration

```bash
# In ~/.tmux.conf
set-option -g default-shell /path/to/den

# Quick pane with Den
bind-key d split-window -h "den"
```

### IDE Integration

**VS Code** (`settings.json`):
```json
{
  "terminal.integrated.defaultProfile.osx": "Den",
  "terminal.integrated.profiles.osx": {
    "Den": {
      "path": "/path/to/den"
    }
  }
}
```

## Debugging & Profiling

### Debug Mode

```bash
# Enable debug output
export DEN_DEBUG=1
den script.sh

# Trace execution
set -x
command1
command2
set +x
```

### Profiling

```bash
# Profile startup time
time den -c "exit"

# Profile script execution
den --profile script.sh

# Profile with built-in profiler
den --profile-output=profile.json script.sh
```

### Memory Profiling

```bash
# Check memory usage
den --mem-profile script.sh

# Profile with external tool
valgrind --tool=massif den script.sh
```

### Performance Analysis

```bash
# Benchmark command execution
bench command "ls -la"

# Compare implementations
bench parallel "
    process_v1 file
    process_v2 file
"
```

## Custom Completions

### Basic Completion

```bash
# Complete function
_my_command_complete() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    local suggestions="start stop restart status"

    COMPREPLY=($(compgen -W "$suggestions" -- "$current"))
}

complete -F _my_command_complete my_command
```

### Advanced Completion

```bash
# Context-aware completion
_git_like_complete() {
    local cmd="${COMP_WORDS[1]}"

    case "$cmd" in
        commit)
            # Complete file names
            COMPREPLY=($(compgen -f -- "${COMP_WORDS[COMP_CWORD]}"))
            ;;
        checkout)
            # Complete branch names
            local branches=$(git branch | cut -c3-)
            COMPREPLY=($(compgen -W "$branches" -- "${COMP_WORDS[COMP_CWORD]}"))
            ;;
    esac
}
```

### Dynamic Completion

```bash
# Generate completions dynamically
_dynamic_complete() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    local suggestions=$(my_command --list-options)

    COMPREPLY=($(compgen -W "$suggestions" -- "$current"))
}
```

## Advanced Job Control

### Job Priorities

```bash
# Set job priority
nice -n 10 long_process &

# Adjust running job
renice +5 -p $!
```

### Job Monitoring

```bash
# Monitor job status
watch_job() {
    local pid=$1
    while kill -0 $pid 2>/dev/null; do
        echo "Job $pid still running..."
        sleep 1
    done
    echo "Job $pid completed"
}

long_process &
watch_job $!
```

### Job Synchronization

```bash
# Wait for specific jobs
JOB1_PID=$(job1 &)
JOB2_PID=$(job2 &)

wait $JOB1_PID || echo "Job1 failed"
wait $JOB2_PID || echo "Job2 failed"

# Wait with timeout
timeout 30 wait $JOB1_PID || echo "Timeout"
```

## Security Best Practices

### Input Validation

```bash
# Validate user input
read -p "Enter filename: " filename

# Check for dangerous characters
if echo "$filename" | grep -q '[;&|]'; then
    echo "Invalid filename"
    exit 1
fi

# Sanitize input
filename=$(echo "$filename" | tr -cd '[:alnum:]._-')
```

### Secure Temporary Files

```bash
# Use mktemp for secure temp files
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Secure temp directory
TEMP_DIR=$(mktemp -d)
chmod 700 $TEMP_DIR
trap "rm -rf $TEMP_DIR" EXIT
```

### Environment Variable Safety

```bash
# Quote all variable expansions
rm "$FILE"  # Good
rm $FILE    # Bad (word splitting)

# Use arrays for command arguments
args=("--option" "value with spaces")
command "${args[@]}"

# Prevent code injection
# Bad
eval "echo $USER_INPUT"

# Good
echo "$USER_INPUT"
```

### Privilege Management

```bash
# Check if running as root
if test $(id -u) -eq 0; then
    echo "Don't run as root"
    exit 1
fi

# Drop privileges when needed
if test -n "$SUDO_USER"; then
    # Running under sudo, drop to original user
    su -c "command" $SUDO_USER
fi
```

## Best Practices Summary

### Script Structure

```bash
#!/usr/bin/env den
# Script description
# Author: Your Name
# Date: 2024-01-01

set -euo pipefail  # Strict mode

# Constants
readonly SCRIPT_DIR=$(dirname "$0")
readonly SCRIPT_NAME=$(basename "$0")

# Functions
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] ARGS

Options:
    -h, --help     Show this help
    -v, --verbose  Verbose output
EOF
    exit 1
}

main() {
    local verbose=0

    # Parse arguments
    while test $# -gt 0; do
        case "$1" in
            -h|--help) usage ;;
            -v|--verbose) verbose=1 ;;
            *) break ;;
        esac
        shift
    done

    # Main logic
    # ...
}

# Run main if script is executed directly
if test "${BASH_SOURCE[0]}" = "${0}"; then
    main "$@"
fi
```

### Performance Checklist

- [ ] Use builtins instead of external commands
- [ ] Minimize subshells and pipelines
- [ ] Cache expensive computations
- [ ] Use specific glob patterns
- [ ] Enable command hashing
- [ ] Profile before optimizing

### Security Checklist

- [ ] Quote all variable expansions
- [ ] Validate user input
- [ ] Use secure temp files
- [ ] Check permissions
- [ ] Avoid eval with user input
- [ ] Use trap for cleanup

## Next Steps

- [API Reference](./API.md) - Complete API documentation
- [Features Guide](./FEATURES.md) - All features reference
- [Benchmarks](./BENCHMARKS.md) - Performance comparisons
- [Contributing](./CONTRIBUTING.md) - Help improve Den
