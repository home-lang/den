export interface HistoryNavigatorOptions {
  // When true, duplicate consecutive entries are treated as separate steps.
  // When false, duplicates are de-duplicated while browsing.
  keepDuplicates?: boolean
}

// A pure, testable history navigator. No TTY or rendering concerns.
// It supports prefix-filtered browsing like common shells do.
export class HistoryNavigator {
  private history: string[]
  private prefix: string
  private index: number // -1 means "editing current line" (not yet in history)
  private filtered: number[] // indices into history that match the prefix (most-recent-first)
  private keepDuplicates: boolean

  constructor(history: string[] = [], prefix = '', options: HistoryNavigatorOptions = {}) {
    this.history = history.slice()
    this.prefix = prefix
    this.index = -1
    this.filtered = []
    this.keepDuplicates = options.keepDuplicates ?? true
    this.recompute()
  }

  setHistory(history: string[]): void {
    this.history = history.slice()
    this.recompute()
  }

  setPrefix(prefix: string): void {
    this.prefix = prefix
    this.recompute()
  }

  reset(): void {
    this.index = -1
  }

  // Returns current value under the cursor. If index === -1, returns the prefix (editing state)
  current(): string {
    if (this.index < 0)
      return this.prefix
    const histIdx = this.filtered[this.index]
    return this.history[histIdx] ?? this.prefix
  }

  // Move to previous (older) matching history item. Returns the new value.
  up(): string {
    if (this.filtered.length === 0)
      return this.current()
    if (this.index < this.filtered.length - 1)
      this.index++
    return this.current()
  }

  // Move to next (newer) matching history item. Returns the new value.
  down(): string {
    if (this.filtered.length === 0)
      return this.current()
    if (this.index >= 0)
      this.index--
    return this.current()
  }

  // True if we are currently browsing history (not editing)
  isBrowsing(): boolean {
    return this.index >= 0
  }

  private recompute(): void {
    const out: number[] = []
    const seen = new Set<string>()
    // Process from newest to oldest, so up arrow shows most recent commands first
    for (let i = this.history.length - 1; i >= 0; i--) {
      const h = this.history[i]
      if (typeof h !== 'string')
        continue
      if (this.prefix && !h.startsWith(this.prefix))
        continue
      if (!this.keepDuplicates) {
        if (seen.has(h))
          continue
        seen.add(h)
      }
      out.push(i)
    }
    // Keep the order so that up arrow shows most recent matching commands first
    this.filtered = out
    this.index = -1
  }
}
