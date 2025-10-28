# Den Shell

**A blazing-fast, production-ready POSIX shell written in Zig.**

Den is a modern shell that combines the familiarity of traditional shells with native performance and memory safety. Originally built as "Krusty" with TypeScript and Bun, Den has been completely rewritten in Zig for maximum efficiency.

## Why Den?

- ⚡ **Native Performance**: No runtime overhead, instant startup (~5ms)
- 📦 **Tiny Binary**: ~1.8MB executable with zero dependencies
- 🛡️ **Memory Safe**: Zig's compile-time safety prevents common bugs
- 🎯 **Feature Rich**: 54 builtins, job control, history, completion, tilde expansion
- ✅ **Production Ready**: Thoroughly tested, proper memory management, POSIX-compliant

### Performance Comparison

| Metric | TypeScript/Bun | Zig Den | Improvement |
|--------|----------------|---------|-------------|
| **Binary Size** | ~80MB | ~1.8MB | **44x smaller** |
| **Startup Time** | ~50ms | ~5ms | **10x faster** |
| **Memory Usage** | ~30MB | ~2MB | **15x less** |
| **Lines of Code** | ~28,712 | ~4,102 | **7x smaller** |
| **Build Time** | ~5s | <2s | **2.5x faster** |
| **Dependencies** | Bun runtime | None | **Zero deps** |

## Quick Start

```bash
# Build Den
zig build

# Run Den interactively
./zig-out/bin/den

# Run a shell script
./zig-out/bin/den script.sh

# Run a single command
echo 'echo "Hello from Den!"' | ./zig-out/bin/den
```

## Features

### Core Shell Capabilities

- **Pipelines**: Multi-stage command pipelines (`cmd1 | cmd2 | cmd3`)
- **Redirections**: Full I/O redirection (`>`, `>>`, `<`, `2>`, `2>&1`)
- **Background Jobs**: Job control with `&`, `jobs`, `fg`, `bg`
- **Boolean Operators**: Conditional execution with `&&` and `||`
- **Command Chaining**: Sequential commands with `;`
- **Variable Expansion**: `$VAR`, `${VAR}`, `${VAR:-default}`, special vars (`$?`, `$$`, `$!`, `$_`, `$0-$9`, `$@`, `$*`, `$#`)
- **Command Substitution**: `$(command)` for capturing command output
- **Arithmetic Expansion**: `$((expression))` with `+`, `-`, `*`, `/`, `%`, `**` operators
- **Brace Expansion**: Sequences `{1..10}`, `{a..z}` and lists `{foo,bar,baz}`
- **Tilde Expansion**: `~` for home directory
- **Glob Expansion**: Pattern matching (`*.zig`, `**/*.txt`)
- **Command History**: Persistent history with search
- **Tab Completion**: Smart completion for commands and file paths
- **Aliases**: Command aliases with expansion

### 54 Built-in Commands

**Core** (4): `exit`, `help`, `true`, `false`

**File System** (6): `cd`, `pwd`, `pushd`, `popd`, `dirs`, `realpath`

**Environment** (4): `env`, `export`, `set`, `unset`

**Introspection** (4): `alias`, `unalias`, `type`, `which`

**Job Control** (3): `jobs`, `fg`, `bg`

**History** (2): `history`, `complete`

**Scripting** (6): `source`/`.`, `read`, `test`/`[`, `eval`, `shift`, `command`

**Path Utils** (2): `basename`, `dirname`

**Output** (2): `echo`, `printf`

**System** (4): `time`, `sleep`, `umask`, `hash`

**Info** (3): `clear`, `uname`, `whoami`

**Script Control** (6): `return`, `break`, `continue`, `local`, `declare`, `readonly`

**Job Management** (3): `kill`, `wait`, `disown`

**Advanced Execution** (5): `exec`, `builtin`, `trap`, `getopts`, `times`

Run `help` in Den for detailed information on each command.

## Example Usage

### Interactive Shell

```bash
$ ./zig-out/bin/den
Den shell initialized!
Type 'exit' to quit or Ctrl+D to exit.

den> echo "Hello, World!"
Hello, World!

den> export MY_VAR="test"
den> echo $MY_VAR
test

den> ls -la | grep zig
drwxr-xr-x  15 user  staff   480 Oct 25 12:00 zig-out
-rw-r--r--   1 user  staff  1234 Oct 25 12:00 build.zig
```

### Shell Scripting

```bash
#!/usr/bin/env den

# Variables and expansion
export PROJECT="my-app"
export VERSION="1.0.0"

# Conditional execution
if test -f README.md; then
    echo "README exists"
else
    echo "README not found"
fi

# Loops (via source)
for file in *.zig; do
    basename $file .zig
done

# Functions via scripts
test -d build || mkdir build
pushd build
echo "Building in $(pwd)"
popd
```

### Job Control

```bash
den> sleep 30 &
[1] 12345

den> jobs
[1]+ Running    sleep 30 &

den> fg %1
# (brings sleep to foreground)
^Z
[1]+ Stopped    sleep 30

den> bg %1
[1]+ Running    sleep 30 &
```

## Building from Source

### Requirements

- Zig 0.15.1 or later
- macOS, Linux, or BSD (Windows support planned)

### Build

```bash
# Debug build (default)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Install system-wide
zig build install --prefix ~/.local

# Run tests
zig build test
```

## Development

### Project Structure

```
den/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig           # Entry point
│   ├── shell.zig          # Main shell logic & builtins
│   ├── types/             # Type definitions
│   ├── parser/            # Command parser & tokenizer
│   ├── executor/          # Command execution engine
│   ├── expansion/         # Variable & glob expansion
│   ├── history/           # History management
│   ├── completion/        # Tab completion
│   └── utils/             # Utilities (IO, glob, etc.)
└── test/                  # Test files
```

### Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](.github/CONTRIBUTING.md) for guidelines.

## Roadmap

**✅ Completed** (Production Ready):
- Core shell functionality (parsing, execution, I/O)
- 54 essential builtin commands
- Job control and process management (jobs, fg, bg, kill, wait, disown)
- History and tab completion
- Variable expansion ($VAR, ${VAR:-default}, special vars: $?, $$, $!, $_, $0-$9, $@, $*, $#)
- Command substitution ($(command) and `` `command` ``)
- Arithmetic expansion ($((expr)) with +, -, *, /, %, ** operators)
- Brace expansion ({1..10}, {a..z}, {foo,bar,baz})
- Tilde expansion (~, ~/path)
- Glob expansion (*.txt, **/*.zig)
- Pipelines, redirections, and operators
- Script control builtins (return, break, continue, local, declare, readonly)
- Advanced execution (exec, builtin, trap, getopts, times)
- Script execution with positional parameters
- Error handling (set -e errexit, set -E errtrace, line number reporting)
- Script management (caching, reloading, validation, enhanced error reporting)
- Control flow (if/elif/else/fi, while, until, for loops with break/continue support)

**✨ Enhanced Features**:
- ✅ Configuration file support (JSONC via zig-config)
- ✅ C-style for loops (`for ((i=0; i<10; i++))`)
- ✅ Select menus for interactive selection
- 🔧 Plugin system for extensibility (infrastructure complete)
- 🔧 Theme and prompt customization (configuration complete)
- 🔧 Syntax highlighting and auto-suggestions (plugins exist)
- 📋 Additional productivity builtins (planned)

See [ROADMAP.md](ROADMAP.md) for detailed phase breakdown.

## Documentation

- [Migration Status](ZIG_MIGRATION_STATUS.md) - Detailed implementation progress
- [Session Summary](FINAL_SESSION_SUMMARY.md) - Development session notes
- [Roadmap](ROADMAP.md) - Full feature roadmap

## License

MIT License - see [LICENSE](LICENSE.md) for details.

Made with 💙 by the Stacks team.

## Community

- [GitHub Discussions](https://github.com/stacksjs/den/discussions)
- [Discord Server](https://discord.gg/stacksjs)

---

**Note**: Den is the Zig rewrite of the original Krusty shell (TypeScript/Bun). The TypeScript version remains available in the repository for reference but is no longer actively developed.
