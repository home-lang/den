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
  - [ ] Performance tests (`test/performance.test.ts`)
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

### 3. Cross-Platform Support ✅ Partial
- [x] **Windows support** (abstraction layer complete)
  - [x] Windows process API (CreateProcess via std.process.Child)
  - [x] Cross-platform process abstractions (`src/utils/process.zig`)
  - [x] Cross-platform job control (`src/executor/job_control.zig`)
  - [x] Windows environment handling (env.zig with thread-local cache)
  - [x] Windows executable detection (.exe, .com, .bat, .cmd, .ps1)
  - [x] Process groups replaced with job management on Windows
  - [x] Windows signal handling equivalent (TerminateProcess)
- [ ] **Linux support** (partial)
  - [ ] Test on various Linux distributions
  - [ ] Ensure all system modules work (battery, memory detection)

---

## 🟡 Medium Priority - Missing Features

### 4. Configuration System (Phase 3) ✅ Partial
- [x] Integrate `zig-config` library for JSONC parsing
- [x] Config file search logic (current dir → home dir)
- [x] Support `den.jsonc` config file format
- [ ] Support `package.jsonc` config file format
- [ ] Config validation with error messages
- [ ] Config override via CLI flags (`--config <path>`)
- [ ] Config reload mechanism
- [ ] Config hot-reload
- [x] Port default config from TypeScript version
  - [x] Default aliases (~35 aliases in den.jsonc)
  - [ ] Default environment variables
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
  - [ ] Typo correction (fuzzy matching)
  - [x] Suggestion accept (Right arrow, End, Ctrl+E)
  - [x] Partial suggestion accept (Alt+F)
- [x] **Syntax Highlighting** (toggle available)
  - [x] Command highlighting (builtin, alias, external)
  - [x] Keyword highlighting
  - [x] String highlighting
  - [x] Operator highlighting
  - [ ] Error highlighting (invalid syntax)
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
- [ ] `!#` (current command line - needs context)
- [x] Word designators (`:0`, `:1`, `:$`, `:*`, `:^`, `:n-m`)
- [x] `!$` (last argument)
- [x] `!*` (all arguments)
- [ ] Fuzzy search
- [ ] Regex search
- [ ] Search result ranking
- **Implementation**: `src/utils/history_expansion.zig` (856 lines)

### 7. Context-Aware Completion (Phase 11) ✅
- [x] Argument position detection
- [x] Option/flag completion (`ls -<TAB>`, `grep -<TAB>`, `find -<TAB>`, `curl -<TAB>`)
- [ ] Variable name completion
- [x] Environment variable completion (`$<TAB>`)
- [ ] Hostname completion
- [ ] Username completion
- [x] **Command-Specific Completion**
  - [x] Git completion (branches, tags, remotes, files, subcommands)
  - [x] npm/bun/yarn/pnpm completion (scripts, subcommands)
  - [x] Docker completion (containers, images, subcommands)
  - [ ] kubectl completion
  - [ ] Custom completion registration
- [ ] Completion caching with TTL
- [ ] Completion configuration (enable/disable, case sensitivity, max suggestions)
- **Implementation**: `src/utils/context_completion.zig` (893 lines)

### 8. Arithmetic Expansion (Incomplete)
- [ ] Comparison operators (`<`, `>`, `<=`, `>=`, `==`, `!=`)
- [ ] Logical operators (`&&`, `||`, `!`)
- [ ] Bitwise operators (`&`, `|`, `^`, `~`, `<<`, `>>`)
- [ ] Ternary operator (`? :`)
- [ ] Variable references in expressions
- [ ] Integer overflow handling
- [ ] Expression caching

### 9. Expansion Features (Incomplete)
- [ ] **Tilde Expansion**
  - [ ] `~user` (user's home directory)
  - [ ] `~+` (current working directory)
  - [ ] `~-` (previous working directory)
- [ ] **Brace Expansion**
  - [ ] Nested brace expansion
  - [ ] Zero-padding support (`{01..10}`)
- [ ] **Process Substitution**
  - [ ] `<(command)` (create temp file with command output)
  - [ ] `>(command)` (create temp file as command input)
  - [ ] Named pipe creation
  - [ ] Cleanup on command completion
- [ ] **Quote Removal & Word Splitting**
  - [ ] Quote removal (after expansion)
  - [ ] IFS-based word splitting
  - [ ] Empty argument preservation (`""`)
  - [ ] Field splitting with configurable IFS
- [ ] **Expansion Caching**
  - [ ] LRU cache for variable expansions
  - [ ] LRU cache for arithmetic results
  - [ ] LRU cache for command substitutions
  - [ ] LRU cache for glob results

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
- [ ] **Control Flow Enhancements**
  - [ ] C-style for loop (`for ((i=0; i<10; i++))`)
  - [ ] Iterate over array in for loops
  - [ ] Multiple patterns per case statement
  - [ ] Fallthrough with `;&` and `;;&` in case
  - [ ] `select` loops (interactive menu)
- [ ] **Functions**
  - [ ] Function definition (`function name { ... }`, `name() { ... }`)
  - [ ] Function call
  - [ ] Positional parameters in functions (`$1`, `$2`, etc.)
  - [ ] Local variables
  - [ ] Return statement
  - [ ] Function export
  - [ ] Recursive functions
  - [ ] Function overriding
- [ ] **Script Execution**
  - [ ] Script context (variables, functions, scope)
  - [ ] Script caching (parsed AST)
  - [ ] Script timeout
- [ ] **Error Handling**
  - [ ] Error suggestions
  - [ ] Error recovery

### 12. Custom Hooks (Phase 16)
- [ ] `git:push` - Before git push
- [ ] `docker:build` - Before docker build
- [ ] `npm:install` - Before npm install
- [ ] Support user-defined custom hooks
- [ ] Conditional execution (file/env/custom predicates)
- [ ] Script execution from hooks

---

## 🟢 Low Priority - Extended Features

### 13. Extended Builtins (Phase 13)
- [ ] **Navigation Helpers**
  - [ ] `bookmark` - Bookmark management
- [ ] **Developer Tools**
  - [ ] `reload` - Reload configuration
  - [ ] `code` - Open in VS Code
  - [ ] `pstorm` - Open in PhpStorm
  - [ ] `library` - Library management
  - [ ] `show` / `hide` - Show/hide files (macOS)
- [ ] **System Helpers**
  - [ ] `ip` - Display public IP info
  - [ ] `localip` - Show local IP
  - [ ] `reloaddns` - Reload DNS cache
  - [ ] `emptytrash` - Empty trash (macOS)
  - [ ] `copyssh` - Copy SSH key to clipboard
  - [ ] `ft` - Fuzzy file finder
  - [ ] `web` - Open URL in browser
- [ ] **Productivity**
  - [ ] `shrug` - Print shrug emoticon
  - [ ] `wip` - Work-in-progress git helper
  - [ ] `calc` - Calculator with functions
  - [ ] `json` - JSON utilities (parse, format, query)
  - [ ] `http` - HTTP requests
- [ ] **Advanced Tools**
  - [ ] `find` - Fuzzy file finder (interactive)
  - [ ] `tree` - Directory tree
  - [ ] `grep` - Text search with highlighting
  - [ ] `watch` - Execute command repeatedly
- [ ] **Monitoring & Logging**
  - [ ] `log-tail` - Tail logs with filtering
  - [ ] `log-parse` - Parse structured logs
  - [ ] `proc-monitor` - Process monitoring
  - [ ] `sys-stats` - System statistics
  - [ ] `net-check` - Network connectivity check
- [ ] **Dotfiles**
  - [ ] `dotfiles` - Dotfiles management helper

### 14. Documentation (Phase 21)
- [ ] **Code Documentation**
  - [ ] Document all public APIs
  - [ ] Create architecture documentation
  - [ ] Document data structures
  - [ ] Document algorithms (parser, expansion, etc.)
  - [ ] Create contributor guide
- [ ] **User Documentation**
  - [ ] Update README.md for Zig version
  - [ ] Create getting started guide
  - [ ] Create configuration guide
  - [ ] Create builtin command reference
  - [ ] Create scripting guide
  - [ ] Create plugin development guide
  - [ ] Create theme customization guide
  - [ ] Create troubleshooting guide
  - [ ] Create man page
- [ ] **Migration Guide**
  - [ ] Document breaking changes
  - [ ] Create migration script/tool
  - [ ] Document feature parity status
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

- [ ] **cd**: CDPATH support, directory stack integration
- [ ] **pwd**: `-L` (logical path), `-P` (physical path)
- [ ] **pushd/popd**: `+N`/`-N` rotation
- [ ] **dirs**: `-c` (clear), `-l` (long), `-p` (one per line), `-v` (with indices)
- [ ] **echo**: `-e` (escape sequences), `-E` (disable escapes)
- [ ] **printf**: Full format string support (`%s`, `%d`, `%f`, etc.)
- [ ] **env**: `env VAR=value command` (temp env)
- [ ] **export**: `-n` (unexport), `-p` (list exports)
- [ ] **unset**: `-v` (variable), `-f` (function) flags
- [ ] **set**: Full option support (`-e`, `-u`, `-x`, `-o pipefail`, `-o noclobber`)
- [ ] **umask**: `-S` (symbolic), `-p` (portable)
- [ ] **jobs**: `-l` (PIDs), `-p` (PIDs only), `-r` (running), `-s` (stopped)
- [ ] **kill**: `-l` (list signals), `-s signal`
- [ ] **wait**: Wait for specific job, exit code return
- [ ] **disown**: `-h` (keep but no SIGHUP), `-a` (all), `-r` (running)
- [ ] **type**: `-a` (all matches), `-p` (path), `-t` (type only)
- [ ] **which**: `-a` (all matches)
- [ ] **hash**: `-r` (clear), `-d name` (delete), `-l` (list), `-p path name` (add)
- [ ] **time**: `-p` (POSIX format)
- [ ] **trap**: `-l` (list signals), `-p` (show traps), ERR/EXIT/DEBUG/RETURN pseudo-signals
- [ ] **timeout**: `-s signal`, `-k duration`
- [ ] **read**: `-r` (raw), `-p prompt`, `-a array`, `-t timeout`, `-n nchars`, `-d delim`, `-s` (silent)
- [ ] **test**: `[[ ]]` extended test (pattern matching, regex)

### 21. Code Quality
- [ ] Remove any remaining `undefined` behavior
- [ ] Ensure all error paths are handled
- [ ] Add more inline documentation
- [ ] Consistent error messages across builtins
- [ ] Improve error recovery in parser

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
| Cross-Platform | 9/11 ✅ (Windows abstraction complete) | 🔴 Critical |
| Configuration System | 15 (10 ✅) | 🟡 Medium |
| Advanced REPL | 25 (25 ✅) | 🟡 Medium |
| History Expansion | 12 (10 ✅) | 🟡 Medium |
| Completion | 15 (10 ✅) | 🟡 Medium |
| Arithmetic/Expansion | 20 | 🟡 Medium |
| Execution Options | 8/8 ✅ | 🟡 Medium |
| Scripting Engine | 20 | 🟡 Medium |
| Custom Hooks | 6 | 🟡 Medium |
| Extended Builtins | 30 | 🟢 Low |
| Documentation | 20 | 🟢 Low |
| Performance | 25 | 🟢 Low |
| Foundation Libraries | 12 (9 ✅) | 🟢 Low |
| Logging & Debugging | 7/7 ✅ | 🟢 Low |
| Memory Management | 6 | 🟢 Low |
| Builtin Enhancements | 25 | 🔧 Improvement |
| Code Quality | 5 | 🔧 Improvement |
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
- **Arithmetic Expansion**: Basic operators (`+`, `-`, `*`, `/`, `%`, `**`)
- **Brace Expansion**: Sequences `{1..10}`, lists `{foo,bar,baz}`
- **Tilde Expansion**: `~` for home directory
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

*Last updated: November 26, 2025*
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
