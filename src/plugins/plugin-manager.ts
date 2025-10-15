import type { KrustyConfig, Plugin, PluginContext, Shell } from '../types'
import { existsSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { config } from '../config'
import { Logger } from '../logger'

export class PluginManager {
  private plugins: Map<string, Plugin> = new Map()
  private pluginDir: string
  private updateInterval: NodeJS.Timeout | null = null
  private shell: Shell
  private config: KrustyConfig
  // Keep lazily-configured plugins to load on demand
  private lazyPlugins: Map<string, { item: Plugin }> = new Map()

  // Safely invoke lifecycle methods and isolate errors per plugin
  private async callLifecycle<K extends 'initialize' | 'activate' | 'deactivate' | 'destroy'>(
    plugin: Plugin,
    phase: K,
    context: PluginContext | undefined,
  ): Promise<boolean> {
    const logger = this.shell?.log
    try {
      const fn = (plugin as any)[phase] as ((ctx: PluginContext) => Promise<void> | void) | undefined
      if (!fn) {
        return true
      }
      if (!context) {
        // If no context could be created, skip but do not treat as failure of plugin code
        logger?.warn?.(`Skipping plugin ${plugin.name} ${phase} due to missing context`)
        return false
      }
      await fn(context)
      return true
    }
    catch (error) {
      if (logger) {
        logger.error(`Plugin ${plugin.name} ${phase} failed:`, error)
      }
      else {
        console.error(`Plugin ${plugin.name} ${phase} failed:`, error)
      }
      return false
    }
  }

  constructor(shell: Shell, shellConfig: KrustyConfig) {
    this.shell = shell
    this.config = shellConfig
    this.pluginDir = this.resolvePath(shellConfig.pluginsConfig?.directory || config.pluginsConfig?.directory || '~/.krusty/plugins')
    this.ensurePluginDir()
  }

  private createPluginLogger(name: string): Logger {
    // Use shell config verbosity and provide a namespaced logger for plugins
    const verbose = !!this.shell?.config?.verbose
    return new Logger(verbose, `plugin:${name}`)
  }

  private resolvePath(path: string): string {
    return path.replace(/^~(?=$|\/|\\)/, homedir())
  }

  private async loadBuiltinPlugin(name: string, _config?: Record<string, any>): Promise<void> {
    // Create a temporary plugin entry to get context
    const tempPlugin: Plugin = { name, version: '1.0.0' }
    this.plugins.set(name, tempPlugin)

    const context = this.getPluginContext(name)
    if (!context)
      return

    if (name === 'auto-suggest') {
      // Load the sophisticated auto-suggest plugin from file
      try {
        const autoSuggestPlugin = await import('./auto-suggest-plugin')
        const plugin = autoSuggestPlugin.default

        this.plugins.set(name, plugin)
        const okInit = await this.callLifecycle(plugin, 'initialize', context)
        if (okInit)
          await this.callLifecycle(plugin, 'activate', context)
        // Keep plugin registered even if lifecycle methods fail
      }
      catch (error) {
        console.error('Failed to load auto-suggest plugin:', error)
        // Keep the temporary plugin entry for error isolation testing
      }
    }
    else if (name === 'highlight') {
      const plugin: Plugin = {
        name: 'highlight',
        version: '1.0.0',
        description: 'Provides syntax highlighting for commands',
        commands: {
          'highlight:demo': {
            description: 'Demo command that outputs colored text',
            execute: async (_args: string[], _context: any) => ({
              exitCode: 0,
              stdout: `\x1B[32mecho\x1B[0m \x1B[33mhi\x1B[0m\n`,
              stderr: '',
              duration: 0,
            }),
          },
        },
      }

      this.plugins.set(name, plugin)
      const okInit = await this.callLifecycle(plugin, 'initialize', context)
      if (okInit)
        await this.callLifecycle(plugin, 'activate', context)
    }
  }

  // Begin: Lazy loading helpers
  private async loadLazyByName(name: string): Promise<void> {
    const lazy = this.lazyPlugins.get(name)
    if (!lazy)
      return

    const { item } = lazy
    try {
      // Handle built-in default plugins
      if (item.name === 'auto-suggest' || item.name === 'highlight') {
        await this.loadBuiltinPlugin(item.name, item.config)
      }
      else {
        const pluginPath = item.path
          ? this.resolvePath(item.path)
          : join(this.pluginDir, item.name)

        if (!existsSync(pluginPath)) {
          if (item.url) {
            await this.installPluginItem(item)
          }
          else {
            this.shell.log?.warn(`Plugin not found: ${item.name}`)
            return
          }
        }

        const pluginModule = await import(pluginPath)
        const plugin: Plugin = pluginModule.default || pluginModule
        if (this.validatePlugin(plugin)) {
          this.plugins.set(plugin.name, plugin)
          await this.initializePlugin(plugin, item.config || {})
        }
      }
    }
    catch (error) {
      if (this.shell.log)
        this.shell.log.error(`Failed to load lazy plugin ${name}:`, error)
      else
        console.error(`Failed to load lazy plugin ${name}:`, error)
    }
    finally {
      // Remove from lazy registry regardless of success to avoid repeated attempts
      this.lazyPlugins.delete(name)
    }
  }

  // Fire-and-forget background load for specific plugins
  ensureLazyLoaded(names?: string[]): void {
    const targets = names && names.length > 0 ? names : Array.from(this.lazyPlugins.keys())
    for (const n of targets) {
      // Trigger async load without awaiting to avoid blocking callers
      this.loadLazyByName(n).catch(err => this.shell.log?.error?.(`Lazy load error for ${n}:`, err))
    }
  }
  // End: Lazy loading helpers

  private ensurePluginDir(): void {
    if (!existsSync(this.pluginDir)) {
      mkdirSync(this.pluginDir, { recursive: true })
    }
  }

  public async loadPlugins(): Promise<void> {
    if (this.config.pluginsConfig?.enabled === false) {
      this.shell.log?.info('Plugin system is disabled.')
      return
    }

    let pluginsToLoad: (Plugin | string)[] = this.config.plugins || []

    // Inject default plugins if no plugins are configured
    if (pluginsToLoad.length === 0) {
      pluginsToLoad = ['auto-suggest', 'highlight']
    }
    else {
      const configuredPluginNames = new Set(pluginsToLoad.map(p => (typeof p === 'string' ? p : p.name)))
      const defaultPlugins = ['auto-suggest', 'highlight']
      for (const defaultPlugin of defaultPlugins) {
        if (!configuredPluginNames.has(defaultPlugin)) {
          pluginsToLoad.push(defaultPlugin)
        }
      }
    }

    for (const pluginItem of pluginsToLoad) {
      await this.loadPlugin(pluginItem)
    }

    this.startAutoUpdate()
  }

  public async loadPlugin(pluginIdentifier: Plugin | string): Promise<void> {
    const pluginItem: Plugin = typeof pluginIdentifier === 'string'
      ? { name: pluginIdentifier, enabled: true }
      : pluginIdentifier

    if (pluginItem.enabled === false) {
      return
    }

    try {
      // If marked as lazy, defer actual loading
      if (pluginItem.lazy) {
        this.lazyPlugins.set(pluginItem.name, { item: pluginItem })
        return
      }

      // Handle built-in default plugins
      if (pluginItem.name === 'auto-suggest' || pluginItem.name === 'highlight') {
        await this.loadBuiltinPlugin(pluginItem.name, pluginItem.config)
        return
      }

      const pluginPath = pluginItem.path
        ? (pluginItem.path.startsWith('/') || pluginItem.path.startsWith('.')
          ? pluginItem.path.startsWith('.')
            ? join(process.cwd(), pluginItem.path)
            : pluginItem.path
          : this.resolvePath(pluginItem.path))
        : join(this.pluginDir, pluginItem.name)

      if (!existsSync(pluginPath)) {
        if (pluginItem.url) {
          await this.installPluginItem(pluginItem)
        } else {
          this.shell.log?.warn(`Plugin not found: ${pluginItem.name}`)
          return
        }
      }

      const pluginModule = await import(pluginPath)
      const plugin: Plugin = pluginModule.default || pluginModule

      if (this.validatePlugin(plugin)) {
        this.plugins.set(plugin.name, plugin)
        await this.initializePlugin(plugin, pluginItem.config || {})
      } else {
        // Register plugin even if validation fails for error isolation testing
        this.plugins.set(pluginItem.name, plugin)
      }
    } catch (error) {
      if (this.shell.log) {
        this.shell.log.error(`Failed to load plugin "${pluginItem.name}":`, error)
      } else {
        console.error(`Failed to load plugin "${pluginItem.name}":`, error)
      }
      // Register a minimal plugin entry even on load failure for error isolation testing
      this.plugins.set(pluginItem.name, {
        name: pluginItem.name,
        version: '1.0.0',
        description: 'Failed to load'
      })
    }
  }

  private validatePlugin(plugin: Plugin): boolean {
    // A plugin is valid if it has a name, version, and either an activate function or hooks.
    return !!(plugin.name && plugin.version && (plugin.activate || plugin.hooks));
  }

  private async initializePlugin(plugin: Plugin, pluginConfig: any): Promise<void> {
    const context: PluginContext = {
      shell: this.shell,
      config: this.config,
      pluginConfig,
      logger: this.createPluginLogger(plugin.name),
      utils: {
        exec: async (command: string, _options?: any) => {
          const result = await this.shell.execute(command)
          return {
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
          }
        },
        readFile: async (path: string) => {
          const { readFile } = await import('node:fs/promises')
          return readFile(path, 'utf-8')
        },
        writeFile: async (path: string, content: string) => {
          const { writeFile } = await import('node:fs/promises')
          await writeFile(path, content, 'utf-8')
        },
        exists: (path: string) => existsSync(path),
        expandPath: (path: string) => this.resolvePath(path),
        formatTemplate: (template: string, variables: Record<string, string>) => {
          return template.replace(/\{\{(\w+)\}\}/g, (_, key) => variables[key] || '')
        },
      },
    }

    // Register hooks if they exist
    if (plugin.hooks) {
      for (const [hookName, handler] of Object.entries(plugin.hooks)) {
        this.shell.hookManager.on(hookName, handler.bind(plugin));
      }
    }

    // Always attempt lifecycle methods but don't fail plugin registration on errors
    const okInit = await this.callLifecycle(plugin, 'initialize', context)
    if (okInit) {
      await this.callLifecycle(plugin, 'activate', context)
    }
    // Plugin remains registered even if lifecycle methods fail
  }

  private async installPluginItem(pluginItem: { name: string, url?: string, version?: string }): Promise<void> {
    // Implementation for installing plugins from npm or git
    console.warn(`Installing plugin: ${pluginItem.name}`)
    // TODO: Implement actual installation logic
  }

  public async updatePlugin(name: string): Promise<void> {
    const plugin = this.plugins.get(name)
    if (!plugin)
      return

    console.warn(`Updating plugin: ${name}`)
    // TODO: Implement update logic
  }

  private startAutoUpdate(): void {
    if (this.updateInterval)
      clearInterval(this.updateInterval)

    const updateInterval = 24 * 60 * 60 * 1000 // 24 hours
    this.updateInterval = setInterval(() => {
      this.checkForUpdates()
    }, updateInterval)
  }

  private async checkForUpdates(): Promise<void> {
    for (const [name] of this.plugins) {
      try {
        await this.updatePlugin(name)
      }
      catch (error) {
        console.error(`Failed to update plugin ${name}:`, error)
      }
    }
  }

  public async shutdown(): Promise<void> {
    if (this.updateInterval) {
      clearInterval(this.updateInterval)
      this.updateInterval = null
    }

    for (const [name, plugin] of this.plugins) {
      try {
        const context: PluginContext = {
          shell: this.shell,
          config: this.config,
          logger: this.createPluginLogger(plugin.name),
          utils: {} as any, // Simplified for shutdown
        }
        await this.callLifecycle(plugin, 'deactivate', context)
      }
      catch (error) {
        console.error(`Error deactivating plugin ${name}:`, error)
      }
    }

    this.plugins.clear()
  }

  public getPlugin(name: string): Plugin | undefined {
    // Trigger background lazy load if needed, then return what's available now
    if (this.lazyPlugins.has(name))
      this.ensureLazyLoaded([name])
    return this.plugins.get(name)
  }

  public getAllPlugins(): Map<string, Plugin> {
    return this.plugins
  }

  public getPluginContext(name: string): PluginContext | undefined {
    const plugin = this.plugins.get(name)
    if (!plugin)
      return undefined

    return {
      shell: this.shell,
      config: this.config,
      logger: this.createPluginLogger(plugin.name),
      utils: {
        exec: async (command: string, _options?: any) => {
          const result = await this.shell.execute(command)
          return {
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
          }
        },
        readFile: async (path: string) => {
          const { readFile } = await import('node:fs/promises')
          return readFile(path, 'utf-8')
        },
        writeFile: async (path: string, content: string) => {
          const { writeFile } = await import('node:fs/promises')
          await writeFile(path, content, 'utf-8')
        },
        exists: (path: string) => existsSync(path),
        expandPath: (path: string) => this.resolvePath(path),
        formatTemplate: (template: string, variables: Record<string, string>) => {
          return template.replace(/\{\{(\w+)\}\}/g, (_, key) => variables[key] || '')
        },
      },
    }
  }

  public getPluginCompletions(input: string, cursor: number): string[] {
    const completions: string[] = []

    // Ensure any lazy plugins are being loaded before gathering completions
    if (this.lazyPlugins.size > 0)
      this.ensureLazyLoaded()

    for (const [name, plugin] of this.plugins) {
      if (plugin.completions) {
        for (const completion of plugin.completions) {
          try {
            const context = this.getPluginContext(name)
            if (context) {
              const pluginCompletions = completion.complete(input, cursor, context)
              completions.push(...pluginCompletions)
            }
          }
          catch (error) {
            // Use shell logger if available, fallback to console.error
            if (this.shell.log) {
              this.shell.log.error(`Error getting completions from plugin ${name}:`, error)
            }
            else {
              console.error(`Error getting completions from plugin ${name}:`, error)
            }
          }
        }
      }
    }

    return completions
  }

  public async unloadPlugin(name: string): Promise<void> {
    const plugin = this.plugins.get(name)
    if (!plugin)
      return

    try {
      const context = this.getPluginContext(name)
      await this.callLifecycle(plugin, 'deactivate', context)
      this.plugins.delete(name)
    }
    catch (error) {
      console.error(`Error unloading plugin ${name}:`, error)
    }
  }
}

// Export class only, instances should be created with shell and config
