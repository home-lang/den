# Den Shell Roadmap

This document outlines the development roadmap for Den, a modern shell written in Zig.

## Current Status: v0.1.x (Active Development)

Den is currently in active development with core shell functionality complete and production-ready features being refined.

## Phase 1: Core Shell (Complete)

- [x] Command parsing and execution
- [x] Pipeline support (`|`, `||`, `&&`)
- [x] Background jobs (`&`)
- [x] Redirection (`>`, `>>`, `<`, `2>`, `&>`)
- [x] Environment variables
- [x] History with persistence
- [x] Tab completion
- [x] Line editing (emacs/vi modes)
- [x] Globbing and brace expansion
- [x] Alias support

## Phase 2: POSIX Compatibility (Complete)

- [x] Control flow (`if`, `for`, `while`, `case`, `until`)
- [x] Functions
- [x] Parameter expansion (`${}`, arrays)
- [x] Command substitution (`$()`, backticks)
- [x] Arithmetic expansion (`$(())`, `$[]`)
- [x] Process substitution (`<()`, `>()`)
- [x] Here documents and here strings
- [x] Job control (jobs, fg, bg, disown, wait)
- [x] Signal handling
- [x] Exit traps

## Phase 3: Extended Features (In Progress)

- [x] C-style for loops (`for ((i=0; i<10; i++))`)
- [x] Select menus
- [x] Coprocess support
- [x] Extended globbing (extglob)
- [x] Configuration file support (JSONC)
- [x] Hot-reload configuration
- [ ] Full zsh compatibility layer
- [ ] Fish-style autosuggestions (plugin exists)
- [ ] Syntax highlighting (plugin exists)

## Phase 4: Performance & Polish (Planned)

- [ ] Startup time optimization (<10ms target)
- [ ] Memory footprint reduction
- [ ] Comprehensive test suite
- [ ] Cross-platform CI/CD
- [ ] Documentation completion
- [ ] Plugin ecosystem

## Phase 5: Future Directions

- [ ] Language server protocol support
- [ ] WebAssembly plugins
- [ ] Distributed shell sessions
- [ ] AI-assisted completions

## Module Organization

The codebase is organized into focused modules:

```
src/
├── shell.zig           # Main shell logic
├── main.zig            # Entry point
├── cli.zig             # CLI argument handling
├── parser/             # Command parsing
├── executor/           # Command execution
├── types/              # Type definitions
├── utils/              # Utility functions
├── history/            # History management
├── jobs/               # Job control
├── prompt/             # Prompt rendering
├── plugins/            # Plugin system
├── scripting/          # Script execution
└── config_loader.zig   # Configuration
```

## Contributing

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for contribution guidelines.

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.
