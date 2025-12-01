# Den Shell - TODO

> Comprehensive analysis of features to implement, fix, and improve.
> Based on thorough codebase review and ROADMAP.md status.

---

## 🔴 Critical / High Priority

### 1. Testing Infrastructure ✅
- [x] **Port remaining unit tests** from TypeScript version
  - [x] Expansion tests (447+ existing test blocks)
  - [x] Redirection tests (existing in codebase)
  - [x] Command execution tests (existing in codebase)
  - [x] Builtin tests (`tests/test_builtins.zig`) - 30+ tests
  - [x] Completion tests (`tests/test_completion.zig`) - 15+ tests
  - [x] History tests (`tests/test_history.zig`) - 10+ tests
  - [x] Alias tests (`tests/test_alias.zig`) - 15+ tests
  - [x] Job control tests (`tests/test_job_control.zig`) - 15+ tests
  - [x] Test utilities (`tests/test_utils.zig`) - ShellFixture, TempDir, etc.
- [x] **Integration tests**
  - [x] Pipeline tests (`tests/test_pipeline.zig`) - 30 tests
  - [x] Chaining tests (`tests/test_chaining.zig`) - 35 tests
  - [x] Scripting tests (`tests/test_scripting.zig`) - 42 tests
- [x] **E2E tests**
  - [x] CLI tests (`tests/test_e2e.zig`) - 50 tests
  - [x] REPL tests (`tests/test_repl.zig`) - 35 tests
  - [x] Shell integration tests (`tests/test_shell_integration.zig`) - 46 tests
  - [x] Performance tests (`tests/test_performance.zig`) - 11 benchmarks
- [x] **Regression tests** ✅
  - [x] Parser regression tests (`tests/test_parser_regression.zig`) - 60+ tests
  - [x] Operator tests (`tests/test_operators.zig`) - 44 tests
  - [x] Pipefail tests (`tests/test_shell_options.zig`) - included
  - [x] Xtrace tests (`tests/test_shell_options.zig`) - included
  - [x] Nounset tests (`tests/test_shell_options.zig`) - included
- [x] **Fuzzing** ✅
  - [x] Parser fuzzing (`src/parser/test_fuzz.zig`, `test_fuzz_simple.zig`)
  - [x] Completion fuzzing (`tests/test_fuzzing.zig`)
  - [x] Expansion fuzzing (`tests/test_fuzzing.zig`)
  - [x] Input handling fuzzing (`tests/test_fuzzing.zig`)

### 2. Signal Handling ✅
- [x] Handle SIGTERM gracefully (clean shutdown)
- [x] Handle SIGWINCH properly (terminal resize redraw)
- [x] Clean up resources on abnormal exit
- [x] Signal-safe I/O operations

### 3. Cross-Platform Support ✅
- [x] **Windows support** (abstraction layer complete)
  - [x] Windows process API (CreateProcess via std.process.Child)
  - [x] Cross-platform process abstractions (`src/utils/process.zig`)
  - [x] Cross-platform job control (`src/executor/job_control.zig`)
  - [x] Windows environment handling (env.zig with thread-local cache)
  - [x] Windows executable detection (.exe, .com, .bat, .cmd, .ps1)
  - [x] Process groups replaced with job management on Windows
  - [x] Windows signal handling equivalent (TerminateProcess)
- [x] **Linux support** (verified via cross-compilation)
  - [x] Cross-compiles for x86_64-linux (musl), x86_64-linux-gnu (glibc), aarch64-linux
  - [x] System modules work (battery via /sys/class/power_supply/, memory via /proc/meminfo)

---

## 🟡 Medium Priority - Missing Features

### 4. Configuration System (Phase 3) ✅ Complete
- [x] Integrate `zig-config` library for JSONC parsing
- [x] Config file search logic (current dir → home dir)
- [x] Support `den.jsonc` config file format
- [x] Support `package.jsonc` config file format ✅ (extracts "den" key)
- [x] Config validation with error messages ✅ (validateConfig, ConfigError, ValidationResult)
- [x] Config override via CLI flags (`--config <path>`)
- [x] Config reload mechanism ✅ (`reload` builtin with -v, --aliases, --config options)
- [x] Config hot-reload ✅ (set `hot_reload: true` in config, checks mtime on each prompt)
- [x] Port default config from TypeScript version
  - [x] Default aliases (~35 aliases in den.jsonc)
  - [x] Default environment variables
  - [x] Default prompt format
  - [x] Default theme
  - [x] Default history settings
  - [x] Default completion settings

### 5. Advanced REPL Features (Phase 9) ✅ Mostly Complete
- [x] **Cursor Movement** (in `src/utils/terminal.zig`)
  - [x] Left/right arrow keys
  - [x] Ctrl+A (home), Ctrl+E (end)
  - [x] Ctrl+B (backward char), Ctrl+F (forward char)
  - [x] Alt+B (backward word), Alt+F (forward word)
- [x] **Auto-suggestions**
  - [x] Inline suggestion rendering
  - [x] Suggestion from history
  - [x] Suggestion from completions
  - [x] Typo correction (fuzzy matching)
  - [x] Suggestion accept (Right arrow, End, Ctrl+E)
  - [x] Partial suggestion accept (Alt+F)
- [x] **Syntax Highlighting** (toggle available)
  - [x] Command highlighting (builtin, alias, external)
  - [x] Keyword highlighting
  - [x] String highlighting
  - [x] Operator highlighting
  - [x] Error highlighting (invalid syntax)
  - [x] Path highlighting
  - [x] Variable highlighting
- [x] **History Navigation**
  - [x] Up/down arrow keys for history
  - [x] History browsing state
  - [x] Temporary line preservation
- [x] **Reverse Search**
  - [x] Ctrl+R reverse search trigger
  - [x] Incremental search display
  - [x] Search result highlighting
  - [x] Search result cycling (Ctrl+R repeatedly)
- [x] **Multi-line Input** ✅
  - [x] Line continuation detection (`\` at EOL)
  - [x] Unclosed quote detection
  - [x] Multi-line prompt (PS2)
  - [x] Multi-line editing
  - [x] Unclosed parentheses/brackets/braces detection
  - **Implementation**: `src/utils/terminal.zig` (isIncomplete function, multiline_buffer)

### 6. History Expansion (Phase 10) ✅
- [x] `!!` (last command)
- [x] `!N` (command N)
- [x] `!-N` (Nth previous command)
- [x] `!string` (last command starting with string)
- [x] `!?string` (last command containing string)
- [x] `^old^new` (replace in last command)
- [x] `!#` (current command line)
- [x] Word designators (`:0`, `:1`, `:$`, `:*`, `:^`, `:n-m`)
- [x] `!$` (last argument)
- [x] `!*` (all arguments)
- [x] Fuzzy search (`searchHistoryFuzzy` - case-insensitive pattern matching)
- [x] Regex search (`searchHistoryRegex` - `.`, `*`, `^`, `$` patterns)
- [x] Search result ranking
- **Implementation**: `src/utils/history_expansion.zig` (900+ lines)

### 7. Context-Aware Completion (Phase 11) ✅
- [x] Argument position detection
- [x] Option/flag completion (`ls -<TAB>`, `grep -<TAB>`, `find -<TAB>`, `curl -<TAB>`)
- [x] Variable name completion (from shell environment)
- [x] Environment variable completion (`$<TAB>`)
- [x] Hostname completion (from ~/.ssh/known_hosts and ~/.ssh/config)
- [x] Username completion
- [x] **Command-Specific Completion**
  - [x] Git completion (branches, tags, remotes, files, subcommands)
  - [x] npm/bun/yarn/pnpm completion (scripts, subcommands)
  - [x] Docker completion (containers, images, subcommands)
  - [x] kubectl completion (subcommands, resources, namespaces)
  - [x] Custom completion registration ✅ (complete builtin with -f,-d,-c,-a,-b,-e,-u,-W,-S,-P flags)
- [x] Completion caching with TTL ✅
- [x] Completion configuration (enable/disable, case sensitivity, max suggestions) ✅
- **Implementation**: `src/utils/context_completion.zig` (1000+ lines)

### 8. Arithmetic Expansion ✅ Complete
- [x] Basic operators (`+`, `-`, `*`, `/`, `%`, `**`)
- [x] Comparison operators (`<`, `>`, `<=`, `>=`, `==`, `!=`)
- [x] Logical operators (`&&`, `||`, `!`)
- [x] Bitwise operators (`&`, `|`, `^`, `~`, `<<`, `>>`)
- [x] Ternary operator (`? :`)
- [x] Variable references in expressions
- [x] Hex (0x...), octal (0...) and binary (0b...) number literals
- [x] Integer overflow handling
- [x] Expression caching
- **Implementation**: `src/utils/arithmetic.zig` (530+ lines, 11 tests)

### 9. Expansion Features (Partial)
- [x] **Tilde Expansion** ✅
  - [x] `~` (current user's home directory)
  - [x] `~user` (user's home directory via passwd lookup)
  - [x] `~+` (current working directory - PWD)
  - [x] `~-` (previous working directory - OLDPWD)
  - **Implementation**: `src/utils/expansion.zig` (`expandTilde` function, `getUserHomeDir`)
- [ ] **Brace Expansion**
  - [x] Nested brace expansion
  - [x] Zero-padding support (`{01..10}`)
- [x] **Process Substitution** ✅
  - [x] `<(command)` (create pipe with command output) ✅
  - [x] `>(command)` (create pipe as command input) ✅
  - [x] Pipe-based implementation using /dev/fd/N ✅
  - [x] Cleanup handled by OS on process exit ✅
- [x] **Quote Removal & Word Splitting** ✅
  - [x] Quote removal (removeQuotes function)
  - [x] IFS-based word splitting (WordSplitter struct with default/custom IFS)
  - [x] Empty argument preservation (`""`)
  - [x] Field splitting with configurable IFS (splitFieldsIfs function)
- [x] **Expansion Caching** ✅
  - [x] LRU cache for variable expansions ✅
  - [x] LRU cache for arithmetic results ✅
  - [x] LRU cache for command substitutions ✅ (cmd_cache in Expansion struct)
  - [x] LRU cache for glob results ✅

### 10. Execution Options ✅
- [x] `set -x` (xtrace - print commands before execution)
- [x] `set -u` (nounset - error on unset variable)
- [x] `set -o pipefail` (pipeline failure detection)
- [x] `set -n` (noexec - parse only, don't execute)
- [x] `set -v` (verbose - print input lines)
- [x] `set -e` (errexit - exit on error) - already implemented
- [x] `set -E` (errtrace - inherit ERR trap) - already implemented
- [x] `set -o` (list all options)
- **Implementation**: `src/shell.zig` (option fields), `src/executor/mod.zig` (builtinSet, executeCommand, pipelines)

### 11. Scripting Engine (Phase 14 - Partial)
- [x] **Control Flow Enhancements** ✅
  - [x] C-style for loop (`for ((i=0; i<10; i++))`) ✅
  - [ ] Iterate over array in for loops
  - [ ] Multiple patterns per case statement
  - [ ] Fallthrough with `;&` and `;;&` in case
  - [x] `select` loops (interactive menu) ✅
- [x] **Functions** ✅ (Partial)
  - [x] Function definition (`function name { ... }`, `name() { ... }`)
  - [x] Function call
  - [x] Positional parameters in functions (`$1`, `$2`, etc.)
  - [x] Local variables (`local` builtin)
  - [x] Return statement (`return` builtin)
  - [ ] Function export
  - [ ] Recursive functions (untested)
  - [ ] Function overriding
  - **Note**: Functions work in both scripts and REPL (single-line and multi-line)
- [x] **Script Execution**
  - [x] Script context (variables, functions, scope)
  - [x] Script caching ✅ (content caching with mtime validation in ScriptManager)
  - [ ] Script timeout
- [ ] **Error Handling**
  - [ ] Error suggestions
  - [ ] Error recovery

### 12. Custom Hooks (Phase 16) ✅
- [x] `git:push` - Before git push ✅
- [x] `docker:build` - Before docker build ✅
- [x] `npm:install` - Before npm install ✅
- [x] Support user-defined custom hooks ✅ (`hook` builtin)
- [x] Conditional execution (file/env/custom predicates) ✅
- [x] Script execution from hooks ✅

---

## 🟢 Low Priority - Extended Features

### 13. Extended Builtins (Phase 13)
- [x] **Navigation Helpers**
  - [x] `bookmark` - Bookmark management ✅
- [x] **Developer Tools**
  - [x] `reload` - Reload configuration
  - [x] `code` - Open in VS Code ✅
  - [x] `pstorm` - Open in PhpStorm ✅
  - [x] `library` - Library management ✅
  - [x] `show` / `hide` - Show/hide files (macOS) ✅
- [x] **System Helpers**
  - [x] `ip` - Display public IP info ✅
  - [x] `localip` - Show local IP ✅
  - [x] `reloaddns` - Reload DNS cache (macOS) ✅
  - [x] `emptytrash` - Empty trash (macOS) ✅
  - [x] `copyssh` - Copy SSH key to clipboard ✅
  - [x] `ft` - Fuzzy file finder ✅
  - [x] `web` - Open URL in browser ✅
- [x] **Productivity**
  - [x] `shrug` - Print shrug emoticon ✅
  - [x] `wip` - Work-in-progress git helper ✅
  - [x] `calc` - Calculator with functions ✅
  - [x] `json` - JSON utilities (parse, format, query) ✅
  - [x] `http` - HTTP requests ✅
- [ ] **Advanced Tools**
  - [ ] `find` - Fuzzy file finder (interactive)
  - [x] `tree` - Directory tree ✅
  - [x] `grep` - Text search with highlighting ✅
  - [x] `watch` - Execute command repeatedly ✅
- [ ] **Monitoring & Logging**
  - [x] `log-tail` - Tail logs with filtering ✅
  - [x] `log-parse` - Parse structured logs ✅
  - [x] `proc-monitor` - Process monitoring ✅
  - [x] `sys-stats` - System statistics ✅
  - [x] `netstats` - Network statistics ✅
  - [x] `net-check` - Network connectivity check ✅
- [x] **Dotfiles**
  - [x] `dotfiles` - Dotfiles management helper ✅

### 14. Documentation (Phase 21) ✅ Mostly Complete
- [x] **Code Documentation**
  - [x] Document all public APIs ✅ (docs/API.md)
  - [x] Create architecture documentation ✅ (docs/ARCHITECTURE.md - updated with config system)
  - [x] Document data structures ✅ (docs/DATA_STRUCTURES.md)
  - [x] Document algorithms (parser, expansion, etc.) ✅ (docs/ALGORITHMS.md)
  - [x] Create contributor guide ✅ (docs/CONTRIBUTING.md)
- [x] **User Documentation**
  - [x] Update README.md for Zig version ✅
  - [x] Create getting started guide ✅ (docs/intro.md, docs/install.md)
  - [x] Create configuration guide ✅ (docs/config.md)
  - [x] Create builtin command reference ✅ (docs/BUILTINS.md - fully updated)
  - [x] Create scripting guide ✅ (docs/SCRIPTING.md)
  - [x] Create plugin development guide ✅ (docs/PLUGIN_DEVELOPMENT.md)
  - [x] Create theme customization guide ✅ (docs/THEMES.md - already exists)
  - [x] Create troubleshooting guide ✅ (docs/TROUBLESHOOTING.md)
  - [x] Create man page ✅ (docs/den.1)
- [x] **Migration Guide** ✅ (docs/MIGRATION.md)
  - [x] Document breaking changes ✅
  - [x] Create migration script/tool ✅
  - [x] Document feature parity status ✅
- [ ] **Website/Docs Site**
  - [ ] Port VitePress docs to static site
  - [ ] Create online playground/demo
  - [ ] Create feature showcase
  - [ ] Create comparison table (vs Bash, Zsh, Fish)

### 15. Performance & Optimization (Phase 22)
- [ ] **Memory Optimization**
  - [ ] Minimize allocations in hot paths
  - [ ] Use stack allocation where possible
  - [ ] Pool frequently allocated objects
  - [ ] Tune arena allocator sizes
  - [ ] Fix memory leaks
  - [ ] Reduce memory fragmentation
- [ ] **CPU Optimization**
  - [ ] Optimize parser (reduce passes)
  - [ ] Optimize expansion engine (reduce copying)
  - [ ] Optimize completion matching (better algorithms)
  - [ ] Optimize history search (indexing)
  - [ ] Use SIMD where applicable
  - [ ] Cache expensive operations
- [ ] **I/O Optimization**
  - [ ] Minimize system calls
  - [ ] Batch I/O operations
  - [ ] Use async I/O for long operations
  - [ ] Optimize file reading/writing
  - [ ] Reduce terminal escape sequences
- [ ] **Concurrency**
  - [ ] Parallelize module detection
  - [ ] Use thread pool for async operations
  - [ ] Minimize lock contention
- [ ] **Benchmarking**
  - [ ] Create comprehensive benchmark suite
  - [ ] Benchmark against Bash
  - [ ] Benchmark against Zsh
  - [ ] Benchmark against Fish
  - [ ] Track performance over time
  - [ ] Set performance targets

### 16. Foundation Libraries (Phase 4 - Partial) ✅
- [ ] **ANSI/Terminal**
  - [ ] Handle Windows console API differences
- [x] **Terminal I/O**
  - [x] Non-blocking I/O (in terminal.zig)
  - [x] Signal-safe I/O (in io.zig)
- [ ] **File System**
  - [ ] Path normalization
  - [ ] Recursive directory walking
  - [x] Cross-platform path handling (glob.zig path separators)
- [x] **Process Management** (`src/utils/process.zig`)
  - [x] ProcessId/FileHandle type abstractions
  - [x] Cross-platform pipe creation
  - [x] Cross-platform process waiting
  - [x] Cross-platform process termination
  - [x] Process group management (POSIX) / stubs (Windows)
  - [x] Handle Windows CreateProcess API (via std.process.Child)
- [x] **Environment** (`src/utils/env.zig`)
  - [x] PATH parsing with PathList
  - [x] Cross-platform executable search
  - [x] Platform detection (Linux, macOS, Windows, BSD, etc.)
  - [x] Architecture detection (x86_64, aarch64, arm, etc.)
  - [x] Windows environment cache (thread-local)

### 17. Logging & Debugging (Phase 1) ✅
- [x] Implement logging infrastructure (debug, info, warn, error levels)
- [x] Add structured logging support
- [x] Create debug output utilities
- [x] Implement error formatting
- [x] Add stack trace utilities
- [x] Create assertion macros
- [x] Add timing/profiling utilities

### 18. Memory Management (Phase 1)
- [ ] Design allocator strategy (GPA, Arena, Pool allocators)
- [ ] Implement memory pools for common objects
- [ ] Create arena allocator for request-scoped allocations
- [ ] Add memory leak detection for debug builds
- [ ] Implement reference counting where needed
- [ ] Create object pooling for frequently allocated structures

### 19. AST Construction (Phase 5)
- [ ] Design abstract syntax tree structure
- [ ] Implement AST node types (Command, Pipeline, Chain, etc.)
- [ ] Implement AST builder from tokens
- [ ] Implement AST pretty-printing (for debugging)
- [ ] Implement AST optimization

---

## 🔧 Improvements & Fixes

### 20. Builtin Command Enhancements
Many builtins are implemented but missing flags/options:

- [x] **cd**: CDPATH support, `cd -` (OLDPWD), OLDPWD tracking ✅
- [x] **pwd**: `-L` (logical path), `-P` (physical path) ✅
- [x] **pushd/popd**: `+N`/`-N` rotation ✅
- [x] **dirs**: `-c` (clear), `-l` (long), `-p` (one per line), `-v` (with indices) ✅
- [x] **echo**: `-e` (escape sequences), `-E` (disable escapes) ✅
- [x] **printf**: Full format string support (`%s`, `%d`, `%f`, etc.) ✅
- [x] **env**: `env VAR=value command` (temp env), `-i` (ignore env), `-u` (unset) ✅
- [x] **export**: `-n` (unexport), `-p` (list exports) ✅
- [x] **unset**: `-v` (variable), `-f` (function) flags ✅
- [x] **set**: Full option support (`-e`, `-E`, `-u`, `-x`, `-n`, `-v`, `-f`, `-C`, `-o pipefail`, `-o noclobber`, `-o noglob`) ✅
- [x] **umask**: `-S` (symbolic), `-p` (portable), symbolic mode input ✅
- [x] **jobs**: `-l` (PIDs), `-p` (PIDs only), `-r` (running), `-s` (stopped) ✅
- [x] **kill**: `-l` (list signals), `-s signal` ✅
- [x] **wait**: Wait for specific job by %jobid or PID, exit code return ✅
- [x] **disown**: `-h` (keep but no SIGHUP), `-a` (all), `-r` (running) ✅
- [x] **type**: `-a` (all matches), `-p` (path), `-t` (type only) ✅
- [x] **which**: `-a` (all matches) ✅
- [x] **hash**: `-r` (clear), `-d name` (delete), `-l` (list), `-p path name` (add), `-t` (print path) ✅
- [x] **time**: `-p` (POSIX format) ✅
- [x] **trap**: `-l` (list signals), `-p` (show traps) ✅
- [x] **timeout**: `-s signal`, `-k duration`, `--preserve-status`, `--foreground` ✅
- [x] **read**: `-r` (raw), `-p prompt`, `-a` (array), `-n` (nchars), `-d` (delimiter), `-s` (silent), `-t` (timeout) ✅
- [x] **test**: `[[ ]]` extended test (pattern matching, regex) ✅

### 21. Code Quality ✅
- [x] Remove any remaining `undefined` behavior
- [x] Ensure all error paths are handled
- [x] Add more inline documentation
- [x] Consistent error messages across builtins (all use `den: command: message` format)
- [x] Improve error recovery in parser (user-friendly error messages)

### 22. CI/CD Improvements
- [ ] Set up cross-platform testing (Linux, macOS)
- [ ] Add coverage reporting
- [ ] Performance regression detection
- [ ] Automated release workflow improvements
- [ ] Binary signing for releases

---

## 📊 Summary

| Category | Total Items | Priority |
|----------|-------------|----------|
| Testing Infrastructure | ~40 ✅ (unit ✅, integration ✅, e2e ✅, regression ✅, fuzzing ✅) | 🔴 Critical |
| Signal Handling | 4/4 ✅ | 🔴 Critical |
| Cross-Platform | 11/11 ✅ (Windows + Linux complete) | 🔴 Critical |
| Configuration System | 15 (10 ✅) | 🟡 Medium |
| Advanced REPL | 25 (25 ✅) | 🟡 Medium |
| History Expansion | 13 (12 ✅) | 🟡 Medium |
| Completion | 15 (12 ✅) | 🟡 Medium |
| Arithmetic Expansion | 9 (7 ✅) | 🟡 Medium |
| Expansion Features | 15 (5 ✅ - tilde done) | 🟡 Medium |
| Execution Options | 8/8 ✅ | 🟡 Medium |
| Scripting Engine | 20 | 🟡 Medium |
| Custom Hooks | 6 | 🟡 Medium |
| Extended Builtins | 30 (14 ✅) | 🟢 Low |
| Documentation | 20 | 🟢 Low |
| Performance | 25 | 🟢 Low |
| Foundation Libraries | 12 (9 ✅) | 🟢 Low |
| Logging & Debugging | 7/7 ✅ | 🟢 Low |
| Memory Management | 6 | 🟢 Low |
| Builtin Enhancements | 25 (22 ✅) | 🔧 Improvement |
| Code Quality | 5/5 ✅ | 🔧 Improvement |
| CI/CD | 5 | 🔧 Improvement |

**Total: ~300+ items**

---

## ✅ What's Already Working Well

The following features are production-ready:

- **Core Shell**: Parsing, tokenization, command execution
- **Pipelines**: Multi-stage pipelines with proper error handling
- **Redirections**: Full I/O redirection (`>`, `>>`, `<`, `2>`, `2>&1`, `&>`, heredoc, herestring)
- **Job Control**: Background jobs, fg, bg, jobs, kill, wait, disown
- **Variable Expansion**: `$VAR`, `${VAR}`, `${VAR:-default}`, special vars (`$?`, `$$`, `$!`, `$_`, `$0-$9`, `$@`, `$*`, `$#`)
- **Command Substitution**: `$(command)` and backticks
- **Arithmetic Expansion**: Full operators (`+`, `-`, `*`, `/`, `%`, `**`, comparisons, logical, bitwise, ternary)
- **Brace Expansion**: Sequences `{1..10}`, lists `{foo,bar,baz}`
- **Tilde Expansion**: `~`, `~user`, `~+`, `~-` for directories
- **Glob Expansion**: `*`, `?`, `[abc]`, `**`
- **History**: Persistent history with search
- **Tab Completion**: Commands, files, paths
- **54 Builtins**: Core shell functionality
- **Control Flow**: if/elif/else, while, for, case, until
- **Plugin System**: Complete with API, hooks, discovery
- **Theme System**: Colors, terminal detection, prompt rendering
- **Module System**: Language/cloud/system detection
- **Prompt**: Git integration, async fetching, customizable

---

*Last updated: November 27, 2025*
*Based on codebase analysis and ROADMAP.md review*

**Recent completions:**
- Cross-Platform Support:
  - `src/utils/process.zig` - ProcessId, FileHandle, Pipe abstractions for Windows/POSIX
  - `src/executor/job_control.zig` - Cross-platform job management
  - Windows executable detection (.exe, .com, .bat, .cmd, .ps1)
  - Integrated process abstractions into executor builtins (fg, bg, wait, kill)
  - Fixed zig-config use-after-free bug causing config loading segfault
  - Added `-c "command"` CLI flag support
- Signal Handling (SIGTERM, SIGWINCH, clean exit, signal-safe I/O)
- Logging & Debugging infrastructure
- Zig 0.16 API compatibility fixes
- Testing Infrastructure - Unit Tests:
  - test_builtins.zig (cd, pwd, echo, export, type, which, true/false, test)
  - test_completion.zig (file completion, filtering, sorting, special chars)
  - test_history.zig (recording, clearing, limits, duplicates)
  - test_alias.zig (create, overwrite, unalias, chained aliases)
  - test_job_control.zig (background jobs, wait, kill, disown)
  - test_utils.zig (ShellFixture, TempDir, TestAssert helpers)
- Testing Infrastructure - Integration Tests:
  - test_pipeline.zig (30 tests - pipe operations, multi-stage, error handling)
  - test_chaining.zig (35 tests - &&, ||, ; operators, grouping)
  - test_scripting.zig (42 tests - if/else, for, while, until, case, functions)
- Configuration System:
  - JSONC parsing with comment removal and trailing comma handling
  - Config file search: ./den.jsonc → config/ → .config/ → ~/.config/
  - Config-driven aliases (35 default aliases in den.jsonc)
  - Shell loads aliases from config on startup
- Advanced REPL (already implemented in src/utils/terminal.zig):
  - Full cursor movement (arrows, Ctrl+A/E/B/F, Alt+B/F)
  - History navigation with substring matching
  - Reverse search (Ctrl+R) with cycling
  - Tab completion with arrow key navigation
  - Inline suggestions with Right arrow acceptance
  - 50-state undo stack
- E2E Tests (131 total tests):
  - test_e2e.zig (50 tests) - Variable expansion, command substitution, arithmetic, redirections, globs, subshells, functions, process control, string operations, edge cases
  - test_repl.zig (35 tests) - Multi-line scripts, variable state, history, input handling, prompts, line continuation, job control, traps, shell options, source command, special variables
  - test_shell_integration.zig (46 tests) - Environment integration, signal handling, process groups, file descriptors, working directory, exit codes, script mode, quoting, chaining, glob/expansion, builtins, error handling, IPC
- Regression Tests & Fuzzing Infrastructure:
  - test_parser_regression.zig (60+ tests) - Edge cases, quoting, operators, redirections, command substitution, unicode, security
  - test_operators.zig (44 tests) - &&, ||, |, ;, &, redirections, grouping, negation
  - test_shell_options.zig (25+ tests) - set -e, -u, -x, -o pipefail, -n, -v, -f, -C
  - test_fuzzing.zig (30+ tests) - Variable expansion, glob, brace expansion, pipelines, grouping, unicode
  - src/parser/test_fuzz.zig - Parser fuzzing with random inputs
  - src/parser/test_fuzz_simple.zig - Simple tokenizer fuzzing
- History Expansion (fully implemented):
  - src/utils/history_expansion.zig (856 lines)
  - `!!`, `!N`, `!-N`, `!string`, `!?string?`, `^old^new`
  - `!$`, `!*`, word designators (`:0`, `:1`, `:$`, `:*`, `:^`, `:n-m`)
  - Integrated in shell.zig
- Context-Aware Completion (fully implemented):
  - src/utils/context_completion.zig (893 lines)
  - Git completion (branches, tags, remotes, files, subcommands)
  - npm/bun/yarn/pnpm completion (scripts, subcommands)
  - Docker completion (containers, images, subcommands)
  - Environment variable completion ($TAB)
  - Option/flag completion (ls, grep, find, curl)
- Multi-line Input (fully implemented):
  - src/utils/terminal.zig (isIncomplete function, multiline_buffer)
  - Line continuation detection (`\` at EOL)
  - Unclosed quote detection (single and double)
  - Unclosed brackets/parentheses/braces detection
  - PS2 prompt for continuation lines
  - Ctrl+C cancels multi-line input
  - 20+ unit tests for isIncomplete function
- Execution Options (fully implemented):
  - src/shell.zig (option fields: errexit, errtrace, xtrace, nounset, pipefail, noexec, verbose)
  - src/executor/mod.zig (builtinSet handles all options)
  - `set -x` prints commands before execution with `+ ` prefix
  - `set -u` errors on unset variable in expansion
  - `set -o pipefail` returns rightmost non-zero exit in pipeline
  - `set -n` parses but doesn't execute (syntax check mode)
  - `set -v` verbose mode
  - `set -e/-E` were already implemented
  - `set -o` lists all option settings
- Config System Enhancements:
  - `--config <path>` and `--config=path` CLI flag support
  - `loadConfigWithPath` for custom config file loading
  - JSONC comment stripping (// and /* */) and trailing comma handling
  - `initWithConfig` shell initialization with custom config path
- History Expansion Enhancements:
  - `!#` current command line support (`expandWithCurrentLine`)
  - `searchHistoryFuzzy` - case-insensitive fuzzy pattern matching (e.g., "gco" matches "git checkout")
  - `searchHistoryRegex` - simple regex search with `.`, `*`, `^`, `$` patterns
- Context-Aware Completion Enhancements:
  - kubectl completion: subcommands, resources (pods, deployments, services, etc.), namespaces (live from cluster)
  - Variable name completion from shell environment
  - Hostname completion from ~/.ssh/known_hosts and ~/.ssh/config
  - Enhanced context detection for ssh, scp, rsync commands
- Performance Tests:
  - tests/test_performance.zig (11 benchmarks)
  - Tokenizer benchmarks (simple, pipeline, complex commands)
  - Variable expansion benchmarks
  - History search benchmarks (20 and 1000 entries)
  - Completion matching benchmarks
  - Arena allocator throughput
  - String splitting benchmarks
  - Glob pattern matching benchmarks
- Linux Support Verification:
  - Cross-compilation verified for x86_64-linux, x86_64-linux-gnu, aarch64-linux
  - System modules (battery, memory) properly conditionally compiled
  - Build step added: `zig build test-performance`
- Arithmetic Expansion (fully implemented):
  - src/utils/arithmetic.zig (530+ lines, 11 tests)
  - All operators: `+`, `-`, `*`, `/`, `%`, `**`, comparisons, logical, bitwise, ternary
  - Variable references in expressions
  - Hex (0x), octal (0), and binary (0b) number literals
- Tilde Expansion Enhancements:
  - `~user` - user's home directory via POSIX getpwnam()
  - `~+` - current working directory (PWD)
  - `~-` - previous working directory (OLDPWD)
  - 4 new unit tests for tilde expansion
- Extended Builtins (8 complete):
  - `shrug` - Print shrug emoticon (¯\_(ツ)_/¯)
  - `localip` - Show local IP address hints
  - `ip` - Display public IP info hints
  - `web <url>` - Open URL in browser (platform hints)
  - `tree` - Directory tree (already implemented)
  - `calc` - Calculator with functions (already implemented)
  - `json` - JSON utilities (already implemented)
  - `reload` - Reload shell configuration
- REPL Enhancements:
  - Typo correction with Damerau-Levenshtein distance for "Did you mean..." suggestions
  - Handles transpositions as single edit (e.g., "gti" → "git")
  - Searches PATH and shell builtins for suggestions
- History Expansion Enhancements:
  - Ranked search results with scoring by match type (exact > prefix > substring > fuzzy)
  - `RankedSearchResult` struct with command, score, and match type
  - `searchHistoryRanked()` function for ranked history search
- Completion Enhancements:
  - Username completion from /etc/passwd (`~user<TAB>`)
  - `completeUsername()` and `expandUsername()` functions
- Arithmetic Enhancements:
  - Integer overflow handling with `@addWithOverflow`, `@subWithOverflow`, `@mulWithOverflow`
  - Returns `IntegerOverflow` error instead of undefined behavior
- Brace Expansion Enhancements:
  - Zero-padding support for numeric sequences (`{01..10}` → 01, 02, ..., 10)
  - Detects leading zeros and preserves width in output
  - `formatZeroPadded()` helper for zero-padded number formatting
- Extended Builtins (4 new):
  - `code` - Open file/directory in VS Code (macOS)
  - `pstorm` - Open file/directory in PhpStorm (macOS)
  - `show <file>...` - Remove hidden attribute from files (macOS)
  - `hide <file>...` - Add hidden attribute to files (macOS)
- Completion Caching:
  - `CompletionCache` struct with TTL support in `src/utils/completion.zig`
  - LRU eviction when max entries exceeded
  - Cache key includes command prefix for command completion
- Expansion Caching:
  - `GlobCache` LRU cache in `src/utils/glob.zig`
  - `ExpansionCache` LRU cache in `src/utils/expansion.zig`
  - Config limits in `ExpansionConfig.CacheLimits` (glob: 256, variable: 256)
- Builtin Command Enhancements (December 2025):
  - `disown`: Added `-h` (keep but no SIGHUP), `-a` (all jobs), `-r` (running only) flags
  - `hash`: Added `-l` (list reusable), `-d name` (delete), `-p path name` (add specific), `-t name` (print path) flags
  - `set`: Full option support with `-o optionname` syntax for pipefail, noclobber, noglob
  - Added `option_noglob` and `option_noclobber` shell options
  - `umask`: Added `-S` (symbolic output), `-p` (portable output), symbolic mode input (u=rwx,g=rx,o=rx)
  - `time`: Added `-p` (POSIX format output)
  - `wait`: Now returns proper exit code of waited job
  - `read`: Added `-a` (array), `-n` (nchars), `-d` (delimiter), `-s` (silent), `-t` (timeout) flags
  - `trap`: Already had `-l` and `-p` flags implemented
  - `env`: Already had `VAR=value command`, `-i`, `-u` implemented
  - `export`: Already had `-n` and `-p` flags implemented
  - `jobs`, `kill`, `type`, `which`, `unset` flags already implemented
