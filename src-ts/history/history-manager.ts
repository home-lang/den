export class HistoryManager {
  private history: string[] = []
  private maxSize: number = 1000
  private filePath: string
  private isInitialized = false

  constructor(config?: { maxSize?: number, filePath?: string }) {
    this.maxSize = config?.maxSize || this.maxSize
    this.filePath = config?.filePath || ''
  }

  async initialize(): Promise<void> {
    if (this.isInitialized)
      return

    try {
      if (this.filePath) {
        // In a real implementation, we would load history from file here
        // For now, we'll just initialize with an empty array
      }
      this.isInitialized = true
    }
    catch (error) {
      console.error('Failed to initialize history manager:', error)
      throw error
    }
  }

  add(command: string): void {
    if (!command.trim())
      return

    // Remove any existing occurrence of the command
    this.history = this.history.filter(cmd => cmd !== command)

    // Add to the beginning of the array (most recent first)
    this.history.unshift(command)

    // Trim history to max size
    if (this.history.length > this.maxSize) {
      this.history = this.history.slice(0, this.maxSize)
    }
  }

  getHistory(): string[] {
    return [...this.history]
  }

  search(query: string): string[] {
    if (!query)
      return this.getHistory()
    return this.history.filter(cmd =>
      cmd.toLowerCase().includes(query.toLowerCase()),
    )
  }

  async save(): Promise<void> {
    if (!this.filePath)
      return

    try {
      // In a real implementation, we would save to file here
      // For now, this is a no-op
    }
    catch (error) {
      console.error('Failed to save history:', error)
      throw error
    }
  }
}
