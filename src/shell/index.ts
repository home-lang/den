import type { ChildProcess } from 'node:child_process'
import type Readline from 'node:readline'
import type { Job } from '../jobs/job-manager'
import type { BuiltinCommand, CommandResult, KrustyConfig, ParsedCommand, Plugin, Shell, ThemeConfig } from '../types'
import { EventEmitter } from 'node:events'
import { existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { resolve } from 'node:path'
import process from 'node:process'
import { createBuiltins } from '../builtins'
import { CompletionProvider } from '../completion'
import { defaultConfig, diffKrustyConfigs, loadKrustyConfig, validateKrustyConfig } from '../config'
import { HistoryManager, sharedHistory } from '../history'
import { HookManager } from '../hooks'
import { AutoSuggestInput } from '../input/auto-suggest'
import { JobManager } from '../jobs/job-manager'
import { Logger } from '../logger'
import { CommandParser } from '../parser'
import { PluginManager } from '../plugins/plugin-manager'
import { GitInfoProvider, PromptRenderer, SystemInfoProvider } from '../prompt'
import { ScriptManager } from '../scripting/script-manager'
import { ThemeManager } from '../theme/theme-manager'
import { ExpansionUtils } from '../utils/expansion'
import { ScriptErrorHandler } from '../utils/script-error-handler'
import { AliasManager } from './alias-manager'
import { BuiltinManager } from './builtin-manager'
import { CommandChainExecutor } from './command-chain-executor'
import { CommandExecutor } from './command-executor'
import { ReplManager } from './repl-manager'
import { ScriptExecutor } from './script-executor'

// Export all the modular components
export { AliasManager } from './alias-manager'
export { BuiltinManager } from './builtin-manager'
export { CommandChainExecutor } from './command-chain-executor'
export { CommandExecutor } from './command-executor'
export { ReplManager } from './repl-manager'
export { ScriptExecutor } from './script-executor'

export class KrustyShell extends EventEmitter implements Shell {
  public config: KrustyConfig
  public cwd: string
  public environment: Record<string, string>
  public historyManager: HistoryManager
  public aliases: Record<string, string>
  public builtins: Map<string, BuiltinCommand>
  public history: string[] = []
  public jobManager: JobManager
  public jobs: Job[] = [] // Compatibility property for Shell interface
  // POSIX-like shell options
  public nounset: boolean = false
  public xtrace: boolean = false
  public pipefail: boolean = false
  // Last xtrace line printed (for testing/support tooling)
  public lastXtraceLine: string | undefined
  private lastExitCode: number = 0
  private lastCommandDurationMs: number = 0

  private parser: CommandParser
  private promptRenderer: PromptRenderer
  private systemInfoProvider: SystemInfoProvider
  private gitInfoProvider: GitInfoProvider
  private completionProvider: CompletionProvider
  private pluginManager: PluginManager
  private themeManager: ThemeManager
  public hookManager: HookManager
  public log: Logger
  private autoSuggestInput: AutoSuggestInput
  private scriptManager: ScriptManager

  private commandExecutor: CommandExecutor
  private replManager: ReplManager
  private aliasManager: AliasManager
  private builtinManager: BuiltinManager
  private scriptExecutor: ScriptExecutor
  private commandChainExecutor: CommandChainExecutor
  private scriptErrorHandler: ScriptErrorHandler
  private lastScriptSuggestion: { originalCommand: string, suggestion: string, timestamp: number } | null = null

  // Getter for testing access
  get testHookManager(): HookManager {
    return this.hookManager
  }

  // Sync pipefail state with command executor
  syncPipefailToExecutor(enabled: boolean): void {
    this.commandExecutor.setPipefail(enabled)
  }

  private rl: Readline.Interface | null = null
  private running = false
  // Public method to check if shell is in interactive session
  isInteractive(): boolean {
    return this.interactiveSession
  }

  // Get current input for testing (delegates to AutoSuggestInput)
  getCurrentInputForTesting(): string {
    if (this.autoSuggestInput && typeof this.autoSuggestInput.getCurrentInput === 'function') {
      return this.autoSuggestInput.getCurrentInput()
    }
    return ''
  }

  private interactiveSession = false
  private promptPreRendered = false

  constructor(config?: KrustyConfig) {
    super()

    // Use defaultConfig from src/config to preserve exact equality in tests
    this.config = config || defaultConfig
    // Ensure plugins array exists
    if (!this.config.plugins)
      this.config.plugins = []

    // Default plugins are injected by PluginManager at load time.
    this.cwd = process.cwd()
    // Convert process.env to Record<string, string> by filtering out undefined values
    this.environment = Object.fromEntries(
      Object.entries(process.env).filter(([_, value]) => value !== undefined),
    ) as Record<string, string>

    // Override with config environment if provided
    if (this.config.environment) {
      Object.assign(this.environment, this.config.environment)
    }
    this.history = []
    // Honor configured history settings
    this.historyManager = new HistoryManager(this.config.history)
    // Initialize aliases from config (tests expect constructor to honor provided aliases)
    this.aliases = { ...(this.config.aliases || {}) }
    this.builtins = createBuiltins()

    // Skip history manager initialization in tests to prevent hanging
    if (process.env.NODE_ENV !== 'test') {
      this.historyManager.initialize().catch(console.error)
    }

    this.parser = new CommandParser()

    // Skip complex initialization in test environment to prevent hanging
    if (process.env.NODE_ENV === 'test') {
      // Minimal initialization for tests
      this.themeManager = {} as any
      this.promptRenderer = {} as any
      this.systemInfoProvider = {} as any
      this.gitInfoProvider = {} as any
      this.completionProvider = new CompletionProvider(this)
      this.pluginManager = {
        shutdown: async () => {},
        getPluginCompletions: () => [],
        loadPlugins: async () => {},
        getPlugin: () => undefined,
      } as any
      // Initialize real HookManager even in test mode since hook tests depend on it
      this.hookManager = new HookManager(this, this.config || defaultConfig)
      this.log = { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} } as any
      this.autoSuggestInput = {} as any
      // Initialize real JobManager even in test mode since tests depend on it
      this.jobManager = new JobManager(this)
      // Initialize real ScriptManager even in test mode since script tests depend on it
      this.scriptManager = new ScriptManager(this)
    }
    else {
      this.themeManager = new ThemeManager(this.config.theme)
      this.promptRenderer = new PromptRenderer(this.config)
      this.systemInfoProvider = new SystemInfoProvider()
      this.gitInfoProvider = new GitInfoProvider()
      this.completionProvider = new CompletionProvider(this)
      this.pluginManager = new PluginManager(this, this.config)
      this.hookManager = new HookManager(this, this.config)
      this.log = new Logger(this.config.verbose, 'shell')
      this.autoSuggestInput = new AutoSuggestInput(this)
      // Let AutoSuggestInput know that the shell manages the prompt. This ensures
      // input updates do not clear/overwrite the prompt and fixes cases where the
      // prompt might not be visible due to display updates.
      this.autoSuggestInput.setShellMode(true)
      this.jobManager = new JobManager(this)
      this.scriptManager = new ScriptManager(this)
    }

    // Initialize new modular components
    this.commandExecutor = new CommandExecutor(this.config, this.cwd, this.environment, this.log)
    this.replManager = new ReplManager(this, this.autoSuggestInput, this.log)
    this.aliasManager = new AliasManager(this.aliases, this.parser, this.cwd, this.environment)
    this.builtinManager = new BuiltinManager(this)
    this.scriptExecutor = new ScriptExecutor(this)
    this.commandChainExecutor = new CommandChainExecutor(this)
    this.scriptErrorHandler = new ScriptErrorHandler(this)

    // Apply expansion cache limits from config (if any)
    try {
      const limits = this.config.expansion?.cacheLimits
      if (limits) {
        ExpansionUtils.setCacheLimits(limits)
      }
    }
    catch {}

    // Load history
    this.loadHistory()
  }

  async execute(command: string, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, bypassScriptDetection?: boolean, aliasDepth?: number }): Promise<CommandResult> {
    // Execute command:before hooks
    await this.hookManager.executeHooks('command:before', { command })

    // Add to history (before execution to capture the command even if it fails)
    this.addToHistory(command)

    // Delegate to CommandChainExecutor
    const result = await this.commandChainExecutor.executeCommandChain(command, options)

    // Process bun run errors with enhanced suggestions
    if (result.exitCode !== 0 && result.stderr && command.trim().startsWith('bun run ')) {
      const scriptName = command.trim().replace(/^bun run\s+/, '').split(' ')[0]
      const errorResult = this.scriptErrorHandler.handleBunRunError(result.stderr, scriptName)
      result.stderr = errorResult.stderr

      // Store suggestion for potential use by 'yes' builtin
      if (errorResult.suggestion) {
        this.lastScriptSuggestion = {
          originalCommand: command.trim(),
          suggestion: errorResult.suggestion,
          timestamp: Date.now()
        }
      }
    }

    // Execute command:after hooks
    await this.hookManager.executeHooks('command:after', { command, result })

    return result
  }

  async executeCommandChain(parsed: ParsedCommand | string, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }): Promise<CommandResult> {
    // Handle both ParsedCommand objects and string inputs for backward compatibility
    if (typeof parsed === 'string') {
      return await this.commandChainExecutor.executeCommandChain(parsed, options)
    }

    // For ParsedCommand objects with multiple commands, execute them as a pipeline
    if (parsed.commands && parsed.commands.length > 0) {
      if (parsed.commands.length === 1) {
        // Single command - execute directly
        return await this.executeSingleCommand(parsed.commands[0], undefined, options)
      }
      else {
        // Multiple commands - execute as pipeline
        return await this.executePipedCommands(parsed.commands, options)
      }
    }

    // Fallback for empty commands
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  async executeParsedCommand(parsed: ParsedCommand): Promise<number> {
    const result = await this.executeCommandChain(parsed)
    return result.exitCode
  }

  async executePipedCommands(commands: any[], _options?: { bypassAliases?: boolean, bypassFunctions?: boolean }): Promise<CommandResult> {
    // For now, delegate to the command executor
    return await this.commandExecutor.executePipedCommands(commands)
  }

  async executeCommand(command: string, args: string[] = []): Promise<CommandResult> {
    // Create a command object that matches the expected format
    const cmd = { name: command, args }
    return this.executeSingleCommand(cmd)
  }

  async parseCommand(input: string): Promise<ParsedCommand> {
    return await this.parser.parse(input, this)
  }

  changeDirectory(path: string): boolean {
    try {
      let targetPath = path

      // Handle tilde expansion
      if (targetPath.startsWith('~')) {
        targetPath = targetPath.replace('~', homedir())
      }

      // Handle relative paths
      if (!targetPath.startsWith('/')) {
        targetPath = resolve(this.cwd, targetPath)
      }

      // Check if directory exists and is accessible
      if (!existsSync(targetPath)) {
        return false
      }

      const stat = statSync(targetPath)
      if (!stat.isDirectory()) {
        return false
      }

      // Change directory and maintain PWD/OLDPWD
      const prev = this.cwd
      process.chdir(targetPath)
      this.cwd = targetPath
      try {
        // Track previous directory for `cd -`
        ;(this as any)._prevDir = prev
        // Update env vars similar to POSIX shells
        this.environment.OLDPWD = prev
        this.environment.PWD = this.cwd
        process.env.OLDPWD = prev
        process.env.PWD = this.cwd
      }
      catch {}
      return true
    }
    catch {
      return false
    }
  }

  async start(interactive: boolean = true): Promise<void> {
    if (this.running)
      return

    // Skip any interactive/session setup during tests or when explicitly disabled.
    if (!interactive || process.env.NODE_ENV === 'test' || process.env.BUN_ENV === 'test') {
      this.running = false
      return
    }

    // Initialize modules
    const { initializeModules } = await import('../modules/registry')
    initializeModules(this.config.modules)

    // Execute shell:init hooks
    await this.hookManager.executeHooks('shell:init', {})

    // Load plugins
    await this.pluginManager.loadPlugins()

    this.running = true

    // Execute shell:start hooks
    await this.hookManager.executeHooks('shell:start', {})

    // Delegate to REPL manager
    await this.replManager.start(interactive)
  }

  stop(): void {
    this.running = false
    this.replManager.stop()

    try {
      if (this.rl) {
        this.rl.close()
        this.rl = null
      }
    }
    catch (error) {
      this.log.error('Error closing readline interface:', error)
    }

    try {
      this.saveHistory()
    }
    catch (error) {
      this.log.error('Error saving history:', error)
    }

    // Shutdown job manager
    try {
      this.jobManager.shutdown()
    }
    catch (error) {
      this.log.error('Error shutting down job manager:', error)
    }

    // Execute shell:stop hooks
    this.hookManager.executeHooks('shell:stop', {}).catch(err => this.log.error('shell:stop hook error:', err))

    // Shutdown plugins
    this.pluginManager.shutdown().catch(err => this.log.error('plugin shutdown error:', err))

    // Execute shell:exit hooks
    this.hookManager.executeHooks('shell:exit', {}).catch(err => this.log.error('shell:exit hook error:', err))
  }

  async renderPrompt(): Promise<string> {
    // Execute prompt:before hooks
    await this.hookManager.executeHooks('prompt:before', {})

    const systemInfo = await this.systemInfoProvider.getSystemInfo()
    const gitInfo = await this.gitInfoProvider.getGitInfo(this.cwd)
    const prompt = await this.promptRenderer.render(this.cwd, systemInfo, gitInfo, this.lastExitCode, this.lastCommandDurationMs)
    // Clear duration so it only shows once after a command
    this.lastCommandDurationMs = 0

    // Execute prompt:after hooks
    await this.hookManager.executeHooks('prompt:after', { prompt })

    return prompt
  }

  addToHistory(command: string): void {
    this.historyManager.add(command)
    this.history = this.historyManager.getHistory()

    // Keep shared history in sync so components using the singleton see latest entries
    try {
      sharedHistory.add(command)
    }
    catch {}

    // Execute history:add hooks
    this.hookManager.executeHooks('history:add', { command }).catch(err => this.log.error('history:add hook error:', err))
  }

  searchHistory(query: string): string[] {
    // Execute history:search hooks
    this.hookManager.executeHooks('history:search', { query }).catch(err => this.log.error('history:search hook error:', err))

    return this.historyManager.search(query)
  }

  getCompletions(input: string, cursor: number): import('../types').CompletionResults {
    try {
      // Execute completion:before hooks
      this.hookManager.executeHooks('completion:before', { input, cursor })
        .catch(err => this.log.error('completion:before hook error:', err))

      // Get completions from the completion provider
      let completions: any = []

      try {
        completions = this.completionProvider.getCompletions(input, cursor)
      }
      catch (error) {
        this.log.error('Error in completion provider:', error)
      }

      // Check if completions are grouped (CompletionGroup[])
      const isGrouped = Array.isArray(completions)
        && completions.length > 0
        && completions[0]
        && typeof completions[0] === 'object'
        && 'title' in completions[0]
        && 'items' in completions[0]

      // If grouped, return as-is (don't flatten or process further)
      if (isGrouped) {
        // Execute completion:after hooks
        this.hookManager.executeHooks('completion:after', { input, cursor, completions })
          .catch(err => this.log.error('completion:after hook error:', err))
        return completions
      }

      // Always collect plugin completions (flat strings)
      let pluginCompletions: string[] = []
      if (this.pluginManager?.getPluginCompletions) {
        try {
          pluginCompletions = this.pluginManager.getPluginCompletions(input, cursor) || []
        }
        catch (error) {
          this.log.error('Error getting plugin completions:', error)
        }
      }

      // Merge flat plugin completions into flat core list
      if (pluginCompletions.length > 0) {
        completions = [...new Set([...(Array.isArray(completions) ? completions : []), ...pluginCompletions])]
      }

      // Filter out empty strings and sort alphabetically (case-insensitive)
      const allSorted = completions
        .filter((c: string) => c && c.trim().length > 0)
        .sort((a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: 'base' }))

      // Enforce max suggestions limit
      const max = this.config.completion?.maxSuggestions ?? 10
      completions = allSorted.length > max ? allSorted.slice(0, max) : allSorted

      // Execute completion:after hooks
      this.hookManager.executeHooks('completion:after', { input, cursor, completions })
        .catch(err => this.log.error('completion:after hook error:', err))

      return completions
    }
    catch (error) {
      this.log.error('Error in getCompletions:', error)
      return []
    }
  }

  // Job management methods - delegated to JobManager
  addJob(command: string, childProcess?: ChildProcess, background = false): number {
    return this.jobManager.addJob(command, childProcess, background)
  }

  removeJob(jobId: number, force = false): boolean {
    return this.jobManager.removeJob(jobId, force)
  }

  getJob(id: number): Job | undefined {
    return this.jobManager.getJob(id)
  }

  getJobs(): Job[] {
    this.jobs = this.jobManager.getJobs() // Keep compatibility property in sync
    return this.jobs
  }

  setJobStatus(id: number, status: 'running' | 'stopped' | 'done'): boolean {
    const job = this.jobManager.getJob(id)
    if (job) {
      job.status = status
      return true
    }
    return false
  }

  // Additional job control methods
  suspendJob(jobId: number): boolean {
    return this.jobManager.suspendJob(jobId)
  }

  resumeJobBackground(jobId: number): boolean {
    return this.jobManager.resumeJobBackground(jobId)
  }

  resumeJobForeground(jobId: number): boolean {
    return this.jobManager.resumeJobForeground(jobId)
  }

  terminateJob(jobId: number, signal = 'SIGTERM'): boolean {
    return this.jobManager.terminateJob(jobId, signal)
  }

  waitForJob(jobId: number): Promise<Job | null> {
    return this.jobManager.waitForJob(jobId)
  }

  // Public proxies for plugin operations (for tests and external callers)
  async loadPlugins(): Promise<void> {
    await this.pluginManager.loadPlugins()
  }

  getPlugin(name: string): Plugin | undefined {
    return this.pluginManager.getPlugin(name)
  }

  // Public proxies for theme operations
  getThemeManager(): ThemeManager {
    return this.themeManager
  }

  setTheme(themeConfig: ThemeConfig): void {
    this.themeManager = new ThemeManager(themeConfig)
    this.config.theme = themeConfig
  }

  // Reload configuration, hooks, and plugins at runtime
  public async reload(): Promise<CommandResult> {
    const start = performance.now()
    try {
      // Load latest config from disk
      const oldConfig = this.config
      const newConfig = await loadKrustyConfig()

      // Validate before applying
      const { valid, errors, warnings } = validateKrustyConfig(newConfig)
      if (!valid) {
        // Log validation errors and abort reload
        this.log.error('Reload aborted: invalid configuration')
        for (const e of errors) {
          this.log.error(` - ${e}`)
        }
        const stderr = `${['reload: invalid configuration', ...errors.map(e => ` - ${e}`)].join('\n')}\n`
        return { exitCode: 1, stdout: '', stderr, duration: performance.now() - start }
      }

      // Log warnings if any
      if (warnings && warnings.length) {
        this.log.warn('Configuration warnings:')
        for (const w of warnings) this.log.warn(` - ${w}`)
      }

      // Compute and log a diff for visibility
      try {
        const diff = diffKrustyConfigs(oldConfig, newConfig)
        if (diff.length) {
          this.log.info('Config changes on reload:')
          for (const line of diff) this.log.info(` - ${line}`)
        }
        else {
          this.log.info('No config changes detected.')
        }
      }
      catch {}

      // Apply environment: start from current process.env to keep runtime updates, then overlay new config
      this.environment = Object.fromEntries(
        Object.entries(process.env).filter(([_, v]) => v !== undefined),
      ) as Record<string, string>
      if (newConfig.environment) {
        for (const [k, v] of Object.entries(newConfig.environment)) {
          if (v === undefined)
            continue
          this.environment[k] = v
          process.env[k] = v
        }
      }

      // Replace config and dependent components
      this.config = newConfig
      this.aliases = { ...this.config.aliases }
      this.promptRenderer = new PromptRenderer(this.config)

      // Recreate history manager with new settings but keep in-memory history
      this.historyManager = new HistoryManager(this.config.history)
      this.loadHistory()

      // Recreate hooks with new config
      this.hookManager = new HookManager(this, this.config)

      // Apply expansion cache limits and clear caches on reload
      try {
        const limits = this.config.expansion?.cacheLimits
        if (limits) {
          ExpansionUtils.setCacheLimits(limits)
        }
      }
      catch {}
      try {
        ExpansionUtils.clearCaches()
      }
      catch {}

      // Restart plugins to reflect new config
      await this.pluginManager.shutdown()
      this.pluginManager = new PluginManager(this, this.config)
      await this.pluginManager.loadPlugins()

      // Reinitialize modules using new config
      try {
        const { initializeModules } = await import('../modules/registry')
        initializeModules(this.config.modules)
      }
      catch (e) {
        this.log.warn('Module reinitialization failed:', e)
      }

      // Stop the old REPL, re-create with new config, and restart it.
      this.replManager.stop()
      this.autoSuggestInput = new AutoSuggestInput(this)
      this.autoSuggestInput.setShellMode(true)
      this.replManager = new ReplManager(this, this.autoSuggestInput, this.log)
      this.replManager.start(this.interactiveSession)

      // Execute a reload hook event if configured
      await this.hookManager.executeHooks('shell:reload', {})

      // Return a success message, but the new REPL will actually handle the prompt.
      return {
        exitCode: 0,
        stdout: 'Configuration reloaded successfully\n',
        stderr: '',
        duration: performance.now() - start,
      }
    }
    catch (error) {
      const msg = error instanceof Error ? error.message : String(error)
      return {
        exitCode: 1,
        stdout: '',
        stderr: `reload: ${msg}\n`,
        duration: performance.now() - start,
      }
    }
  }

  private loadHistory(): void {
    try {
      this.history = this.historyManager.getHistory()
    }
    catch (error) {
      if (this.config.verbose) {
        this.log.warn('Failed to load history:', error)
      }
    }
  }

  private saveHistory(): void {
    try {
      this.historyManager.save()
    }
    catch (error) {
      if (this.config.verbose) {
        this.log.warn('Failed to save history:', error)
      }
    }
  }

  private async executeSingleCommand(command: any, redirections?: any[], options?: { bypassAliases?: boolean, bypassFunctions?: boolean, aliasDepth?: number }): Promise<CommandResult> {
    if (!command?.name) {
      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: 0,
      }
    }

    // Prefer builtins over aliases to ensure builtin behavior is not shadowed by alias names
    if (!options?.bypassFunctions && this.builtins.has(command.name)) {
      const builtin = this.builtins.get(command.name)!

      // Handle background processes for builtins
      if (command.background) {
        // For background builtins, execute asynchronously and add to jobs
        const jobId = this.addJob(command.raw)

        // Execute builtin in background (don't await)
        builtin.execute(command.args, this).then(async (_result) => {
          // Mark job as done
          this.setJobStatus(jobId, 'done')
        }).catch(() => {
          this.setJobStatus(jobId, 'done')
        })

        return {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: 0,
        }
      }

      // xtrace for builtins: print command before execution
      if (this.xtrace) {
        const formatArg = (a: string) => (/\s/.test(a) ? `"${a}"` : a)
        const argsStr = Array.isArray(command.args) ? command.args.map((a: string) => formatArg(a)).join(' ') : ''
        const line = `+ ${command.name}${argsStr ? ` ${argsStr}` : ''}`
        this.lastXtraceLine = line
        try {
          process.stderr.write(`${line}\n`)
        }
        catch {}
      }

      // Process arguments to remove quotes for builtin commands (except alias which handles quotes itself)
      const processedArgs = command.name === 'alias'
        ? command.args
        : command.args.map((arg: string) => this.processAliasArgument(arg))
      const result = await builtin.execute(processedArgs, this)

      return result
    }

    // Check for alias expansion (only if not bypassing aliases)
    if (!options?.bypassAliases && command.name in this.aliases) {
      const aliasDepth = (options?.aliasDepth || 0) + 1

      // Prevent infinite recursion with depth limit
      if (aliasDepth > 10) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `krusty: alias expansion depth exceeded for '${command.name}'\n`,
          duration: 0,
          streamed: false,
        }
      }

      // Use AliasManager for proper alias expansion
      const expandedCommand = await this.aliasManager.expandAlias(command)
      if (expandedCommand && expandedCommand !== command) {
        // Execute the expanded alias command (allow nested aliases with depth tracking)
        return await this.executeCommandChain(expandedCommand, {
          bypassAliases: options?.bypassAliases,
          bypassFunctions: options?.bypassFunctions,
          aliasDepth,
        })
      }
    }

    // Execute external command using CommandExecutor
    return this.commandExecutor.executeExternalCommand(command, redirections)
  }

  /**
   * Processes an argument from alias expansion by removing quotes
   * @param arg The argument to process
   * @returns The processed argument
   */
  private processAliasArgument(arg: string): string {
    if (!arg)
      return arg

    // Handle quoted strings
    if ((arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))) {
      return arg.slice(1, -1)
    }

    // Handle escaped characters
    return arg.replace(/\\(.)/g, '$1')
  }

  private needsInteractiveTTY(command: any, redirections?: any[]): boolean {
    // Interactive commands that need TTY access
    const interactiveCommands = ['vim', 'nano', 'emacs', 'less', 'more', 'man', 'top', 'htop', 'ssh', 'sudo']

    // Don't use TTY if backgrounded or has redirections
    if (command.background || (redirections && redirections.length > 0)) {
      return false
    }

    return interactiveCommands.includes(command.name)
  }
}
