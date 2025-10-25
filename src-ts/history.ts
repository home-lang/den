import type { Interface } from 'node:readline'
import type { HistoryConfig } from './types'
import { existsSync, promises as fs, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { cwd, env, stdin, stdout } from 'node:process'
import { createInterface } from 'node:readline'

export class HistoryManager {
  private history: string[] = []
  private config: HistoryConfig
  private historyPath: string
  private isInitialized = false

  constructor(config?: HistoryConfig) {
    this.config = {
      maxEntries: 1000,
      file: '~/.krusty_history',
      ignoreDuplicates: true,
      ignoreSpace: true,
      searchMode: 'fuzzy',
      searchLimit: undefined,
      ...config,
    }
    // Resolve the history file path
    this.historyPath = this.resolvePath(this.config.file || '~/.krusty_history')

    // Load synchronously so history is available immediately to the shell
    // (prevents a race where the shell queries history before async init completes)
    try {
      this.load()
    }
    catch {
      // Non-fatal; proceed with async initialize
    }

    // Initialize asynchronously for any additional setup and to mark initialized
    this.initialize().catch(console.error)
  }

  async initialize(): Promise<void> {
    if (this.isInitialized)
      return

    try {
      // Ensure history directory exists
      const dir = dirname(this.historyPath)
      if (!existsSync(dir)) {
        await fs.mkdir(dir, { recursive: true })
      }

      // Load existing history
      if (existsSync(this.historyPath)) {
        const data = await fs.readFile(this.historyPath, 'utf-8')
        this.history = data.split('\n').filter(Boolean)
      }

      this.isInitialized = true
    }
    catch (error) {
      console.error('Failed to initialize history:', error)
      this.history = []
    }
  }

  async add(command: string): Promise<void> {
    // Skip empty commands
    if (!command.trim())
      return

    // Skip commands starting with space if configured
    if (this.config.ignoreSpace && command.startsWith(' '))
      return

    // Skip duplicates if configured
    if (this.config.ignoreDuplicates && this.history[this.history.length - 1] === command) {
      return
    }

    this.history.push(command)

    // Limit history size
    if (this.config.maxEntries && this.history.length > this.config.maxEntries) {
      this.history = this.history.slice(-this.config.maxEntries)
    }

    // Save history after each command
    await this.save()
  }

  getHistory(): string[] {
    return [...this.history]
  }

  async save(): Promise<void> {
    if (!this.isInitialized)
      return

    try {
      // Preserve full history including repeated commands
      await fs.writeFile(this.historyPath, `${this.history.join('\n')}\n`, 'utf-8')
    }
    catch (error) {
      console.error('Failed to save history:', error)
    }
  }

  // For readline integration
  getReadlineInterface(): Interface {
    return createInterface({
      input: stdin,
      output: stdout,
      history: this.history,
      historySize: this.config.maxEntries || 1000,
    })
  }

  search(query: string, limit?: number): string[] {
    if (!query.trim())
      return []

    const lowerQuery = query.toLowerCase()

    // Determine result limit
    const resultLimit = typeof limit === 'number' ? limit : this.config.searchLimit

    // Exact (substring) search
    if (this.config.searchMode === 'exact') {
      const results = this.history.filter(cmd =>
        cmd.toLowerCase().includes(lowerQuery),
      )
      return typeof resultLimit === 'number' ? results.slice(0, resultLimit) : results
    }

    // Startswith search
    if (this.config.searchMode === 'startswith') {
      const results = this.history.filter(cmd =>
        cmd.toLowerCase().startsWith(lowerQuery),
      )
      return typeof resultLimit === 'number' ? results.slice(0, resultLimit) : results
    }

    // Regex search (query treated as regex pattern)
    if (this.config.searchMode === 'regex') {
      try {
        const pattern = new RegExp(query)
        const results = this.history.filter(cmd => pattern.test(cmd))
        return typeof resultLimit === 'number' ? results.slice(0, resultLimit) : results
      }
      catch {
        // Invalid regex: return empty results
        return []
      }
    }

    // Fuzzy search
    const results = this.history.filter((cmd) => {
      const lowerCmd = cmd.toLowerCase()
      let queryIndex = 0

      for (let i = 0; i < lowerCmd.length && queryIndex < lowerQuery.length; i++) {
        if (lowerCmd[i] === lowerQuery[queryIndex]) {
          queryIndex++
        }
      }

      return queryIndex === lowerQuery.length
    })
    return typeof resultLimit === 'number' ? results.slice(0, resultLimit) : results
  }

  clear(): void {
    this.history = []
  }

  load(): void {
    try {
      const filePath = this.resolvePath(this.config.file || '~/.krusty_history')

      if (!existsSync(filePath)) {
        return
      }

      const content = readFileSync(filePath, 'utf-8')
      this.history = content
        .split('\n')
        .filter((line: string) => line.trim())
        .slice(-this.config.maxEntries!)
    }
    catch {
      // Silently fail - history is not critical
    }
  }

  saveSync(): void {
    try {
      const filePath = this.resolvePath(this.config.file || '~/.krusty_history')
      const dir = dirname(filePath)

      // Ensure directory exists
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true })
      }

      const content = this.history.join('\n')
      writeFileSync(filePath, content, 'utf-8')
    }
    catch {
      // Silently fail - history saving is not critical
    }
  }

  private resolvePath(path: string): string {
    if (path.startsWith('~')) {
      const homeEnv = env.HOME
      const home = homeEnv && homeEnv.trim() ? homeEnv : homedir()
      const base = !home || home === '/' ? tmpdir() : home
      if (path === '~')
        return base
      const rest = path.startsWith('~/') ? path.slice(2) : path.slice(1)
      return resolve(base, rest)
    }
    return resolve(cwd(), path)
  }

  // Get recent commands (for completion)
  getRecent(limit = 10): string[] {
    return this.history.slice(-limit).reverse()
  }

  // Get command at specific index (1-based, like bash history)
  getCommand(index: number): string | undefined {
    if (index < 1 || index > this.history.length) {
      return undefined
    }
    return this.history[index - 1]
  }

  // Get commands matching pattern
  getMatching(pattern: RegExp): string[] {
    return this.history.filter(cmd => pattern.test(cmd))
  }

  // Remove command at index
  remove(index: number): boolean {
    if (index < 1 || index > this.history.length) {
      return false
    }
    this.history.splice(index - 1, 1)
    return true
  }

  // Get statistics
  getStats(): {
    totalCommands: number
    uniqueCommands: number
    mostUsed: Array<{ command: string, count: number }>
  } {
    const commandCounts = new Map<string, number>()

    for (const cmd of this.history) {
      const count = commandCounts.get(cmd) || 0
      commandCounts.set(cmd, count + 1)
    }

    const mostUsed = Array.from(commandCounts.entries())
      .map(([command, count]) => ({ command, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10)

    return {
      totalCommands: this.history.length,
      uniqueCommands: commandCounts.size,
      mostUsed,
    }
  }
}

// Shared singleton for cross-component history access
export const sharedHistory: HistoryManager = new HistoryManager()
