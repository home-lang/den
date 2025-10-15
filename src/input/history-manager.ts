import type { HistoryNavigator } from '../history/history-navigator'
import type { Shell } from '../types'
import type { HistoryState } from './types'
import { sharedHistory } from '../history'

export class InputHistoryManager {
  private shell: Shell
  private state: HistoryState
  private historyNav?: HistoryNavigator

  constructor(shell: Shell) {
    this.shell = shell
    this.state = {
      historyBrowseActive: false,
      historyBrowseIndex: -1,
      historyBrowseSaved: '',
      historyFilteredIndexes: [],
      historyFilteredPosition: 0,
    }
  }

  getHistoryArray(): string[] | undefined {
    // Prefer a fresh snapshot from the shell's HistoryManager
    try {
      const hm = (this.shell as any)?.historyManager
      if (hm && typeof hm.getHistory === 'function') {
        const fresh = hm.getHistory()
        if (Array.isArray(fresh))
          return fresh
      }
    }
    catch {}

    // Fallback to shell.history if present
    const arr = (this.shell as any)?.history as string[] | undefined
    if (arr && Array.isArray(arr))
      return arr

    // Final fallback to shared singleton
    try {
      const shared = sharedHistory as any
      if (shared && typeof shared.getHistory === 'function')
        return shared.getHistory()
    }
    catch {}
    return undefined
  }

  // Expand history references: !!, !n, !string
  expandHistory(input: string): string {
    const hist = this.getHistoryArray()
    if (!hist || hist.length === 0)
      return input

    // !! -> last command (allow space or end after !!)
    input = input.replace(/(^|\s)!!(?=\s|$)/g, (_m: string, pre: string) => {
      const last = hist[hist.length - 1]
      return `${pre}${last ?? ''}`
    })

    // !n -> nth command (1-based)
    input = input.replace(/(^|\s)!(\d+)(?:\b|$)/g, (_m, pre: string, n: string) => {
      const idx = Number.parseInt(n, 10)
      const cmd = idx >= 1 && idx <= hist.length ? hist[idx - 1] : ''
      return `${pre}${cmd}`
    })

    // !string -> most recent command starting with string
    input = input.replace(/(^|\s)!([a-z][\w-]*)(?:\b|$)/gi, (_m, pre: string, prefix: string) => {
      for (let i = hist.length - 1; i >= 0; i--) {
        if (hist[i].startsWith(prefix))
          return `${pre}${hist[i]}`
      }
      return `${pre}`
    })

    return input
  }

  // Suggest from history: entries starting with prefix, most recent first, deduped
  getHistorySuggestions(prefix: string): string[] {
    const history = this.getHistoryArray()
    if (!history || !prefix)
      return []

    const seen = new Set<string>()
    const out: string[] = []
    // iterate from most recent to oldest
    for (let i = history.length - 1; i >= 0; i--) {
      const h = history[i]
      if (typeof h !== 'string')
        continue
      if (!h.startsWith(prefix))
        continue
      if (seen.has(h))
        continue
      seen.add(h)
      out.push(h)
      if (out.length >= 10) // maxSuggestions
        break
    }
    return out
  }

  // Prefix-based history navigation
  navigateHistory(direction: 'up' | 'down', currentInput: string): { input: string, active: boolean } {
    const hist = this.getHistoryArray() || []

    if (direction === 'up') {
      if (this.state.historyBrowseActive) {
        // Move to next older filtered entry
        if (this.state.historyFilteredPosition < this.state.historyFilteredIndexes.length - 1) {
          this.state.historyFilteredPosition++
          const actualIndex = this.state.historyFilteredIndexes[this.state.historyFilteredPosition]
          return { input: hist[actualIndex] || '', active: true }
        }
        return { input: currentInput, active: true }
      }
      else {
        // Start browsing - filter history by current input prefix
        if (hist.length > 0) {
          this.state.historyBrowseActive = true
          this.state.historyBrowseSaved = currentInput
          const prefix = currentInput.trim()

          // Filter history entries that start with the current prefix
          const filtered: number[] = []
          for (let i = hist.length - 1; i >= 0; i--) {
            const entry = hist[i]
            if (typeof entry === 'string' && entry.startsWith(prefix)) {
              filtered.push(i)
            }
          }

          this.state.historyFilteredIndexes = filtered
          this.state.historyFilteredPosition = 0

          if (filtered.length > 0) {
            const actualIndex = filtered[0]
            return { input: hist[actualIndex] || '', active: true }
          }
        }
      }
    }
    else if (direction === 'down') {
      if (this.state.historyBrowseActive) {
        // Navigate forward in filtered history or return to saved input
        if (this.state.historyFilteredPosition > 0) {
          // Go to newer filtered entry
          this.state.historyFilteredPosition--
          const actualIndex = this.state.historyFilteredIndexes[this.state.historyFilteredPosition]
          return { input: hist[actualIndex] || '', active: true }
        }
        else {
          // Return to original input and exit history browsing
          this.state.historyBrowseActive = false
          const saved = this.state.historyBrowseSaved
          this.state.historyFilteredIndexes = []
          this.state.historyFilteredPosition = 0
          return { input: saved, active: false }
        }
      }
    }

    return { input: currentInput, active: this.state.historyBrowseActive }
  }

  resetHistoryBrowsing(): void {
    this.state.historyBrowseActive = false
    this.state.historyBrowseIndex = -1
    this.state.historyNav = undefined
    this.state.historyFilteredIndexes = []
    this.state.historyFilteredPosition = 0
  }

  isHistoryBrowseActive(): boolean {
    return this.state.historyBrowseActive
  }
}
