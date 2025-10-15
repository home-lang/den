![Krusty Shell](.github/art/cover.jpg)

[![npm version][npm-version-src]][npm-version-href]
[![GitHub Actions][github-actions-src]][github-actions-href]
[![Commitizen friendly](https://img.shields.io/badge/commitizen-friendly-brightgreen.svg)](http://commitizen.github.io/cz-cli/)
<!-- [![npm downloads][npm-downloads-src]][npm-downloads-href] -->
<!-- [![Codecov][codecov-src]][codecov-href] -->

# Krusty Shell

Krusty is a modern, feature-rich shell built with TypeScript and Bun. It provides a familiar shell experience with enhanced features, intelligent auto-suggestions, comprehensive scripting support, and extensive customization options for developers.

## Features

- 🚀 **Performance**: Built on Bun for lightning-fast execution
- 🧠 **Smart completion**: Context-aware command/file completions with caching
- 💡 **Auto-suggestions**: Intelligent inline suggestions with history integration
- 🧩 **Aliases & functions**: Powerful aliasing and shell functions with expansion
- 🧵 **Pipelines & redirections**: Full `|`, `>`, `>>`, `2>&1`, here-strings, process substitution
- 🧭 **Job control**: Advanced job management with `Ctrl+Z`, `Ctrl+C`, `jobs`, `bg`, `fg`, `kill`, `wait`
- 📜 **Scripting**: Complete scripting engine with control flow, functions, and error handling
- 🎨 **Themes**: Highly configurable prompts with Git status and runtime detection
- 🔌 **Plugins**: Extensible plugin system with hooks and lifecycle management

## Quick start

```bash
# Install Krusty globally
bun add -g krusty
npm install -g krusty
yarn global add krusty
pnpm global add krusty

# Start the shell
krusty

# Or run directly with Bun
bunx krusty
```

## Built-in Commands

Krusty ships with a comprehensive set of built-ins. Run `help` for details.

### Core shell

- [`alias`](https://krusty.sh/commands/alias), [`unalias`](https://krusty.sh/commands/unalias) — manage aliases
- [`type`](https://krusty.sh/commands/type), [`which`](https://krusty.sh/commands/which), [`hash`](https://krusty.sh/commands/hash) — identify commands and hash lookups
- [`help`](https://krusty.sh/commands/help), [`history`](https://krusty.sh/commands/history) — builtin help and command history
- [`set`](https://krusty.sh/commands/set), [`export`](https://krusty.sh/commands/export), [`unset`](https://krusty.sh/commands/unset), [`umask`](https://krusty.sh/commands/umask) — shell/options and environment
- [`source`](https://krusty.sh/commands/source), [`eval`](https://krusty.sh/commands/eval), [`exec`](https://krusty.sh/commands/exec), [`read`](https://krusty.sh/commands/read) — script and execution helpers
- [`printf`](https://krusty.sh/commands/printf), [`echo`](https://krusty.sh/commands/echo), [`test`](https://krusty.sh/commands/test), [`true`](https://krusty.sh/commands/true), [`false`](https://krusty.sh/commands/false) — basic utilities
- [`time`](https://krusty.sh/commands/time), [`times`](https://krusty.sh/commands/times), [`trap`](https://krusty.sh/commands/trap), [`timeout`](https://krusty.sh/commands/timeout), [`getopts`](https://krusty.sh/commands/getopts) — timing, signals, option parsing
- [`command`](https://krusty.sh/commands/command) — run a command bypassing functions/aliases
- [`exit`](https://krusty.sh/commands/exit), [`pwd`](https://krusty.sh/commands/pwd), [`cd`](https://krusty.sh/commands/cd), [`dirs`](https://krusty.sh/commands/dirs), [`pushd`](https://krusty.sh/commands/pushd), [`popd`](https://krusty.sh/commands/popd) — navigation and exit
- [`env`](https://krusty.sh/commands/env), [`clear`](https://krusty.sh/commands/clear) — environment display and screen clear

### Jobs & processes

- [`jobs`](https://krusty.sh/commands/jobs) — list jobs
- [`bg`](https://krusty.sh/commands/bg) — resume a job in background
- [`fg`](https://krusty.sh/commands/fg) — bring a job to foreground
- [`kill`](https://krusty.sh/commands/kill) — send signals to jobs/processes
- [`disown`](https://krusty.sh/commands/disown) — remove jobs from job table
- [`wait`](https://krusty.sh/commands/wait) — wait for jobs to complete

### Developer utilities

- [`reload`](https://krusty.sh/commands/reload) — reload configuration
- [`library`](https://krusty.sh/commands/library) — manage/inspect libraries
- [`show`](https://krusty.sh/commands/show) — display information/details
- [`script-builtins`](https://krusty.sh/commands/script-builtins) — scripting helpers (internal)

### Networking & system helpers

- [`ip`](https://krusty.sh/commands/ip) — display IP info
- [`localip`](https://krusty.sh/commands/localip) — show local IP
- [`reloaddns`](https://krusty.sh/commands/reloaddns) — reload DNS cache

### Productivity helpers

- [`bookmark`](https://krusty.sh/commands/bookmark) — manage bookmarks/paths
- [`copyssh`](https://krusty.sh/commands/copyssh) — copy SSH public key
- [`dotfiles`](https://krusty.sh/commands/dotfiles) — dotfiles helper
- [`emptytrash`](https://krusty.sh/commands/emptytrash) — empty system trash
- [`ft`](https://krusty.sh/commands/ft) — quick fuzzy file helper
- [`hide`](https://krusty.sh/commands/hide) — hide/show files
- [`pstorm`](https://krusty.sh/commands/pstorm) — open in PhpStorm
- [`code`](https://krusty.sh/commands/code) — open in VS Code
- [`shrug`](https://krusty.sh/commands/shrug) — print ¯\\_(ツ)_/¯
- [`wip`](https://krusty.sh/commands/wip) — work-in-progress helper

### Short aliases (quality-of-life)

- [`b`](https://krusty.sh/commands/b), [`bb`](https://krusty.sh/commands/bb), [`bd`](https://krusty.sh/commands/bd), [`bf`](https://krusty.sh/commands/bf), [`bi`](https://krusty.sh/commands/bi), [`bl`](https://krusty.sh/commands/bl), [`br`](https://krusty.sh/commands/br) — convenience wrappers

_Note: A few items are convenience helpers specific to Krusty and not POSIX/Bash standard._

## Usage

### Basic Commands

- Execute external commands and pipelines: `echo hi | tr a-z A-Z`
- Redirect output and duplicate FDs: `sh -c 'echo out; echo err 1>&2' 2>&1 | wc -l`
- Process substitution: `diff <(ls /tmp) <(ls /var/tmp)`

### Job Control

- Background processes: `sleep 5 &`
- Suspend with `Ctrl+Z`, resume with `bg %1` or `fg %1`
- List jobs: `jobs`, kill jobs: `kill %1`, wait for completion: `wait %1`

### Auto-suggestions & History

- Navigate history with `↑`/`↓` arrows
- Inline suggestions appear as you type
- History expansion: `!!` (last command), `!n` (command n), `!prefix` (last command starting with prefix)
- Fuzzy history search with `Ctrl+R`

## Customization

### Configuration File

Krusty uses a `krusty.config.ts` file for configuration. Create one in your project root or home directory:

```typescript
export default {
  // Core settings
  verbose: false,
  streamOutput: true,

  // Aliases
  aliases: {
    ll: 'ls -la',
    gs: 'git status',
    commit: 'git add .; git commit -m',
    wip: 'git add -A && git commit -m "chore: wip" && git push',
  },

  // Environment variables
  environment: {
    EDITOR: 'code',
    PAGER: 'less',
  },

  // History configuration
  history: {
    maxEntries: 10000,
    file: '~/.krusty_history',
    ignoreDuplicates: true,
    ignoreSpace: true,
    searchMode: 'fuzzy', // 'fuzzy' | 'exact' | 'startswith' | 'regex'
  },

  // Completion settings
  completion: {
    enabled: true,
    caseSensitive: false,
    showDescriptions: true,
    maxSuggestions: 10,
    cache: {
      enabled: true,
      ttl: 3600000, // 1 hour
      maxEntries: 1000,
    },
  },
}
```

### Themes & Prompts

Krusty supports extensive prompt customization with module detection:

```typescript
export default {
  // Prompt format with placeholders
  prompt: {
    format: '{path} on {git} {modules} {duration} \n{symbol} ',
    showGit: true,
    showTime: false,
    showUser: false,
    showHost: false,
    showPath: true,
    showExitCode: true,
    transient: false,
  },

  // Theme configuration
  theme: {
    name: 'default',
    autoDetectColorScheme: true,
    enableRightPrompt: true,

    // Git status display
    gitStatus: {
      enabled: true,
      showStaged: true,
      showUnstaged: true,
      showUntracked: true,
      showAheadBehind: true,
      format: '({branch}{ahead}{behind}{staged}{unstaged}{untracked})',
    },

    // Colors
    colors: {
      primary: '#00D9FF',
      secondary: '#FF6B9D',
      success: '#00FF88',
      warning: '#FFD700',
      error: '#FF4757',
      git: {
        branch: '#A277FF',
        ahead: '#50FA7B',
        behind: '#FF5555',
        staged: '#50FA7B',
        unstaged: '#FFB86C',
        untracked: '#FF79C6',
      },
    },

    // Symbols
    symbols: {
      prompt: '❯',
      git: {
        branch: '',
        ahead: '⇡',
        behind: '⇣',
        staged: '●',
        unstaged: '○',
        untracked: '?',
      },
    },
  },

  // Runtime modules (auto-detected)
  modules: {
    bun: { enabled: true, format: 'via {symbol} {version}', symbol: '🐰' },
    nodejs: { enabled: true, format: 'via {symbol} {version}', symbol: '⬢' },
    python: { enabled: true, format: 'via {symbol} {version}', symbol: '🐍' },
    // ... many more supported runtimes
  },
}
```

### Plugins & Hooks

Extend Krusty with plugins and lifecycle hooks:

```typescript
export default {
  // Plugin system
  plugins: [
    'my-custom-plugin',
    {
      name: 'git-plugin',
      enabled: true,
      config: { autoFetch: true },
    },
  ],

  // Lifecycle hooks
  hooks: {
    'shell:init': [
      { command: 'echo "Welcome to Krusty!"' },
    ],
    'command:before': [
      { script: 'echo "Executing: $1"' },
    ],
    'directory:change': [
      { command: 'ls -la', conditions: ['directory'] },
    ],
  },

  // Expansion cache limits
  expansion: {
    cacheLimits: {
      arg: 200,
      exec: 500,
      arithmetic: 500,
    },
  },
}
```

## Scripting

Krusty includes a comprehensive scripting engine with full shell compatibility:

### Control Flow

```bash
# Conditional statements
if [ -f "file.txt" ]; then
    echo "File exists"
else
    echo "File not found"
fi

# Loops
for i in {1..5}; do
    echo "Count: $i"
done

while [ $count -lt 10 ]; do
    echo $count
    ((count++))
done

# Case statements
case $1 in
    start) echo "Starting..." ;;
    stop)  echo "Stopping..." ;;
    *)     echo "Usage: $0 {start|stop}" ;;
esac
```

### Functions

```bash
# Function definitions
function greet() {
    local name=${1:-"World"}
    echo "Hello, $name!"
}

# Alternative syntax
greet() {
    echo "Hello, $1!"
}
```

### Error Handling

```bash
# Set error handling modes
set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

# Trap signals
trap 'echo "Cleanup on exit"' EXIT
```

### Script Built-in Commands

- **Control**: `source`, `eval`, `exec`, `return`, `break`, `continue`
- **Variables**: `local`, `declare`, `readonly`, `unset`, `export`
- **Testing**: `test`, `[`, `[[`, `true`, `false`
- **I/O**: `read`, `printf`, `echo`

See `test/scripting.test.ts` for comprehensive examples.

## Advanced Job Management

Krusty provides advanced job management with proper signal handling:

### Signal Handling

- **Ctrl+Z**: Suspend foreground job (SIGTSTP)
- **Ctrl+C**: Terminate foreground job (SIGINT)
- **Process Groups**: Proper process group management for signal propagation

### Job Management Commands

```bash
# Background a command
sleep 60 &

# List all jobs
jobs
# Output: [1]+ Running    sleep 60 &

# Bring job to foreground
fg %1

# Resume job in background
bg %1

# Send signals to jobs
kill -TERM %1    # Terminate job 1
kill -STOP %2    # Stop job 2
kill -CONT %2    # Continue job 2

# Wait for job completion
wait %1          # Wait for job 1
wait             # Wait for all jobs

# Remove job from job table
disown %1
```

### Real-time Monitoring

- Automatic job status updates
- Background job completion notifications
- Process group cleanup on job termination

## Development

```bash
# Clone the repository
git clone https://github.com/stacksjs/krusty.git
cd krusty

# Install dependencies
bun install

# Build the project
bun run build
```

## Testing

```bash
bun test
```

## Changelog

Please see our [releases](https://github.com/stacksjs/krusty/releases) page for more information on what has changed recently.

## Contributing

Please see [CONTRIBUTING](.github/CONTRIBUTING.md) for details.

## Community

For help, discussion about best practices, or any other conversation that would benefit from being searchable:

[Discussions on GitHub](https://github.com/stacksjs/krusty/discussions)

For casual chit-chat with others using this package:

[Join the Stacks Discord Server](https://discord.gg/stacksjs)

## Postcardware

“Software that is free, but hopes for a postcard.” We love receiving postcards from around the world showing where Stacks is being used! We showcase them on our website too.

Our address: Stacks.js, 12665 Village Ln #2306, Playa Vista, CA 90094, United States 🌎

## Sponsors

We would like to extend our thanks to the following sponsors for funding Stacks development. If you are interested in becoming a sponsor, please reach out to us.

- [JetBrains](https://www.jetbrains.com/)
- [The Solana Foundation](https://solana.com/)

## License

The MIT License (MIT). Please see [LICENSE](LICENSE.md) for more information.

Made with 💙

<!-- Badges -->
[npm-version-src]: https://img.shields.io/npm/v/krusty?style=flat-square
[npm-version-href]: https://npmjs.com/package/krusty
[github-actions-src]: https://img.shields.io/github/actions/workflow/status/stacksjs/krusty/ci.yml?style=flat-square&branch=main
[github-actions-href]: https://github.com/stacksjs/krusty/actions?query=workflow%3Aci

<!-- [codecov-src]: https://img.shields.io/codecov/c/gh/stacksjs/krusty/main?style=flat-square
[codecov-href]: https://codecov.io/gh/stacksjs/krusty -->
