import type { ReverseSearchState } from './types'
import process from 'node:process'
import { displayWidth, truncateToWidth } from './ansi'

export class ReverseSearchManager {
  private state: ReverseSearchState
  private getHistoryArray: () => string[] | undefined

  constructor(getHistoryArray: () => string[] | undefined) {
    this.getHistoryArray = getHistoryArray
    this.state = {
      reverseSearchActive: false,
      reverseSearchQuery: '',
      reverseSearchMatches: [],
      reverseSearchIndex: 0,
    }
  }

  start(): void {
    this.state.reverseSearchActive = true
    this.state.reverseSearchQuery = ''
    this.state.reverseSearchMatches = this.computeMatches()
    this.state.reverseSearchIndex = Math.max(0, this.state.reverseSearchMatches.length - 1)
  }

  update(ch: string): string {
    if (ch === '\\b') {
      this.state.reverseSearchQuery = this.state.reverseSearchQuery.slice(0, -1)
    }
    else {
      this.state.reverseSearchQuery += ch
    }
    this.state.reverseSearchMatches = this.computeMatches()
    this.state.reverseSearchIndex = Math.max(0, this.state.reverseSearchMatches.length - 1)
    return this.state.reverseSearchMatches[this.state.reverseSearchIndex] || ''
  }

  cycle(): string {
    if (!this.state.reverseSearchActive || this.state.reverseSearchMatches.length === 0)
      return ''

    this.state.reverseSearchIndex = (this.state.reverseSearchIndex - 1 + this.state.reverseSearchMatches.length) % this.state.reverseSearchMatches.length
    return this.state.reverseSearchMatches[this.state.reverseSearchIndex] || ''
  }

  cancel(): void {
    this.state.reverseSearchActive = false
    this.state.reverseSearchQuery = ''
    this.state.reverseSearchMatches = []
    this.state.reverseSearchIndex = 0
  }

  getCurrentMatch(): string {
    return this.state.reverseSearchMatches[this.state.reverseSearchIndex] || ''
  }

  isActive(): boolean {
    return this.state.reverseSearchActive
  }

  getStatus(): string {
    if (!this.state.reverseSearchActive)
      return ''

    const q = this.state.reverseSearchQuery
    const cur = this.state.reverseSearchMatches[this.state.reverseSearchIndex] || ''
    return `(reverse-i-search) '${q}': ${cur}`
  }

  formatStatusForWidth(prompt: string, currentInput: string): string {
    const raw = this.getStatus()
    if (!raw)
      return ''

    const totalCols = process.stdout.columns ?? 80
    // For multi-line prompts/inputs, only the last line width matters for remaining columns
    const promptLastLine = prompt.slice(prompt.lastIndexOf('\n') + 1)
    const inputLastLine = (() => {
      const nl = currentInput.lastIndexOf('\n')
      return nl >= 0 ? currentInput.slice(nl + 1) : currentInput
    })()
    const used = displayWidth(promptLastLine) + displayWidth(inputLastLine)
    const available = Math.max(0, totalCols - used - 1) // space before status

    if (available <= 0)
      return ''
    if (displayWidth(raw) <= available)
      return raw

    // Truncate with ellipsis, prefer trimming current match first
    const base = `(reverse-i-search) '${this.state.reverseSearchQuery}': `
    const remain = Math.max(0, available - displayWidth(base) - 1)
    if (remain <= 0)
      return base.trimEnd()

    const cur = this.getCurrentMatch()
    const trimmed = `${truncateToWidth(cur, Math.max(0, remain))}…`
    return `${base}${trimmed}`
  }

  private computeMatches(): string[] {
    const hist = this.getHistoryArray() || []
    if (!this.state.reverseSearchQuery)
      return hist.slice()

    const q = this.state.reverseSearchQuery.toLowerCase()
    return hist.filter(h => h.toLowerCase().includes(q))
  }
}
