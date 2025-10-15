import type { KrustyConfig } from './types'
import { homedir } from 'node:os'
import { resolve } from 'node:path'
import process from 'node:process'
import { loadConfig } from 'bunfig'

export const defaultConfig: KrustyConfig = {
  verbose: false,
  streamOutput: true,
  expansion: {
    cacheLimits: {
      arg: 200,
      exec: 500,
      arithmetic: 500,
    },
  },
  logging: {
    prefixes: {
      debug: 'DEBUG',
      info: 'INFO',
      warn: 'WARN',
      error: 'ERROR',
    },
  },
  prompt: {
    // Default prompt focuses on path, git status, and runtime module info (e.g. bun)
    // Example (2-line):
    // "~/Code/krusty on 🌱 main [●1○1] 📦 v0.1.0 via 🐰 v1.2.21 took 5m12s\n❯ "
    // Note: a newline before the prompt symbol places input on the next line
    format: '{path} on {git} {modules} {duration} \n{symbol} ',
    showGit: true,
    showTime: false,
    // Hide user/host by default to match the expected style
    showUser: false,
    showHost: false,
    showPath: true,
    showExitCode: true,
    transient: false,
    // Print a single timestamp line on startup above the first prompt
    startupTimestamp: {
      enabled: true,
      locale: 'en-US',
      options: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' },
      label: undefined,
    },
  },
  history: {
    maxEntries: 10000,
    file: '~/.krusty_history',
    ignoreDuplicates: true,
    ignoreSpace: true,
    searchMode: 'fuzzy',
  },
  completion: {
    // Enable/disable completion system
    enabled: true,
    // Case sensitivity for completions
    caseSensitive: false,
    // Show descriptions with completions
    showDescriptions: true,
    // Maximum number of suggestions to show
    maxSuggestions: 10,
    // Enable completion caching
    cache: {
      enabled: true,
      // Cache expiration in milliseconds (1 hour)
      ttl: 60 * 60 * 1000,
      // Maximum number of completions to cache
      maxEntries: 1000,
    },
    // Context-aware completion settings
    context: {
      // Enable context-aware completions
      enabled: true,
      // Maximum depth to analyze context
      maxDepth: 3,
      // File types to analyze for context
      fileTypes: ['.ts', '.js', '.tsx', '.jsx', '.json', '.md'],
    },
    // Command-specific completion settings
    commands: {
      git: {
        // Enable git completions
        enabled: true,
        // Include porcelain commands
        includePorcelain: true,
        // Include plumbing commands
        includePlumbing: false,
      },
      npm: {
        // Enable npm completions
        enabled: true,
        // Include script names from package.json
        includeScripts: true,
      },
    },
  },
  aliases: {
    // Stage all changes and open a commit message prompt
    commit: 'git add .; git commit -m',
    // Work-in-progress: create a WIP commit and push with styled, informative output
    // - Show concise status and staged diff before committing
    // - Suppress commit's own summary (-q) to avoid duplicate info
    // - Skip commit/push if no staged changes are present
    // - Only run post-commit log and push if commit succeeds
    wip: 'printf \'\\x1b[2m\\x1b[36m─── WIP start ───\\x1b[0m\\n\'; git --no-pager -c color.ui=always status -sb; git -c color.ui=always add -A; printf \'\\x1b[2mstaged summary\\x1b[0m\\n\'; git --no-pager -c color.ui=always diff --cached --stat; git diff --cached --quiet && printf \'\\x1b[2m\\x1b[33mno changes to commit; skipping push\\x1b[0m\\n\' || git -c color.ui=always commit -m \'chore: wip\' -q && printf \'\\x1b[2mcommit (last)\\x1b[0m\\n\' && git --no-pager -c color.ui=always log -1 --oneline && printf \'\\x1b[2m\\x1b[36m─── pushing ───\\x1b[0m\\n\' && git -c color.ui=always push; printf \'\\x1b[2m\\x1b[32m─── done ───\\x1b[0m\\n\'',
    // Push current branch
    push: 'git push',
  },
  environment: {},
  // Plugin system configuration
  plugins: [],
  theme: {
    // Theme name to use (must match a theme in themes/ directory)
    name: 'default',
    // Auto-detect system color scheme
    autoDetectColorScheme: true,
    // Default color scheme (light/dark/auto)
    defaultColorScheme: 'auto',
    // Enable right prompt
    enableRightPrompt: true,
    // Git status in prompt settings
    gitStatus: {
      enabled: true,
      showStaged: true,
      showUnstaged: true,
      showUntracked: true,
      showAheadBehind: true,
      format: '({branch}{ahead}{behind}{staged}{unstaged}{untracked})',
      branchBold: true,
    },
    // Prompt configuration
    prompt: {
      left: '\u001B[32m{user}@{host}\u001B[0m \u001B[34m{path}\u001B[0m {git}{symbol} ',
      right: '{time}{jobs}{status}',
      continuation: '... ',
      error: '\u001B[31m{code}\u001B[0m',
    },
    // Colors configuration
    colors: {
      primary: '#00D9FF',
      secondary: '#FF6B9D',
      success: '#00FF88',
      warning: '#FFD700',
      error: '#FF4757',
      info: '#74B9FF',
      // Git status colors
      git: {
        branch: '#A277FF',
        ahead: '#50FA7B',
        behind: '#FF5555',
        staged: '#50FA7B',
        unstaged: '#FFB86C',
        untracked: '#FF79C6',
        conflict: '#FF5555',
      },
      // Module-specific colors
      modules: {
        bunVersion: '#FF6B6B',
        packageVersion: '#FFA500',
      },
    },
    // Font configuration
    font: {
      // Default to system monospace font stack with fallbacks
      family: 'ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, Liberation Mono, monospace',
      size: 14,
      weight: 'normal',
      lineHeight: 1.4,
      ligatures: false,
    },
    // Symbol configuration
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
        conflict: '✗',
      },
    },
  },
  modules: {
    // Language modules - enabled by default
    bun: { enabled: true, format: 'via {symbol} {version}', symbol: '🐰' },
    deno: { enabled: true, format: 'via {symbol} {version}', symbol: '🦕' },
    nodejs: { enabled: true, format: 'via {symbol} {version}', symbol: '⬢' },
    python: { enabled: true, format: 'via {symbol} {version}', symbol: '🐍' },
    golang: { enabled: true, format: 'via {symbol} {version}', symbol: '🐹' },
    java: { enabled: true, format: 'via {symbol} {version}', symbol: '☕' },
    kotlin: { enabled: true, format: 'via {symbol} {version}', symbol: '🅺' },
    php: { enabled: true, format: 'via {symbol} {version}', symbol: '🐘' },
    ruby: { enabled: true, format: 'via {symbol} {version}', symbol: '💎' },
    swift: { enabled: true, format: 'via {symbol} {version}', symbol: '🐦' },
    zig: { enabled: true, format: 'via {symbol} {version}', symbol: '⚡' },
    lua: { enabled: true, format: 'via {symbol} {version}', symbol: '🌙' },
    perl: { enabled: true, format: 'via {symbol} {version}', symbol: '🐪' },
    rlang: { enabled: true, format: 'via {symbol} {version}', symbol: '📊' },
    dotnet: { enabled: true, format: 'via {symbol} {version}', symbol: '.NET' },
    erlang: { enabled: true, format: 'via {symbol} {version}', symbol: 'E' },
    c: { enabled: true, format: 'via {symbol} {version}', symbol: 'C' },
    cpp: { enabled: true, format: 'via {symbol} {version}', symbol: 'C++' },
    cmake: { enabled: true, format: 'via {symbol} {version}', symbol: '△' },
    terraform: { enabled: true, format: 'via {symbol} {version}', symbol: '💠' },
    pulumi: { enabled: true, format: 'via {symbol} {version}', symbol: '🧊' },

    // Cloud modules
    aws: { enabled: true, format: 'on {symbol} {profile}({region})', symbol: '☁️' },
    azure: { enabled: true, format: 'on {symbol} {subscription}', symbol: '󰠅' },
    gcloud: { enabled: true, format: 'on {symbol} {project}', symbol: '☁️' },

    // Git modules
    git_branch: {
      enabled: true,
      format: 'on {symbol} {branch}',
      symbol: '',
      truncation_length: 20,
      truncation_symbol: '…',
    },
    git_commit: { enabled: true, format: '({hash})', commit_hash_length: 7 },
    git_state: { enabled: true, format: '({state})' },
    git_status: { enabled: true, format: '[{status}]' },
    git_metrics: { enabled: true, format: '({metrics})' },

    // System modules
    os: {
      enabled: false, // Disabled by default
      format: 'on {symbol} {name}',
      symbol: '💻',
      // Per-platform overrides
      // Keys match process.platform values: 'darwin', 'linux', 'win32', etc.
      symbols: { darwin: '', linux: '🐧', win32: '🪟' },
    },
    hostname: { enabled: true, format: '@{hostname}', ssh_only: true, showOnLocal: false },
    directory: {
      enabled: true,
      format: '{path}',
      truncation_length: 3,
      truncate_to_repo: true,
      home_symbol: '~',
      readonly_symbol: '🔒',
    },
    username: { enabled: true, format: '{username}', show_always: false, showOnLocal: false, root_format: '{username}' },
    shell: { enabled: false, format: '{indicator}' }, // Disabled by default
    battery: {
      enabled: true,
      format: '{symbol} {percentage}%',
      full_symbol: '🔋',
      charging_symbol: '🔌',
      discharging_symbol: '🔋',
      unknown_symbol: '🔋',
      empty_symbol: '🪫',
      // New fields (used by refactored module but keep legacy above)
      symbol: '🔋',
      symbol_charging: '🔌',
      symbol_low: '🪫',
    },
    cmd_duration: {
      enabled: true,
      format: 'took {duration}',
      min_time: 2000,
      min_ms: 2000,
      show_milliseconds: false,
    },
    memory_usage: {
      enabled: false, // Disabled by default
      format: '🐏 {ram}',
      threshold: 75,
      symbol: '🐏',
    },
    time: { enabled: false, format: '{symbol} {time}', symbol: '🕐', options: { hour: '2-digit', minute: '2-digit' } }, // Disabled by default
    nix_shell: {
      enabled: true,
      format: 'via {symbol} {state}',
      symbol: '❄️',
      impure_msg: 'impure',
      pure_msg: 'pure',
      unknown_msg: 'shell',
    },

    // Custom modules can be added by users in their config
    env_var: {},
    custom: {},
  },

  // Hooks configuration
  hooks: {
    // Shell lifecycle hooks
    'shell:init': [],
    'shell:start': [],
    'shell:stop': [],
    'shell:exit': [],

    // Command hooks
    'command:before': [],
    'command:after': [],
    'command:error': [],

    // Prompt hooks
    'prompt:before': [],
    'prompt:after': [],
    'prompt:render': [],

    // Directory hooks
    'directory:change': [],
    'directory:enter': [],
    'directory:leave': [],

    // History hooks
    'history:add': [],
    'history:search': [],

    // Completion hooks
    'completion:before': [],
    'completion:after': [],
  },
}

// Use a function to avoid top-level await issues
export const config: KrustyConfig = (() => {
  try {
    return loadConfig({
      name: 'krusty',
      defaultConfig,
    }) as any
  }
  catch {
    return defaultConfig
  }
})()

// Provide a reusable loader that always fetches the latest config from disk
// Options:
// - path: explicit path to a config file; if provided, we load it directly
export async function loadKrustyConfig(options?: { path?: string }): Promise<KrustyConfig> {
  // 1) Explicit path wins
  const explicitPath = options?.path || process.env.KRUSTY_CONFIG
  if (explicitPath) {
    try {
      const abs = resolvePath(explicitPath)
      const mod = await import(abs)
      const userCfg = mod.default ?? mod
      return { ...defaultConfig, ...(userCfg as KrustyConfig) }
    }
    catch {
      // Fall back to bunfig loading
    }
  }

  // 2) bunfig search (current dir up, then user config locations)
  return await loadConfig({
    name: 'krusty',
    defaultConfig,
  })
}

function resolvePath(p: string): string {
  // Support tilde expansion and relative paths
  if (p.startsWith('~')) {
    return resolve(homedir(), p.slice(1))
  }
  return resolve(p)
}

// Validate a loaded Krusty config and return errors/warnings without throwing.
export function validateKrustyConfig(cfg: KrustyConfig): { valid: boolean, errors: string[], warnings: string[] } {
  const errors: string[] = []
  const warnings: string[] = []

  if (!cfg) {
    errors.push('Config is undefined or null')
  }

  // History validation
  const hist = cfg?.history as any
  if (hist) {
    if (hist.maxEntries != null && (typeof hist.maxEntries !== 'number' || hist.maxEntries <= 0)) {
      errors.push(`history.maxEntries must be a positive number (got: ${hist.maxEntries})`)
    }
    const allowedModes = new Set(['fuzzy', 'exact', 'startswith', 'regex'])
    if (hist.searchMode && !allowedModes.has(hist.searchMode)) {
      errors.push(`history.searchMode must be one of ${Array.from(allowedModes).join(', ')} (got: ${hist.searchMode})`)
    }
    if (hist.searchLimit != null && (typeof hist.searchLimit !== 'number' || hist.searchLimit <= 0)) {
      errors.push(`history.searchLimit must be a positive number (got: ${hist.searchLimit})`)
    }
  }

  // Completion validation
  const comp = (cfg as any).completion
  if (comp) {
    if (comp.maxSuggestions != null && (typeof comp.maxSuggestions !== 'number' || comp.maxSuggestions <= 0)) {
      errors.push(`completion.maxSuggestions must be a positive number (got: ${comp.maxSuggestions})`)
    }
  }

  // Expansion cache limits validation
  const exp = (cfg as any).expansion
  if (exp && exp.cacheLimits) {
    const { arg, exec, arithmetic } = exp.cacheLimits
    if (arg != null && (typeof arg !== 'number' || arg <= 0))
      errors.push(`expansion.cacheLimits.arg must be a positive number (got: ${arg})`)
    if (exec != null && (typeof exec !== 'number' || exec <= 0))
      errors.push(`expansion.cacheLimits.exec must be a positive number (got: ${exec})`)
    if (arithmetic != null && (typeof arithmetic !== 'number' || arithmetic <= 0))
      errors.push(`expansion.cacheLimits.arithmetic must be a positive number (got: ${arithmetic})`)
  }

  // Plugins validation (shape only)
  if (cfg?.plugins != null && !Array.isArray(cfg.plugins)) {
    errors.push('plugins must be an array of plugin configuration objects')
  }

  // Hooks validation (shape only)
  if (cfg?.hooks != null && typeof cfg.hooks !== 'object') {
    errors.push('hooks must be an object mapping hook names to arrays of hook configs')
  }

  return { valid: errors.length === 0, errors, warnings }
}

// Create a human-readable diff between two configs (shallow for readability)
export function diffKrustyConfigs(oldCfg: KrustyConfig, newCfg: KrustyConfig): string[] {
  const changes: string[] = []
  const keys = new Set<string>([...Object.keys(oldCfg || {}), ...Object.keys(newCfg || {})])

  const summarize = (val: any): string => {
    if (val === undefined) {
      return 'undefined'
    }
    if (val === null) {
      return 'null'
    }
    if (typeof val === 'object') {
      if (val && (val.maxEntries != null || val.searchMode != null)) {
        return JSON.stringify({
          maxEntries: val.maxEntries,
          ignoreDuplicates: val.ignoreDuplicates,
          ignoreSpace: val.ignoreSpace,
          searchMode: val.searchMode,
          searchLimit: val.searchLimit,
          file: val.file,
        })
      }
      if (Array.isArray(val)) {
        return `[array:${val.length}]`
      }
      return '{...}'
    }
    return JSON.stringify(val)
  }

  for (const k of Array.from(keys).sort()) {
    const a = (oldCfg as any)?.[k]
    const b = (newCfg as any)?.[k]
    const same = (JSON.stringify(a) === JSON.stringify(b))
    if (!same) {
      changes.push(`${k}: ${summarize(a)} -> ${summarize(b)}`)
    }
  }

  return changes
}
