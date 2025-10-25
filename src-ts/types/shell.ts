import type { KrustyConfig as BaseKrustyConfig, Plugin } from '../types'

/**
 * Extended KrustyConfig with required properties for the shell
 */
export interface KrustyShellConfig extends Omit<BaseKrustyConfig, 'plugins'> {
  historySize: number
  historyFile: string
  verbose: boolean
  plugins: Array<string | Plugin>
  aliases: Record<string, string>
  theme?: {
    colorScheme?: 'dark' | 'light' | 'auto'
    prompt?: {
      left?: string
    }
  }
}

/**
 * Shell interface that enforces the correct config type
 */
export interface Shell {
  config: KrustyShellConfig
  cwd: string
  environment: Record<string, string>
  history: string[]
  aliases: Record<string, string>
  builtins: Map<string, BuiltinCommand>
  log: Logger
  umask: number
  jobs: Job[]
  // POSIX-like flags
  nounset: boolean
  xtrace: boolean
  pipefail: boolean
  // Interactive session management
  isInteractive: () => boolean
  getCurrentInputForTesting?: () => string

  // Core methods
  execute: (command: string, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, bypassScriptDetection?: boolean }) => Promise<CommandResult>
  executeCommand: (command: string, args: string[]) => Promise<CommandResult>
  parseCommand: (input: string) => ParsedCommand
  addJob: (command: string, pid?: number) => number
  removeJob: (id: number, force?: boolean) => boolean
  getJob: (id: number) => Job | undefined
  getJobs: () => Job[]
  setJobStatus: (id: number, status: 'running' | 'stopped' | 'done') => void
}

export interface CommandResult {
  exitCode: number
  stdout: string
  stderr: string
  duration: number
}

export interface ParsedCommand {
  command: string
  args: string[]
  options: Record<string, unknown>
  original: string
}

export interface BuiltinCommand {
  (args: string[]): Promise<number> | number
  description?: string
  usage?: string
  options?: Record<string, { alias?: string, description: string, type: 'string' | 'boolean' | 'number' }>
  execute?: (args: string[], shell: Shell) => Promise<CommandResult> | CommandResult
}

export interface Job {
  id: number
  pid?: number
  command: string
  status: 'running' | 'stopped' | 'done'
  fg?: boolean
}

export interface Logger {
  debug: (...args: unknown[]) => void
  info: (...args: unknown[]) => void
  warn: (...args: unknown[]) => void
  error: (...args: unknown[]) => void
}

export interface PromptRenderer {
  render: (cwd: string, systemInfo: SystemInfo, gitInfo: GitInfo, exitCode: number) => Promise<string>
  renderRight: (cwd: string, systemInfo: SystemInfo, gitInfo: GitInfo, exitCode: number) => Promise<string>
}

export interface SystemInfo {
  username: string
  hostname: string
  os: string
  arch: string
}

export interface GitInfo {
  branch?: string
  dirty: boolean
  ahead: number
  behind: number
  untracked: number
  modified: number
  deleted: number
  staged: number
  conflicts: number
}

export interface CompletionProvider {
  getCompletions: (line: string, cursor: number) => Promise<Completion[]>
}

export interface Completion {
  text: string
  displayText?: string
  description?: string
  type?: string
  icon?: string
  priority?: number
}

// Re-export types that might be used elsewhere
export * from '../types'
