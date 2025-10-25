import type { Interface } from 'node:readline/promises'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'
import { createInterface } from 'node:readline/promises'

export class HistoryManager {
  private history: string[] = []
  private historyPath: string
  private maxSize: number
  private isInitialized = false

  constructor(options: { maxSize?: number, historyFile?: string } = {}) {
    this.maxSize = options.maxSize || 1000
    this.historyPath = options.historyFile || join(homedir(), '.krusty_history')
  }

  async initialize(): Promise<void> {
    if (this.isInitialized)
      return

    try {
      // Ensure history directory exists
      await mkdir(join(homedir(), '.krusty'), { recursive: true })

      // Load existing history
      const data = await readFile(this.historyPath, 'utf-8').catch(() => '')
      this.history = data.split('\n').filter(Boolean)
      this.isInitialized = true
    }
    catch (error) {
      console.error('Failed to initialize history:', error)
      this.history = []
    }
  }

  add(command: string): void {
    if (!command.trim() || command === this.history[this.history.length - 1]) {
      return
    }

    this.history.push(command)

    // Trim history if it exceeds max size
    if (this.history.length > this.maxSize) {
      this.history = this.history.slice(-this.maxSize)
    }

    // Save history after each command
    this.save().catch(console.error)
  }

  getHistory(): string[] {
    return [...this.history]
  }

  async save(): Promise<void> {
    if (!this.isInitialized)
      return

    try {
      // Ensure we don't have duplicate commands
      const uniqueHistory = [...new Set(this.history)]
      await writeFile(this.historyPath, `${uniqueHistory.join('\n')}\n`, 'utf-8')
    }
    catch (error) {
      console.error('Failed to save history:', error)
    }
  }

  clear(): void {
    this.history = []
    this.save().catch(console.error)
  }

  // For readline integration
  getReadlineInterface(): Interface {
    return createInterface({
      input: process.stdin,
      output: process.stdout,
      history: this.history,
      historySize: this.maxSize,
    })
  }
}

// Singleton instance
export const historyManager: HistoryManager = new HistoryManager()
