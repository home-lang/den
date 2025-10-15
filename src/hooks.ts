import type {
  HookCondition,
  HookConfig,
  HookContext,
  HookHandler,
  HookResult,
  KrustyConfig,
  Shell,
} from './types'
import { execSync, spawn } from 'node:child_process'
import { existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { resolve } from 'node:path'
import process from 'node:process'

// Helper function to execute commands without shell dependency
function execCommand(command: string, options: { cwd?: string, env?: Record<string, string>, timeout?: number }): Promise<{ stdout: string, stderr: string }> {
  return new Promise((resolve, reject) => {
    // Check if this is a script file (starts with quotes and has executable extension)
    const isScript = command.startsWith('"') && (command.includes('.sh') || command.includes('.js') || command.includes('.py'))

    let cmd: string
    let args: string[]

    if (isScript) {
      // For script files, remove quotes and execute directly
      cmd = command.replace(/"/g, '')
      args = []
    }
    else {
      // Parse regular commands into parts - handle quoted arguments properly
      const parts = []
      let current = ''
      let inQuotes = false
      let quoteChar = ''

      for (let i = 0; i < command.length; i++) {
        const char = command[i]
        if (!inQuotes && (char === '"' || char === '\'')) {
          inQuotes = true
          quoteChar = char
        }
        else if (inQuotes && char === quoteChar) {
          inQuotes = false
          quoteChar = ''
        }
        else if (!inQuotes && char === ' ') {
          if (current.trim()) {
            parts.push(current.trim())
            current = ''
          }
        }
        else {
          current += char
        }
      }
      if (current.trim()) {
        parts.push(current.trim())
      }

      cmd = parts[0]
      args = parts.slice(1)
    }

    // Try to find the command in common locations if it's not an absolute path
    if (!cmd.startsWith('/')) {
      const commonPaths = ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']
      for (const path of commonPaths) {
        const fullPath = `${path}/${cmd}`
        try {
          if (statSync(fullPath).isFile()) {
            cmd = fullPath
            break
          }
        }
        catch {
          // Continue to next path
        }
      }
    }

    // Ensure we have a robust environment with proper PATH
    const env = {
      ...process.env,
      ...options.env,
      PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
      // Ensure shell is available for script execution
      SHELL: process.env.SHELL || '/bin/bash',
    }

    const child = spawn(cmd, args, {
      cwd: options.cwd || process.cwd(),
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''
    let timeoutId: NodeJS.Timeout | undefined
    let completed = false

    // Set up timeout if specified
    if (options.timeout) {
      timeoutId = setTimeout(() => {
        if (!completed) {
          completed = true
          child.kill('SIGKILL') // Use SIGKILL for more reliable termination
          reject(new Error(`Command timed out after ${options.timeout}ms`))
        }
      }, options.timeout)
    }

    child.stdout?.on('data', (data) => {
      stdout += data.toString()
    })

    child.stderr?.on('data', (data) => {
      stderr += data.toString()
    })

    child.on('close', (code) => {
      if (completed)
        return
      completed = true
      if (timeoutId)
        clearTimeout(timeoutId)

      if (code === 0) {
        resolve({ stdout, stderr })
      }
      else {
        const error = new Error(`Command failed with exit code ${code}`)
        ;(error as any).stdout = stdout
        ;(error as any).stderr = stderr
        reject(error)
      }
    })

    child.on('error', (error) => {
      if (completed)
        return
      completed = true
      if (timeoutId)
        clearTimeout(timeoutId)
      reject(error)
    })
  })
}

// Hook manager
export class HookManager {
  private hooks = new Map<string, RegisteredHook[]>()
  private programmaticHooks = new Map<string, HookHandler[]>()
  private executing = new Set<string>()

  /**
   * Programmatically register a hook handler.
   * @param hookName The name of the hook to register.
   * @param callback The handler to execute when the hook is triggered.
   * @returns A function to unregister the hook.
   */
  public on<T = unknown>(hookName: string, callback: HookHandler<T>): () => void {
    if (!this.programmaticHooks.has(hookName)) {
      this.programmaticHooks.set(hookName, [])
    }
    this.programmaticHooks.get(hookName)!.push(callback as HookHandler)

    // Return a function to unregister the hook
    return () => {
      const hooks = this.programmaticHooks.get(hookName)
      if (hooks) {
        const index = hooks.indexOf(callback as HookHandler)
        if (index > -1) {
          hooks.splice(index, 1)
        }
      }
    }
  }

  constructor(private shell: Shell, private config: KrustyConfig) {
    this.loadHooks()
  }

  // Load hooks from configuration
  private loadHooks(): void {
    if (!this.config.hooks)
      return

    for (const [event, hookConfigs] of Object.entries(this.config.hooks)) {
      if (!hookConfigs)
        continue

      for (const hookConfig of hookConfigs) {
        if (hookConfig.enabled === false)
          continue

        try {
          this.registerHook(event, hookConfig)
        }
        catch (error) {
          this.shell.log.error(`Failed to register hook for ${event}:`, error)
        }
      }
    }
  }

  // Register a hook
  registerHook(event: string, config: HookConfig): void {
    const registeredHook: RegisteredHook = {
      event,
      config,
      handler: this.createHookHandler(config),
      priority: config.priority || 0,
    }

    if (!this.hooks.has(event)) {
      this.hooks.set(event, [])
    }

    const hooks = this.hooks.get(event)!
    hooks.push(registeredHook)

    // Sort by priority (higher priority first)
    hooks.sort((a, b) => b.priority - a.priority)
  }

  // Create hook handler from configuration
  private createHookHandler(config: HookConfig): HookHandler {
    return async (context: HookContext): Promise<HookResult> => {
      try {
        // Check conditions
        if (config.conditions && !this.checkConditions(config.conditions, context)) {
          return { success: true }
        }

        let result: HookResult = { success: true }

        if (config.command) {
          result = await this.executeCommand(config.command, context, config.timeout)
        }
        else if (config.script) {
          result = await this.executeScript(config.script, context, config.timeout)
        }
        else if (config.function) {
          result = await this.executeFunction(config.function, context)
        }
        else if (config.plugin) {
          result = await this.executePluginHook(config.plugin, context)
        }

        return result
      }
      catch (error) {
        return {
          success: false,
          error: error instanceof Error ? error.message : String(error),
        }
      }
    }
  }

  // Execute command hook
  private async executeCommand(command: string, context: HookContext, timeout?: number): Promise<HookResult> {
    try {
      const expandedCommand = this.expandTemplate(command, context)
      const { stdout, stderr } = await execCommand(expandedCommand, {
        cwd: context.cwd || process.cwd(),
        timeout,
        env: {
          ...process.env,
          ...context.environment,
          EDITOR: 'true',
          GIT_EDITOR: 'true',
          VISUAL: 'true',
          GIT_ASKPASS: 'true',
          VSCODE_GIT_ASKPASS_NODE: '',
          VSCODE_GIT_ASKPASS_MAIN: '',
          VSCODE_GIT_ASKPASS_EXTRA_ARGS: '',
          VSCODE_GIT_IPC_HANDLE: '',
          PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        },
      })

      return {
        success: true,
        data: { stdout, stderr },
      }
    }
    catch (error: any) {
      return {
        success: false,
        error: error.message,
        data: { stdout: error.stdout || '', stderr: error.stderr || '' },
      }
    }
  }

  // Execute script hook
  private async executeScript(scriptPath: string, context: HookContext, timeout?: number): Promise<HookResult> {
    const expandedPath = this.expandPath(scriptPath)

    if (!existsSync(expandedPath)) {
      return {
        success: false,
        error: `Script not found: ${expandedPath}`,
      }
    }

    try {
      // Determine the interpreter based on file extension
      let command = `"${expandedPath}"`
      if (expandedPath.endsWith('.js')) {
        command = `node "${expandedPath}"`
      }
      else if (expandedPath.endsWith('.py')) {
        command = `python3 "${expandedPath}"`
      }
      else if (expandedPath.endsWith('.sh')) {
        command = `sh "${expandedPath}"`
      }

      const { stdout, stderr } = await execCommand(command, {
        cwd: context.cwd || process.cwd(),
        timeout,
        env: {
          ...process.env,
          ...context.environment,
          EDITOR: 'true',
          GIT_EDITOR: 'true',
          VISUAL: 'true',
          GIT_ASKPASS: 'true',
          VSCODE_GIT_ASKPASS_NODE: '',
          VSCODE_GIT_ASKPASS_MAIN: '',
          VSCODE_GIT_ASKPASS_EXTRA_ARGS: '',
          VSCODE_GIT_IPC_HANDLE: '',
          PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        },
      })
      return {
        success: true,
        data: { stdout, stderr },
      }
    }
    catch (error: any) {
      return {
        success: false,
        error: error.message,
        data: { stdout: error.stdout || '', stderr: error.stderr || '' },
      }
    }
  }

  // Execute function hook
  private async executeFunction(functionName: string, context: HookContext): Promise<HookResult> {
    try {
      // Look for function in global scope or loaded modules
      const func = (globalThis as any)[functionName]

      if (typeof func !== 'function') {
        return {
          success: false,
          error: `Function ${functionName} not found`,
        }
      }

      const result = await func(context)
      return result || { success: true }
    }
    catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  // Execute plugin hook
  private async executePluginHook(pluginName: string, context: HookContext): Promise<HookResult> {
    const pluginManager = (this.shell as any).pluginManager
    if (!pluginManager) {
      return {
        success: false,
        error: 'Plugin manager not available',
      }
    }

    const plugin = pluginManager.getPlugin(pluginName)
    if (!plugin) {
      return {
        success: false,
        error: `Plugin ${pluginName} not found`,
      }
    }

    const hookHandler = plugin.hooks?.[context.event]
    if (!hookHandler) {
      return {
        success: false,
        error: `Hook ${context.event} not found in plugin ${pluginName}`,
      }
    }

    try {
      return await hookHandler(context)
    }
    catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  // Check hook conditions
  private checkConditions(conditions: (HookCondition | string)[], context: HookContext): boolean {
    return conditions.every(condition => this.checkCondition(condition, context))
  }

  // Check single condition
  private checkCondition(condition: HookCondition | string, context: HookContext): boolean {
    // Handle string conditions (shell commands)
    if (typeof condition === 'string') {
      try {
        execSync(condition, {
          stdio: 'ignore',
          env: {
            ...process.env,
            PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
          },
        })
        return true
      }
      catch {
        return false
      }
    }

    // Handle object conditions
    const { type, value, operator = 'equals' } = condition
    let result = false

    switch (type) {
      case 'env': {
        const envValue = context.environment[value]
        result = !!envValue
        break
      }

      case 'file': {
        const filePath = this.expandPath(value)
        result = existsSync(filePath) && statSync(filePath).isFile()
        break
      }

      case 'directory': {
        const dirPath = this.expandPath(value)
        result = existsSync(dirPath) && statSync(dirPath).isDirectory()
        break
      }

      case 'command': {
        // For command conditions, we check if the command exists
        try {
          execSync(`which ${value}`, { stdio: 'ignore' })
          result = true
        }
        catch {
          result = false
        }
        break
      }

      case 'custom': {
        // Custom conditions can be implemented by plugins
        result = this.evaluateCustomCondition(value, context)
        break
      }
    }

    // Apply operator
    if (operator === 'not') {
      result = !result
    }

    return result
  }

  // Evaluate custom condition
  private evaluateCustomCondition(condition: string, context: HookContext): boolean {
    try {
      // Simple expression evaluation - in production, use a proper expression parser
      // eslint-disable-next-line no-new-func
      const func = new Function('context', `return ${condition}`)
      return !!func(context)
    }
    catch {
      return false
    }
  }

  // Execute hooks for an event
  async executeHooks(event: string, data: any = {}): Promise<HookResult[]> {
    const hooks = this.hooks.get(event)
    if (!hooks || hooks.length === 0) {
      return []
    }

    // Prevent recursive hook execution
    const executionKey = `${event}:${JSON.stringify(data)}`
    if (this.executing.has(executionKey)) {
      return []
    }

    this.executing.add(executionKey)

    try {
      const context: HookContext = {
        shell: this.shell,
        event,
        data,
        config: this.config,
        environment: Object.fromEntries(
          Object.entries({ ...process.env, ...this.shell.environment })
            .filter(([_, value]) => value !== undefined),
        ) as Record<string, string>,
        cwd: this.shell.cwd,
        timestamp: Date.now(),
      }

      const results: HookResult[] = []
      let _preventDefault = false
      let stopPropagation = false

      // Execute programmatic hooks first
      const programmaticHooks = this.programmaticHooks.get(event) || []
      for (const programmaticHook of programmaticHooks) {
        try {
          await programmaticHook(data)
        }
        catch (error) {
          this.shell.log.error(`Error in programmatic hook '${event}':`, error)
        }
      }

      // Execute all hooks that match the current context
      for (const hook of hooks) {
        if (stopPropagation)
          break

        // Check conditions before executing
        if (hook.config.conditions && !this.checkConditions(hook.config.conditions, context)) {
          continue
        }

        try {
          const timeout = hook.config.timeout || 5000
          const handlerResult = hook.handler(context)
          const result = await this.executeWithTimeout(
            Promise.resolve(handlerResult),
            timeout,
          )

          results.push(result)

          if (result.preventDefault) {
            _preventDefault = true
          }

          if (result.stopPropagation) {
            stopPropagation = true
          }

          // If hook failed and it's not async, stop execution
          if (!result.success && !hook.config.async) {
            break
          }
        }
        catch (error) {
          results.push({
            success: false,
            error: error instanceof Error ? error.message : String(error),
          })

          // Stop on error unless it's an async hook
          if (!hook.config.async) {
            break
          }
        }
      }

      return results
    }
    finally {
      this.executing.delete(executionKey)
    }
  }

  // Execute with timeout
  private async executeWithTimeout<T>(promise: Promise<T>, timeout: number): Promise<T> {
    return Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        setTimeout(() => reject(new Error('Hook execution timeout')), timeout)
      }),
    ])
  }

  // Expand template variables
  private expandTemplate(template: string, context: HookContext): string {
    return template.replace(/\{(\w+)\}/g, (match, key) => {
      switch (key) {
        case 'event': return context.event
        case 'cwd': return context.cwd
        case 'timestamp': return context.timestamp.toString()
        case 'data': return JSON.stringify(context.data)
        default:
          return context.environment[key] || match
      }
    })
  }

  // Expand file paths
  private expandPath(path: string): string {
    if (path.startsWith('~')) {
      return path.replace('~', homedir())
    }
    return resolve(path)
  }

  // Get registered hooks for an event
  getHooks(event: string): RegisteredHook[] {
    return this.hooks.get(event) || []
  }

  // Get all registered events
  getEvents(): string[] {
    return Array.from(this.hooks.keys())
  }

  // Remove hooks for an event
  removeHooks(event: string): void {
    this.hooks.delete(event)
  }

  // Clear all registered hooks
  public clear(): void {
    this.hooks.clear()
    this.programmaticHooks.clear()
  }
}

// Registered hook interface
interface RegisteredHook {
  event: string
  config: HookConfig
  handler: HookHandler
  priority: number
}

// Hook utilities
export class HookUtils {
  static createSimpleHook(command: string, priority = 0): HookConfig {
    return {
      command,
      priority,
      enabled: true,
    }
  }

  static createScriptHook(scriptPath: string, priority = 0): HookConfig {
    return {
      script: scriptPath,
      priority,
      enabled: true,
    }
  }

  static createConditionalHook(
    command: string,
    conditions: HookCondition[],
    priority = 0,
  ): HookConfig {
    return {
      command,
      conditions,
      priority,
      enabled: true,
    }
  }

  static createAsyncHook(command: string, timeout = 10000, priority = 0): HookConfig {
    return {
      command,
      async: true,
      timeout,
      priority,
      enabled: true,
    }
  }
}
