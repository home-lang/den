import type { CompletionGroup, CompletionItem, Shell } from '../types'
import type { AutoSuggestOptions, GroupedSuggestion } from './types'

export class SuggestionManager {
  private shell: Shell
  private options: AutoSuggestOptions
  private suggestions: string[] = []
  private selectedIndex: number = 0
  private currentSuggestion: string = ''
  private isShowingSuggestions: boolean = false
  private isNavigatingSuggestions: boolean = false

  // Grouped completion state
  private groupedActive: boolean = false
  private groupedForRender: GroupedSuggestion[] | null = null
  private groupedIndexMap: Array<{ group: number, idx: number }> = []

  // One-shot flags for special behavior
  private forceHistoryOnlyOnce: boolean = false
  private suppressHistoryMergeOnce: boolean = false
  private specialRestoreGroupedOnce: boolean = false
  private inlineFromHistoryOnce: string | null = null

  // Track acceptance and post-accept edits
  private acceptedCompletion: boolean = false
  private editedSinceAccept: boolean = false

  constructor(shell: Shell, options: AutoSuggestOptions) {
    this.shell = shell
    this.options = options
  }

  updateSuggestions(currentInput: string, cursorPosition: number, getHistorySuggestions: (prefix: string) => string[]): void {
    try {
      // Snapshot previous selection to try to preserve it after refresh
      const prevSelectedIndex = this.selectedIndex
      const prevSuggestions = this.suggestions.slice()
      const prevSelected = prevSuggestions[prevSelectedIndex]

      // Get suggestions from shell (includes plugin completions)
      const rawNextAny: any = this.shell.getCompletions(currentInput, cursorPosition) || []

      // Narrowing helpers
      const isCompletionItem = (v: any): v is CompletionItem => v && typeof v === 'object' && typeof v.text === 'string'
      const isGroupArray = (v: any): v is CompletionGroup<string | CompletionItem>[] => Array.isArray(v) && v.every(g => g && typeof g.title === 'string' && Array.isArray(g.items))

      // Reset grouped state each update
      this.groupedActive = false
      this.groupedForRender = null
      this.groupedIndexMap = []

      let next: string[] = []
      let groups: GroupedSuggestion[] | null = null

      if (isGroupArray(rawNextAny)) {
        // Normalize groups to strings or {text}
        groups = rawNextAny.map(g => ({
          title: g.title,
          items: g.items.map(it => typeof it === 'string' ? it : { text: it.text }),
        }))
      }

      // Filter by current token prefix to support live filtering as the user types
      const before = currentInput.slice(0, cursorPosition)
      const token = (before.match(/(^|\s)(\S*)$/)?.[2] ?? '').trim()
      const max = this.options.maxSuggestions ?? 10

      if (groups) {
        next = this.processGroupedSuggestions(groups, token, max, getHistorySuggestions, currentInput)
      }
      else {
        next = this.processFlatSuggestions(rawNextAny, token, isCompletionItem)
      }

      // Merge with history suggestions for flat suggestions
      if (!this.groupedActive) {
        next = this.mergeWithHistory(next, max, getHistorySuggestions, currentInput)
      }

      this.suggestions = next
      this.preserveSelection(prevSelected, prevSelectedIndex)
      this.updateCurrentSuggestion(currentInput, cursorPosition)

      // One-shot suppression of history merging is consumed here
      this.suppressHistoryMergeOnce = false
    }
    catch {
      this.resetSuggestions()
    }
  }

  private processGroupedSuggestions(groups: GroupedSuggestion[], token: string, max: number, getHistorySuggestions: (prefix: string) => string[], currentInput: string): string[] {
    // Apply filtering within groups
    const lower = token.toLowerCase()
    const filteredGroups = token.length > 0
      ? groups.map(g => ({
          title: g.title,
          items: g.items.filter((it) => {
            const label = typeof it === 'string' ? it : it.text
            return label.toLowerCase().startsWith(lower)
          }),
        }))
      : groups

    // If filter empties all, keep original groups for typo correction behavior
    const anyItems = filteredGroups.some(g => g.items.length > 0)
    const baseGroups = anyItems ? filteredGroups : groups

    // Merge duplicate groups by normalized title
    const mergedGroups = this.mergeDuplicateGroups(baseGroups)

    // Build flattened list and index map
    const { flat, renderGroups } = this.buildGroupedStructure(mergedGroups, max, getHistorySuggestions, currentInput)

    this.groupedActive = renderGroups.length > 0
    this.groupedForRender = renderGroups.length > 0 ? renderGroups : null

    return flat
  }

  private processFlatSuggestions(rawNextAny: any, token: string, isCompletionItem: (v: any) => v is CompletionItem): string[] {
    const rawNext = Array.isArray(rawNextAny)
      ? rawNextAny.map((v: any) => isCompletionItem(v) ? v.text : String(v))
      : []

    if (token.length > 0) {
      const lower = token.toLowerCase()
      const filtered = rawNext.filter((s: string) => s.toLowerCase().startsWith(lower))
      // If strict prefix filtering removes all items, keep the raw list for typo correction
      return filtered.length > 0 ? filtered : rawNext
    }

    return rawNext
  }

  private mergeDuplicateGroups(groups: GroupedSuggestion[]): GroupedSuggestion[] {
    const mergedByTitle: GroupedSuggestion[] = []
    const titleIndex = new Map<string, number>()

    for (const g of groups) {
      const displayTitle = (g.title ?? '').trim()
      const key = displayTitle.toLowerCase()
      if (!g.items || g.items.length === 0)
        continue

      let idx = titleIndex.get(key)
      if (idx === undefined) {
        idx = mergedByTitle.push({ title: displayTitle, items: [] }) - 1
        titleIndex.set(key, idx)
      }

      const target = mergedByTitle[idx]
      const seen = new Set<string>(target.items.map(it => (typeof it === 'string' ? it : it.text)))
      for (const it of g.items) {
        const label = typeof it === 'string' ? it : it.text
        if (!seen.has(label)) {
          target.items.push(it)
          seen.add(label)
        }
      }
    }

    return mergedByTitle
  }

  private buildGroupedStructure(groups: GroupedSuggestion[], max: number, getHistorySuggestions: (prefix: string) => string[], currentInput: string): { flat: string[], renderGroups: GroupedSuggestion[] } {
    const flat: string[] = []
    const map: Array<{ group: number, idx: number }> = []
    const renderGroups: GroupedSuggestion[] = []

    for (let gi = 0; gi < groups.length; gi++) {
      const g = groups[gi]
      if (!g.items || g.items.length === 0)
        continue

      // Add to flat in original order from shell
      for (let ii = 0; ii < g.items.length; ii++) {
        const it = g.items[ii]
        const label = typeof it === 'string' ? it : it.text
        flat.push(label)
      }

      // Prepare sorted items for rendering
      const sorted = g.items
        .map((it, idx) => ({ it, idx, label: typeof it === 'string' ? it : it.text }))
        .sort((a, b) => a.label.localeCompare(b.label))

      const rgItems: Array<string | { text: string }> = []
      for (let si = 0; si < sorted.length; si++) {
        const s = sorted[si]
        rgItems.push(s.it)
        map.push({ group: gi, idx: si })
      }
      renderGroups.push({ title: g.title, items: rgItems })
    }

    // Merge history suggestions into a trailing History group if there's room
    if (flat.length < max && !this.suppressHistoryMergeOnce && !this.isCdContext(currentInput)) {
      const prefix = this.getCurrentLinePrefix(currentInput)
      const seen = new Set(flat)
      const histItems: string[] = []
      const histSorted = getHistorySuggestions(prefix).slice().sort((a, b) => a.localeCompare(b))

      for (const h of histSorted) {
        if (flat.length >= max)
          break
        if (seen.has(h))
          continue
        flat.push(h)
        map.push({ group: renderGroups.length, idx: histItems.length })
        histItems.push(h)
        seen.add(h)
      }

      if (histItems.length > 0) {
        renderGroups.push({ title: 'History', items: histItems })
      }
    }

    this.groupedIndexMap = map
    return { flat, renderGroups }
  }

  private mergeWithHistory(suggestions: string[], max: number, getHistorySuggestions: (prefix: string) => string[], currentInput: string): string[] {
    const merged: string[] = []
    const seen = new Set<string>()

    for (const s of suggestions) {
      if (!seen.has(s)) {
        merged.push(s)
        seen.add(s)
        if (merged.length >= max)
          break
      }
    }

    if (merged.length < max && !this.suppressHistoryMergeOnce && !this.isCdContext(currentInput)) {
      const prefix = this.getCurrentLinePrefix(currentInput)
      const hist = getHistorySuggestions(prefix)
      for (const h of hist) {
        if (!seen.has(h)) {
          merged.push(h)
          seen.add(h)
          if (merged.length >= max)
            break
        }
      }
    }

    return merged
  }

  private preserveSelection(prevSelected: string | undefined, prevSelectedIndex: number): void {
    if (this.suggestions.length > 0) {
      if (prevSelected) {
        const idx = this.suggestions.findIndex(s => s === prevSelected)
        if (idx >= 0) {
          this.selectedIndex = idx
        }
        else {
          this.selectedIndex = Math.min(prevSelectedIndex, this.suggestions.length - 1)
        }
      }
      else {
        this.selectedIndex = Math.min(prevSelectedIndex, this.suggestions.length - 1)
      }
    }
    else {
      this.selectedIndex = 0
    }
  }

  private updateCurrentSuggestion(currentInput: string, cursorPosition: number): void {
    if (this.suggestions.length > 0) {
      const selected = (this.isCdContext(currentInput) ? null : this.inlineFromHistoryOnce) ?? this.getSelectedLabel() ?? ''
      const inputBeforeCursor = currentInput.slice(0, cursorPosition)

      // Suppress inline overlay when user has only typed "bun run" (no third token yet)
      const prefixTrimmed = this.getCurrentLinePrefix(currentInput).trim().toLowerCase()
      if (/^bunx?\s+run\b/.test(prefixTrimmed)) {
        const parts = prefixTrimmed.split(/\s+/).filter(Boolean)
        if (parts.length === 2) {
          this.currentSuggestion = ''
          this.inlineFromHistoryOnce = null
          return
        }
      }

      this.currentSuggestion = this.calculateSuggestionSuffix(selected, inputBeforeCursor)
    }
    else {
      this.currentSuggestion = ''
    }

    // Consume inline history override after applying once
    this.inlineFromHistoryOnce = null
  }

  private calculateSuggestionSuffix(selected: string, inputBeforeCursor: string): string {
    // Handle different completion scenarios
    if (inputBeforeCursor.trim() === '') {
      // Empty input - show full suggestion
      return selected
    }
    else if (/\s$/.test(inputBeforeCursor)) {
      // Starting a new token (cursor preceded by whitespace)
      if (selected.toLowerCase().startsWith(inputBeforeCursor.toLowerCase())) {
        return selected.slice(inputBeforeCursor.length)
      }
      else {
        return ''
      }
    }
    else {
      // In the middle of a token
      const tokens = inputBeforeCursor.trim().split(/\s+/)
      const lastToken = tokens[tokens.length - 1] || ''
      const beforeLastIdx = inputBeforeCursor.lastIndexOf(lastToken)
      const basePrefix = beforeLastIdx >= 0 ? inputBeforeCursor.slice(0, beforeLastIdx) : ''

      const selLower = selected.toLowerCase()
      const baseLower = basePrefix.toLowerCase()

      if (basePrefix && selLower.startsWith(baseLower)) {
        const remainingFromBase = selected.slice(basePrefix.length)
        const remainingLower = remainingFromBase.toLowerCase()
        if (remainingLower.startsWith(lastToken.toLowerCase())) {
          return selected.slice(inputBeforeCursor.length)
        }
        else {
          return ''
        }
      }
      else if (selLower.startsWith(lastToken.toLowerCase())) {
        return selected.slice(lastToken.length)
      }
      else {
        return ''
      }
    }
  }

  private getCurrentLinePrefix(currentInput: string): string {
    const upto = currentInput.slice(0, currentInput.length)
    const nl = upto.lastIndexOf('\n')
    return nl >= 0 ? upto.slice(nl + 1) : upto
  }

  private isCdContext(currentInput: string): boolean {
    try {
      const line = this.getCurrentLinePrefix(currentInput)
      return /^\s*cd(?:\s+|$)/i.test(line)
    }
    catch {
      return false
    }
  }

  private resetSuggestions(): void {
    this.suggestions = []
    this.currentSuggestion = ''
    this.groupedActive = false
    this.groupedForRender = null
    this.groupedIndexMap = []
  }

  // Public getters and methods
  getSuggestions(): string[] {
    return this.suggestions
  }

  getCurrentSuggestion(): string {
    return this.currentSuggestion
  }

  getSelectedIndex(): number {
    return this.selectedIndex
  }

  setSelectedIndex(index: number): void {
    this.selectedIndex = Math.max(0, Math.min(index, this.suggestions.length - 1))
  }

  setShowingSuggestions(showing: boolean): void {
    this.isShowingSuggestions = showing
  }

  setNavigatingSuggestions(navigating: boolean): void {
    this.isNavigatingSuggestions = navigating
  }

  isGroupedActive(): boolean {
    return this.groupedActive
  }

  getGroupedForRender(): GroupedSuggestion[] | null {
    return this.groupedForRender
  }

  getGroupedIndexMap(): Array<{ group: number, idx: number }> {
    return this.groupedIndexMap
  }

  getSelectedLabel(): string | null {
    if (!this.suggestions || this.suggestions.length === 0)
      return null

    const idx = this.selectedIndex
    if (idx < 0 || idx >= this.suggestions.length)
      return null

    if (this.isShowingSuggestions && this.groupedActive && this.groupedForRender && this.groupedIndexMap.length === this.suggestions.length) {
      const map = this.groupedIndexMap[idx]
      const group = this.groupedForRender[map.group]
      const item = group?.items?.[map.idx]
      if (typeof item === 'string')
        return item
      if (item && typeof (item as any).text === 'string')
        return (item as any).text
    }

    return this.suggestions[idx] || null
  }

  acceptSuggestion(currentInput: string, cursorPosition: number, setInput: (input: string, cursor: number) => void): void {
    if (this.currentSuggestion) {
      const newInput = currentInput.slice(0, cursorPosition) + this.currentSuggestion + currentInput.slice(cursorPosition)
      const newCursor = cursorPosition + this.currentSuggestion.length
      setInput(newInput, newCursor)
      this.currentSuggestion = ''
      this.acceptedCompletion = true
      this.editedSinceAccept = false
    }
  }

  applySelectedCompletion(currentInput: string, cursorPosition: number, setInput: (input: string, cursor: number) => void): boolean {
    const selected = this.getSelectedLabel() || ''
    if (!selected)
      return false

    const selectedIsDir = selected.endsWith('/')
    const before = currentInput.slice(0, cursorPosition)
    const after = currentInput.slice(cursorPosition)

    // New token: just insert selected at cursor
    if (/\s$/.test(before) || before === '') {
      const base = before
      const toInsert = selected.startsWith(base) ? selected.slice(base.length) : selected
      setInput(before + toInsert + after, cursorPosition + toInsert.length)
      this.currentSuggestion = ''
      this.acceptedCompletion = true
      this.editedSinceAccept = false
      return selectedIsDir
    }

    const m = before.match(/(^|\s)(\S+)$/)
    if (m) {
      const lastTok = m[2] || ''
      const tokenStart = cursorPosition - lastTok.length
      const base = currentInput.slice(0, tokenStart)
      const toInsert = selected.startsWith(base) ? selected.slice(base.length) : selected
      setInput(base + toInsert + after, tokenStart + toInsert.length)
    }
    else {
      setInput(selected + after, selected.length)
    }

    this.currentSuggestion = ''
    this.acceptedCompletion = true
    this.editedSinceAccept = false
    return selectedIsDir
  }

  // Special behavior flags
  setForceHistoryOnlyOnce(force: boolean): void {
    this.forceHistoryOnlyOnce = force
  }

  setSuppressHistoryMergeOnce(suppress: boolean): void {
    this.suppressHistoryMergeOnce = suppress
  }

  setSpecialRestoreGroupedOnce(restore: boolean): void {
    this.specialRestoreGroupedOnce = restore
  }

  setInlineFromHistoryOnce(inline: string | null): void {
    this.inlineFromHistoryOnce = inline
  }

  markEdited(): void {
    if (this.acceptedCompletion) {
      this.editedSinceAccept = true
    }
  }

  reset(): void {
    this.suggestions = []
    this.selectedIndex = 0
    this.currentSuggestion = ''
    this.isShowingSuggestions = false
    this.isNavigatingSuggestions = false
    this.groupedActive = false
    this.groupedForRender = null
    this.groupedIndexMap = []
    this.forceHistoryOnlyOnce = false
    this.suppressHistoryMergeOnce = false
    this.specialRestoreGroupedOnce = false
    this.inlineFromHistoryOnce = null
    this.acceptedCompletion = false
    this.editedSinceAccept = false
  }
}
