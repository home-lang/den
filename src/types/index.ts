import type { HistoryManager } from '../history/history-manager'
import type { HookManager } from '../hooks/hook-manager'

// Logger interface
export interface Logger {
  log: (message: string, ...args: any[]) => void
  error: (message: string, ...args: any[]) => void
  warn: (message: string, ...args: any[]) => void
  info: (message: string, ...args: any[]) => void
  debug: (message: string, ...args: any[]) => void
}

// KrustyConfig type with all required properties
export interface KrustyConfig {
  prompt?: string
  /** Maximum number of commands to keep in history */
  historySize: number

  /** Path to the history file */
  historyFile: string

  // Other config properties
  [key: string]: unknown
}

// Command parser interface
export interface CommandParser {
  parse: (input: string) => ParsedCommand
}

// Prompt renderer interface
export interface PromptRenderer {
  render: () => Promise<string>
}

// System info provider interface
export interface SystemInfoProvider {
  getInfo: () => Record<string, unknown>
}

// Git info provider interface
export interface GitInfoProvider {
  getInfo: (cwd: string) => Promise<Record<string, unknown>>
}

// Completion provider interface
export interface CompletionProvider {
  getCompletions: (line: string) => Promise<string[]>
}

// Command result type
export interface CommandResult {
  exitCode: number
  stdout: string
  stderr: string
  duration: number
}

// Parsed command type
export interface ParsedCommand {
  command: string
  args: string[]
  commands: Array<{ name: string, args: string[] }>
  input?: string
  output?: string
  background?: boolean
}

// Shell interface
export interface Shell {
  // Properties
  config: KrustyConfig
  cwd: string
  environment: Record<string, string>
  aliases: Record<string, string>
  builtins: Map<string, (args: string[]) => Promise<number> | number>
  history: string[]
  jobs: Array<{
    id: number
    pid: number
    command: string
    status: 'running' | 'stopped' | 'done'
  }>
  log: Logger
  hashTable: Map<string, string>
  signalHandlers: Map<string, (() => void) | null>
  lastExitCode: number
  parser: CommandParser
  promptRenderer: PromptRenderer
  systemInfoProvider: SystemInfoProvider
  gitInfoProvider: GitInfoProvider
  completionProvider: CompletionProvider
  pluginManager: any
  rl: any
  historyManager: HistoryManager
  hookManager: HookManager
  nextJobId: number
  running: boolean
  isEnhancedInitialized: boolean

  // Methods
  start: () => Promise<void>
  stop: () => void
  execute: (input: string, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }) => Promise<CommandResult>
  executeCommand: (command: string, args: string[]) => Promise<number>
  executeBuiltin: (command: string, args: string[]) => Promise<number>
  executeExternal: (command: string, args: string[]) => Promise<number>
  changeDirectory: (path: string) => Promise<boolean>
  getPrompt: () => Promise<string>
  addJob: (pid: number, command: string) => number
  removeJob: (id: number) => void
  getJob: (id: number) => { id: number, pid: number, command: string, status: 'running' | 'stopped' | 'done' } | undefined
  getJobs: () => Array<{ id: number, pid: number, command: string, status: 'running' | 'stopped' | 'done' }>
  initializeEnhancedFeatures: () => Promise<void>
  executeParsedCommand: (parsed: ParsedCommand) => Promise<number>
  executeCommandChain: (parsed: ParsedCommand, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }) => Promise<CommandResult>
  executeSingleCommand: (command: any, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }) => Promise<CommandResult>
  executePipedCommands: (commands: any[], options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }) => Promise<CommandResult>
}
