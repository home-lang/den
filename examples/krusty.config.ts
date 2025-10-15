import type { KrustyConfig } from '../src/types'

/**
 * Example krusty Configuration
 *
 * This file demonstrates how to configure krusty with:
 * - Plugins
 * - Hooks
 * - Custom modules
 * - Themes and styling
 */
const exampleConfig: KrustyConfig = {
  verbose: true,

  // Prompt configuration
  prompt: {
    format: '{user}@{host} {path}{git} {modules} {symbol} ',
    showGit: true,
    showTime: false,
    showUser: true,
    showHost: true,
    showPath: true,
    showExitCode: true,
    transient: false,
  },

  // History settings
  history: {
    maxEntries: 50000,
    file: '~/.krusty_history',
    ignoreDuplicates: true,
    ignoreSpace: true,
    searchMode: 'fuzzy',
  },

  // Completion settings
  completion: {
    enabled: true,
    caseSensitive: false,
    showDescriptions: true,
    maxSuggestions: 15,
  },

  // Expansion engine settings
  expansion: {
    // Configure cache size limits for expansion caches
    cacheLimits: {
      // Argument splitting cache (e.g., whitespace/tokenization)
      arg: 300,
      // Executable resolution cache (PATH lookups)
      exec: 800,
      // Arithmetic expression evaluation cache
      arithmetic: 600,
    },
  },

  // Shell aliases
  aliases: {
    ll: 'ls -la',
    la: 'ls -A',
    l: 'ls -CF',
    grep: 'grep --color=auto',
    fgrep: 'fgrep --color=auto',
    egrep: 'egrep --color=auto',
    cls: 'clear',
    h: 'history',
    j: 'jobs',
    df: 'df -h',
    du: 'du -h',
    mkdir: 'mkdir -pv',
    wget: 'wget -c',
    path: 'echo $PATH | tr ":" "\\n"',
    now: 'date +"%T"',
    nowdate: 'date +"%d-%m-%Y"',
    vi: 'vim',
    svi: 'sudo vi',
    edit: 'vim',
  },

  // Environment variables
  environment: {
    EDITOR: 'vim',
    PAGER: 'less',
    BROWSER: 'open',
    TERM: 'xterm-256color',
  },

  // Plugin configuration
  plugins: [
    {
      name: 'git-plugin',
      path: './examples/plugins/git-plugin.ts',
      enabled: true,
      config: {
        autoFetch: true,
        showBranchInPrompt: true,
        colorOutput: true,
      },
    },
    {
      name: 'docker-plugin',
      path: '~/.krusty/plugins/docker-plugin.js',
      enabled: true,
      config: {
        showContainerCount: true,
        autoComplete: true,
      },
    },
    {
      name: 'aws-plugin',
      path: '~/.krusty/plugins/aws-plugin.js',
      enabled: false, // Disabled by default
      config: {
        showProfile: true,
        showRegion: true,
      },
    },
  ],

  // Theme configuration
  theme: {
    colors: {
      primary: '#00D9FF',
      secondary: '#FF6B9D',
      success: '#00FF88',
      warning: '#FFD700',
      error: '#FF4757',
      info: '#74B9FF',
    },
    symbols: {
      prompt: '❯',
      continuation: '…',
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

  // Module configuration
  modules: {
    // Language modules
    bun: { enabled: true, format: 'via {symbol} {version}', symbol: '🐰' },
    deno: { enabled: true, format: 'via {symbol} {version}', symbol: '🦕' },
    nodejs: { enabled: true, format: 'via {symbol} {version}', symbol: '⬢' },
    python: { enabled: true, format: 'via {symbol} {version}', symbol: '🐍' },
    golang: { enabled: true, format: 'via {symbol} {version}', symbol: '🐹' },
    java: { enabled: false, format: 'via {symbol} {version}', symbol: '☕' }, // Disabled for performance

    // Cloud modules
    aws: { enabled: true, format: 'on {symbol} {profile}({region})', symbol: '☁️' },
    azure: { enabled: false, format: 'on {symbol} {subscription}', symbol: '󰠅' },
    gcloud: { enabled: false, format: 'on {symbol} {project}', symbol: '☁️' },

    // Git modules
    git_branch: {
      enabled: true,
      format: 'on {symbol} {branch}',
      symbol: '',
      truncation_length: 15,
      truncation_symbol: '…',
    },
    git_status: { enabled: true, format: '[{status}]' },
    git_commit: { enabled: false, format: '({hash})', commit_hash_length: 7 },

    // System modules
    os: {
      enabled: false,
      format: 'on {symbol} {name}',
      symbol: '💻',
      symbols: { darwin: '', linux: '🐧', win32: '🪟' },
    },
    directory: {
      enabled: true,
      format: '{path}',
      truncation_length: 3,
      truncate_to_repo: true,
      home_symbol: '~',
      readonly_symbol: '🔒',
    },
    username: { enabled: true, format: '{username}', show_always: false, showOnLocal: false, root_format: '{username}' },
    hostname: { enabled: true, format: '@{hostname}', ssh_only: true, showOnLocal: false },
    battery: {
      enabled: true,
      format: '{symbol} {percentage}%',
      full_symbol: '🔋',
      charging_symbol: '🔌',
      discharging_symbol: '🔋',
      unknown_symbol: '🔋',
      empty_symbol: '🪫',
      // New unified fields
      symbol: '🔋',
      symbol_charging: '🔌',
      symbol_low: '🪫',
    },
    cmd_duration: {
      enabled: true,
      format: 'took {duration}',
      min_time: 1000, // Show for commands taking more than 1 second
      min_ms: 1000,
      show_milliseconds: false,
    },
    time: { enabled: false, format: '{symbol} {time}', symbol: '🕐', locale: undefined, options: { hour: '2-digit', minute: '2-digit' } },
    memory_usage: { enabled: false, format: '🐏 {ram}', threshold: 80 },
  },

  // Hooks configuration
  hooks: {
    // Shell lifecycle hooks
    'shell:init': [
      {
        name: 'welcome-message',
        command: 'echo "🚀 Welcome to krusty! Type \\"help\\" for available commands."',
        enabled: true,
        priority: 10,
      },
    ],

    'shell:start': [
      {
        name: 'check-updates',
        command: 'krusty --check-updates',
        enabled: true,
        async: true,
        timeout: 5000,
        priority: 1,
      },
      {
        name: 'load-custom-functions',
        script: '~/.krusty/scripts/load-functions.sh',
        enabled: true,
        priority: 5,
      },
    ],

    'shell:exit': [
      {
        name: 'cleanup-temp',
        command: 'rm -rf /tmp/krusty-*',
        enabled: true,
        async: true,
      },
      {
        name: 'goodbye-message',
        command: 'echo "👋 Goodbye from krusty!"',
        enabled: true,
      },
    ],

    // Command hooks
    'command:before': [
      {
        name: 'command-timer-start',
        command: 'echo "⏱️  Executing: {command}"',
        enabled: false, // Disabled by default to avoid spam
        conditions: [
          {
            type: 'env',
            value: 'krusty_VERBOSE_COMMANDS',
            operator: 'exists',
          },
        ],
      },
      {
        name: 'dangerous-command-warning',
        script: '~/.krusty/scripts/check-dangerous-commands.sh',
        enabled: true,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.command.includes("rm -rf") || context.data.command.includes("sudo")',
          },
        ],
      },
    ],

    'command:after': [
      {
        name: 'command-success-notification',
        command: 'echo "✅ Command completed successfully"',
        enabled: false,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.result.exitCode === 0 && context.data.result.duration > 10000',
          },
        ],
      },
    ],

    'command:error': [
      {
        name: 'error-logging',
        script: '~/.krusty/scripts/log-errors.sh',
        enabled: true,
        async: true,
      },
      {
        name: 'suggest-corrections',
        command: 'echo "💡 Try: krusty --suggest \\"{command}\\""',
        enabled: true,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.result.stderr.includes("command not found")',
          },
        ],
      },
    ],

    // Directory hooks
    'directory:change': [
      {
        name: 'auto-ls',
        command: 'ls -la',
        enabled: false, // Disabled by default
        conditions: [
          {
            type: 'env',
            value: 'krusty_AUTO_LS',
            operator: 'exists',
          },
        ],
      },
      {
        name: 'project-detection',
        script: '~/.krusty/scripts/detect-project.sh',
        enabled: true,
        async: true,
      },
      {
        name: 'git-status-check',
        command: 'git status --porcelain 2>/dev/null | head -5',
        enabled: true,
        conditions: [
          {
            type: 'directory',
            value: '.git',
            operator: 'exists',
          },
        ],
      },
    ],

    // Prompt hooks
    'prompt:before': [
      {
        name: 'update-window-title',
        command: 'echo -ne "\\033]0;krusty - $(pwd)\\007"',
        enabled: true,
        async: true,
      },
    ],

    // History hooks
    'history:add': [
      {
        name: 'backup-important-commands',
        script: '~/.krusty/scripts/backup-command.sh',
        enabled: true,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.command.includes("sudo") || context.data.command.includes("rm")',
          },
        ],
      },
    ],

    // Completion hooks
    'completion:before': [
      {
        name: 'load-dynamic-completions',
        script: '~/.krusty/scripts/load-completions.sh',
        enabled: true,
        async: true,
        timeout: 1000,
      },
    ],

    // Custom hooks
    'git:push': [
      {
        name: 'run-tests-before-push',
        command: 'npm test',
        enabled: true,
        conditions: [
          {
            type: 'file',
            value: 'package.json',
            operator: 'exists',
          },
        ],
      },
    ],

    'docker:build': [
      {
        name: 'cleanup-old-images',
        command: 'docker image prune -f',
        enabled: true,
        async: true,
      },
    ],
  },
}

export default exampleConfig
