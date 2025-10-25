import type { DenConfig } from './src-ts/types'

/**
 * Den Configuration
 *
 * This configuration provides a familiar zsh-like experience with:
 * - Starship-inspired prompt with dynamic modules
 * - Git integration and enhanced workflow
 * - Development environment detection
 * - Performance optimizations
 * - Familiar aliases and environment setup
 */
export default {
  verbose: false,

  // Prompt configuration - Starship-inspired but familiar
  prompt: {
    // Single-line: path + git + modules + symbol
    format: '{path}{git} {modules} \n{symbol} ',
    // format: '{user}@{host} \x1B[1m{path}\x1B[0m{git} {modules} {symbol} ',
    showGit: true,
    showTime: false,
    showUser: false,
    showHost: false,
    showPath: true,
    showExitCode: true,
    transient: false,
  },

  // History settings - optimized for development workflow
  history: {
    maxEntries: 50000,
    file: '~/.den_history',
    ignoreDuplicates: true,
    ignoreSpace: true,
    searchMode: 'fuzzy',
  },

  // Completion settings - fast and intelligent
  completion: {
    enabled: true,
    caseSensitive: false,
    showDescriptions: true,
    maxSuggestions: 15,
  },

  // Shell aliases - familiar zsh-style aliases
  aliases: {
    // File operations
    'll': 'ls -la',
    'la': 'ls -A',
    'l': 'ls -CF',
    'lt': 'ls -lt',
    'ltr': 'ls -ltr',

    // Navigation
    '..': 'cd ..',
    '...': 'cd ../..',
    '....': 'cd ../../..',
    '.....': 'cd ../../../..',

    // Git shortcuts
    'g': 'git',
    'ga': 'git add',
    'gc': 'git commit',
    'gp': 'git push',
    'gl': 'git pull',
    'gs': 'git status',
    'gd': 'git diff',
    'gb': 'git branch',
    'gco': 'git checkout',
    'gcb': 'git checkout -b',
    'gcm': 'git commit -m',
    'gcam': 'git commit -am',
    'gst': 'git stash',
    'gstp': 'git stash pop',
    'glog': 'git log --oneline --graph --decorate',

    // Development
    'dev': 'npm run dev',
    'build': 'npm run build',
    'test': 'npm test',
    'lint': 'npm run lint',
    'type-check': 'npm run type-check',

    // System utilities
    'grep': 'grep --color=auto',
    'fgrep': 'fgrep --color=auto',
    'egrep': 'egrep --color=auto',
    'cls': 'clear',
    'h': 'history',
    'j': 'jobs',
    'df': 'df -h',
    'du': 'du -h',
    'mkdir': 'mkdir -pv',
    'wget': 'wget -c',
    'path': 'echo $PATH | tr ":" "\\n"',
    'now': 'date +"%T"',
    'nowdate': 'date +"%d-%m-%Y"',

    // Editor shortcuts
    'vi': 'vim',
    'edit': 'vim',
    'code': 'code .',

    // Network and processes
    'ports': 'lsof -i -P -n | grep LISTEN',
    'killport': 'kill -9 $(lsof -ti:',
    'psg': 'ps aux | grep',

    // Docker shortcuts
    'd': 'docker',
    'dc': 'docker-compose',
    'dps': 'docker ps',
    'dpsa': 'docker ps -a',
    'dex': 'docker exec -it',
    'dlogs': 'docker logs -f',

    // Kubernetes shortcuts
    'k': 'kubectl',
    'kg': 'kubectl get',
    'kdp': 'kubectl describe pod',
    'kdn': 'kubectl describe node',
    'kds': 'kubectl describe service',

    // AWS shortcuts
    'aws': 'aws --profile default',
    'awsdev': 'aws --profile dev',
    'awsprod': 'aws --profile prod',

    // Bun shortcuts
    'b': 'bun',
    'bi': 'bun install',
    'br': 'bun run',
    'bt': 'bun test',
    'bd': 'bun dev',
    'bb': 'bun run build',

    // Utility shortcuts
    'weather': 'curl wttr.in',
    'ip': 'curl -s ifconfig.me',
    'localip': 'ipconfig getifaddr en0',
    'speedtest': 'curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python -',
    'reloaddns': 'dscacheutil -flushcache && sudo killall -HUP mDNSResponder',
  },

  // Environment variables - development-focused
  environment: {
    EDITOR: 'vim',
    PAGER: 'less',
    BROWSER: 'open',
    TERM: 'xterm-256color',
    LC_ALL: 'en_US.UTF-8',
    LANG: 'en_US.UTF-8',

    // Development tools
    NODE_ENV: 'development',
    NODE_OPTIONS: '--max-old-space-size=4096',

    // Git configuration
    GIT_EDITOR: 'vim',
    GIT_PAGER: 'less',

    // AWS configuration
    AWS_SDK_LOAD_CONFIG: '1',

    // Performance
    HISTSIZE: '50000',
    SAVEHIST: '50000',

    // Custom paths
    DOTFILES: '$HOME/.dotfiles',
    BUN_INSTALL: '$HOME/.bun',
  },

  // Theme configuration - modern and colorful
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

  // Module configuration - development environment focused
  modules: {
    // Language modules - prioritize what you use most
    bun: { enabled: true, format: 'via {symbol} {version}', symbol: '🐰' },
    deno: { enabled: true, format: 'via {symbol} {version}', symbol: '🦕' },
    nodejs: { enabled: true, format: 'via {symbol} {version}', symbol: '⬢' },
    python: { enabled: true, format: 'via {symbol} {version}', symbol: '🐍' },
    golang: { enabled: true, format: 'via {symbol} {version}', symbol: '🐹' },
    java: { enabled: false, format: 'via {symbol} {version}', symbol: '☕' }, // Disabled for performance
    kotlin: { enabled: false, format: 'via {symbol} {version}', symbol: '🅺' },
    php: { enabled: false, format: 'via {symbol} {version}', symbol: '🐘' },
    ruby: { enabled: false, format: 'via {symbol} {version}', symbol: '💎' },
    swift: { enabled: false, format: 'via {symbol} {version}', symbol: '🐦' },
    zig: { enabled: true, format: 'via {symbol} {version}', symbol: '⚡' },
    lua: { enabled: false, format: 'via {symbol} {version}', symbol: '🌙' },
    perl: { enabled: false, format: 'via {symbol} {version}', symbol: '🐪' },
    rlang: { enabled: false, format: 'via {symbol} {version}', symbol: '📊' },
    dotnet: { enabled: false, format: 'via {symbol} {version}', symbol: '.NET' },
    erlang: { enabled: false, format: 'via {symbol} {version}', symbol: 'E' },
    c: { enabled: false, format: 'via {symbol} {version}', symbol: 'C' },
    cpp: { enabled: false, format: 'via {symbol} {version}', symbol: 'C++' },
    cmake: { enabled: false, format: 'via {symbol} {version}', symbol: '△' },
    terraform: { enabled: true, format: 'via {symbol} {version}', symbol: '💠' },
    pulumi: { enabled: false, format: 'via {symbol} {version}', symbol: '🧊' },

    // Cloud modules - focus on what you use
    aws: { enabled: true, format: 'on {symbol} {profile}({region})', symbol: '☁️' },
    azure: { enabled: false, format: 'on {symbol} {subscription}', symbol: '󰠅' },
    gcloud: { enabled: false, format: 'on {symbol} {project}', symbol: '☁️' },

    // Git modules - enhanced workflow
    git_branch: {
      enabled: true,
      format: 'on {symbol} {branch}',
      symbol: '',
      truncation_length: 15,
      truncation_symbol: '…',
    },
    git_status: {
      enabled: true,
      format: '[{status}]',
      ahead: '🏎💨',
      behind: '😰',
      conflicted: '🏳',
      deleted: '🗑',
      diverged: '🌿',
      modified: '📝',
      renamed: '👅',
      staged: '[ ++($count)](green)',
      stashed: '📦',
      untracked: '🤷‍',
      typechanged: '🔀',
    },
    git_commit: { enabled: false, format: '({hash})', commit_hash_length: 7 },
    git_state: {
      enabled: true,
      format: '[($state( $progress_current of $progress_total))]($style) ',
      cherry_pick: '[🍒 PICKING](bold red)',
      rebase: '[🔄 REBASING](bold yellow)',
      merge: '[🔀 MERGING](bold red)',
      revert: '[↩️ REVERTING](bold purple)',
      bisect: '[🔍 BISECTING](bold blue)',
      am: '[✉️ APPLYING](bold green)',
      progress_format: '[($state( $progress_current of $progress_total))]($style) ',
    },
    git_metrics: { enabled: false, format: '({metrics})' },

    // System modules - essential information
    directory: {
      enabled: true,
      format: '{path}',
      truncation_length: 3,
      truncate_to_repo: true,
      home_symbol: '~',
    },
    username: { enabled: true, format: '{username}', show_always: false },
    hostname: { enabled: true, format: '@{hostname}', ssh_only: true },
    battery: {
      enabled: true,
      format: '{symbol} {percentage}%',
      full_symbol: '🔋',
      charging_symbol: '🔌',
      discharging_symbol: '🔋',
      unknown_symbol: '🔋',
      empty_symbol: '🪫',
    },
    cmd_duration: {
      enabled: true,
      format: 'took [{duration}](yellow)',
      // min_time: 1000, // Show for commands taking more than 1 second
      show_milliseconds: true,
    },
    time: { enabled: false, format: '🕐 {time}' },
    memory_usage: { enabled: false, format: '🐏 {ram}', threshold: 80 },
    os: { enabled: false, format: 'on {symbol} {name}' },
    shell: { enabled: false, format: '{indicator}' },
    nix_shell: {
      enabled: true,
      format: 'via {symbol} {state}',
      symbol: '❄️',
      impure_msg: 'impure',
      pure_msg: 'pure',
      unknown_msg: 'shell',
    },
  },

  // Plugin configuration - start with essential plugins
  plugins: [
    {
      name: 'script-suggester',
      path: './src/plugins/script-suggester.ts',
    },
  ],

  // Hooks configuration - automation and workflow enhancement
  hooks: {
    // Shell lifecycle hooks
    'shell:init': [
      {
        name: 'welcome-message',
        command: 'echo "🚀 Welcome to krusty! Type \\"help\\" for available commands."',
        enabled: true,
        priority: 10,
      },
      {
        name: 'load-dotfiles',
        command: 'source ~/.dotfiles/.krustyrc 2>/dev/null || true',
        enabled: true,
        priority: 5,
      },
    ],

    'shell:start': [
      {
        name: 'check-bun-updates',
        command: 'bun --version && echo "Bun is ready"',
        enabled: true,
        priority: 1,
      },
      {
        name: 'load-custom-functions',
        script: '~/.dotfiles/scripts/load-functions.sh',
        enabled: true,
        priority: 5,
        conditions: [
          {
            type: 'file',
            value: '~/.dotfiles/scripts/load-functions.sh',
            operator: 'exists',
          },
        ],
      },
    ],

    'shell:exit': [
      {
        name: 'cleanup-temp',
        command: 'rm -rf /tmp/krusty-* 2>/dev/null || true',
        enabled: true,
        async: true,
      },
      {
        name: 'goodbye-message',
        command: 'echo "👋 Goodbye from krusty!"',
        enabled: false,
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
        command: 'echo "⚠️  Careful with: {command}"',
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
        name: 'error-suggestions',
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
        command: 'echo "📁 Entered: $(basename $(pwd))"',
        enabled: true,
        async: true,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.cwd !== context.data.previousCwd',
          },
        ],
      },
      {
        name: 'git-status-check',
        command: 'git status --porcelain 2>/dev/null | head -3',
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
        command: 'echo -ne "\\033]0;krusty - $(pwd | sed "s|$HOME|~|g")\\007"',
        enabled: true,
        async: true,
      },
    ],

    // History hooks
    'history:add': [
      {
        name: 'backup-important-commands',
        command: 'echo "$(date): {command}" >> ~/.krusty_important_commands.log',
        enabled: true,
        conditions: [
          {
            type: 'custom',
            value: 'context.data.command.includes("sudo") || context.data.command.includes("rm") || context.data.command.includes("git commit")',
          },
        ],
      },
    ],

    // Completion hooks
    'completion:before': [
      {
        name: 'load-dynamic-completions',
        command: 'echo "Loading completions..." > /dev/null',
        enabled: true,
        async: true,
        timeout: 1000,
      },
    ],

    // Custom hooks for development workflow
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

    'npm:install': [
      {
        name: 'audit-dependencies',
        command: 'npm audit --audit-level moderate',
        enabled: true,
        async: true,
        timeout: 30000,
      },
    ],
  },
} satisfies DenConfig
