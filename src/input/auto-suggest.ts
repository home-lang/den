import type { Shell } from '../types'
import type { AutoSuggestOptions } from './types'
import process from 'node:process'
import * as readline from 'node:readline'
import { sharedHistory } from '../history'
import { renderHighlighted } from './highlighting'
import { ReverseSearchManager } from './reverse-search'

export type { AutoSuggestOptions } from './types'

interface CursorPosition {
  line: number
  col: number
}

export class AutoSuggestInput {
  // Core dependencies
  private readonly shell: Shell
  private readonly options: Required<AutoSuggestOptions>
  private rl: readline.Interface | null = null
  private readonly reverseSearchManager: ReverseSearchManager
  private handleKeypress!: (str: string, key: { name: string, ctrl: boolean, meta: boolean, shift: boolean } | undefined) => void
  private keypressListener?: (str: string, key: { name: string, ctrl: boolean, meta?: boolean, shift?: boolean }) => void

  // Input state
  private currentInput: string = ''
  private cursorPosition: number = 0
  private historyIndex: number = -1
  private originalInput: string = ''
  private isShowingSuggestions: boolean = false
  private testMode: boolean = false
  private suggestions: string[] = []
  private selectedIndex: number = 0
  private currentSuggestion: string = ''
  private historyBrowseActive: boolean = false
  private groupedActive: boolean = false
  private groupedForRender: Array<{ title: string, items: string[] }> = []

  // Configuration defaults
  private static readonly DEFAULT_OPTIONS: Required<AutoSuggestOptions> = {
    maxSuggestions: 10,
    showInline: true,
    highlightColor: '\x1B[90m',
    suggestionColor: '\x1B[90m',
    keymap: 'emacs',
    syntaxHighlight: true,
    syntaxColors: {},
  }

  constructor(shell: Shell, options: AutoSuggestOptions = {}) {
    this.shell = shell
    this.options = { ...AutoSuggestInput.DEFAULT_OPTIONS, ...options }
    this.reverseSearchManager = new ReverseSearchManager(() => this.shell.history)
    this.initializeKeypressHandler()
  }

  // ===== Test Helpers =====
  public setInputForTesting(input: string, cursorPos?: number): void {
    this.currentInput = input
    this.cursorPosition = cursorPos !== undefined ? cursorPos : input.length
    // Reset history browsing when input changes
    this.historyBrowseActive = false
    this.historyIndex = -1
    // Update suggestions for the new input
    this.updateSuggestions()
  }

  public setCursorPositionForTesting(pos: number): void {
    this.cursorPosition = Math.max(0, Math.min(pos, this.currentInput.length))
  }

  // ===== Cursor and Line Editing =====
  private lineColToIndex(line: number, col: number | string): number {
    const lines = this.currentInput.split('\n')
    let index = 0

    // Handle negative line numbers (count from end)
    const lineNum = line < 0 ? Math.max(0, lines.length + line) : line

    // Sum lengths of previous lines
    for (let i = 0; i < lineNum && i < lines.length; i++) {
      index += lines[i].length + 1 // +1 for newline
    }

    // Handle column
    const colNum = typeof col === 'string'
      ? lines[lineNum]?.indexOf(col) ?? 0
      : col

    return Math.min(index + Math.max(0, colNum), this.currentInput.length)
  }

  private indexToLineCol(index: number): CursorPosition {
    const lines = this.currentInput.split('\n')
    let pos = 0

    for (let line = 0; line < lines.length; line++) {
      const lineLength = lines[line].length
      if (pos + lineLength >= index) {
        return { line, col: index - pos }
      }
      pos += lineLength + 1 // +1 for newline
    }

    // If we get here, return position at end of last line
    return {
      line: Math.max(0, lines.length - 1),
      col: lines[lines.length - 1]?.length ?? 0,
    }
  }

  public moveCursorUp(): void {
    const { line, col } = this.indexToLineCol(this.cursorPosition)
    if (line > 0) {
      const lines = this.currentInput.split('\n')
      const prevLineLength = lines[line - 1].length
      const newCol = Math.min(col, prevLineLength)
      this.cursorPosition = this.lineColToIndex(line - 1, newCol)
    }
  }

  public moveCursorDown(): void {
    const { line, col } = this.indexToLineCol(this.cursorPosition)
    const lines = this.currentInput.split('\n')
    if (line < lines.length - 1) {
      const nextLineLength = lines[line + 1].length
      const newCol = Math.min(col, nextLineLength)
      this.cursorPosition = this.lineColToIndex(line + 1, newCol)
    }
  }

  public moveToLineStart(): void {
    const { line } = this.indexToLineCol(this.cursorPosition)
    this.cursorPosition = this.lineColToIndex(line, 0)
  }

  public moveToLineEnd(): void {
    const { line } = this.indexToLineCol(this.cursorPosition)
    const lines = this.currentInput.split('\n')
    const lineLength = lines[line].length
    this.cursorPosition = this.lineColToIndex(line, lineLength)
  }

  public backspaceOneForTesting(): void {
    if (this.cursorPosition > 0) {
      const before = this.currentInput.slice(0, this.cursorPosition - 1)
      const after = this.currentInput.slice(this.cursorPosition)
      this.currentInput = before + after
      this.cursorPosition--
    }
  }

  public deleteOneForTesting(): void {
    if (this.cursorPosition < this.currentInput.length) {
      const before = this.currentInput.slice(0, this.cursorPosition)
      const after = this.currentInput.slice(this.cursorPosition + 1)
      this.currentInput = before + after
    }
  }

  // Navigation and display methods
  private navigateHistory(direction: 'up' | 'down'): void {
    if (direction === 'up') {
      if (this.historyIndex === -1) {
        // Starting history navigation
        this.originalInput = this.currentInput
        this.historyBrowseActive = true

        // Clear suggestions when entering history mode
        this.currentSuggestion = ''
        this.isShowingSuggestions = false

        // For empty input, get the most recent command
        if (this.currentInput === '') {
          if (this.shell.history.length > 0) {
            this.historyIndex = 0
            this.currentInput = this.shell.history[this.shell.history.length - 1]
            this.cursorPosition = this.currentInput.length
          }
          return
        }
      }

      // Find next matching history item (including duplicates)
      const prefix = this.originalInput
      let newIndex = this.historyIndex + 1

      while (newIndex < this.shell.history.length) {
        const historyItem = this.shell.history[this.shell.history.length - 1 - newIndex]
        if (historyItem.startsWith(prefix)) {
          this.historyIndex = newIndex
          this.currentInput = historyItem
          this.cursorPosition = this.currentInput.length
          return
        }
        newIndex++
      }
    }
    else {
      // Moving down in history
      if (this.historyIndex > 0) {
        // Find previous matching history item
        const prefix = this.originalInput
        let newIndex = this.historyIndex - 1

        while (newIndex >= 0) {
          const historyItem = this.shell.history[this.shell.history.length - 1 - newIndex]
          if (historyItem.startsWith(prefix)) {
            this.historyIndex = newIndex
            this.currentInput = historyItem
            this.cursorPosition = this.currentInput.length
            return
          }
          newIndex--
        }

        // No more matching history, restore original input
        this.historyIndex = -1
        this.currentInput = this.originalInput
        this.cursorPosition = this.currentInput.length
        this.historyBrowseActive = false
      }
      else if (this.historyIndex === 0) {
        // At the most recent history item, restore original input
        this.historyIndex = -1
        this.currentInput = this.originalInput
        this.cursorPosition = this.currentInput.length
        this.historyBrowseActive = false
      }
      else if (!this.historyBrowseActive && this.currentInput === '') {
        // Down on empty prompt when not browsing - do nothing
      }
    }
  }

  private updateDisplay(prompt: string): void {
    // Clear the current line and any suggestion lines below
    process.stdout.write('\r\x1B[2K')

    // Apply syntax highlighting if enabled
    const displayText = this.options.syntaxHighlight
      ? this.applySyntaxHighlighting(this.currentInput)
      : this.currentInput

    // Show inline suggestion only if not browsing history, not showing suggestions list, and not in reverse search
    let inlineSuggestion = ''
    if (!this.historyBrowseActive && !this.isShowingSuggestions && !this.reverseSearchManager.isActive() && this.currentSuggestion) {
      inlineSuggestion = `${this.options.suggestionColor}${this.currentSuggestion}\x1B[0m`
    }

    // Write the prompt, current input, and inline suggestion
    const fullText = prompt + displayText + inlineSuggestion
    process.stdout.write(fullText)

    // Handle suggestions list display
    if (this.isShowingSuggestions) {
      // Use stored grouped data for rendering if available, otherwise get fresh data
      const groups = this.groupedActive && this.groupedForRender.length > 0
        ? this.groupedForRender
        : (() => {
            const completions = this.shell.getCompletions?.(this.currentInput, this.cursorPosition)
            return Array.isArray(completions)
              ? completions.filter(item =>
                typeof item === 'object' && item !== null && 'title' in item && 'items' in item,
              ) as Array<{ title: string, items: string[] }>
              : []
          })()

      if (groups.length > 0) {
        // Render grouped suggestions
        let flatIndex = 0
        for (const group of groups) {
          // Group header
          process.stdout.write(`\n\x1B[2K  ${group.title.toUpperCase()}:`)

          // Group items
          for (const item of group.items) {
            const isSelected = flatIndex === this.selectedIndex
            const prefix = isSelected ? '> ' : '  '
            const color = isSelected ? '\x1B[7m' : ''
            const reset = isSelected ? '\x1B[0m' : ''
            const brackets = isSelected ? '' : '' // No brackets for selected items
            process.stdout.write(`\n\x1B[2K${prefix}${color}${brackets}${item}${brackets}${reset}`)
            flatIndex++
          }
        }
      }
      else if (this.suggestions.length > 0) {
        // Render regular suggestions
        for (let i = 0; i < this.suggestions.length; i++) {
          const suggestion = this.suggestions[i]
          const isSelected = i === this.selectedIndex
          const prefix = isSelected ? '> ' : '  '
          const color = isSelected ? '\x1B[7m' : '' // Reverse video for selected
          const reset = isSelected ? '\x1B[0m' : ''
          process.stdout.write(`\n\x1B[2K${prefix}${color}${suggestion}${reset}`)
        }
      }
    }

    // Position the cursor correctly (after prompt + input, before inline suggestion)
    // For multi-line prompts, we need to position relative to the last line only
    const promptLines = prompt.split('\n')
    const lastLinePrompt = promptLines[promptLines.length - 1] || ''
    const visualLastLineWidth = this.getVisualWidth(lastLinePrompt)
    const cursorPos = visualLastLineWidth + this.cursorPosition
    process.stdout.write(`\x1B[${cursorPos + 1}G`) // Move to column (1-based)
    
    // Ensure cursor is visible
    process.stdout.write('\x1B[?25h') // Show cursor
  }

  private getVisualWidth(text: string): number {
    // Remove ANSI escape sequences to get the actual visual width
    // eslint-disable-next-line no-control-regex
    return text.replace(/\x1B\[[0-9;]*[mGKHfJ]/g, '').length
  }

  private applySyntaxHighlighting(input: string): string {
    if (!this.options.syntaxHighlight)
      return input
    return renderHighlighted(input, this.options.syntaxColors, this.options.highlightColor)
  }

  // Initialize keypress handler
  private initializeKeypressHandler(): void {
    this.handleKeypress = (str: string, key: { name: string, ctrl: boolean, meta: boolean, shift: boolean } | undefined): void => {
      if (!key)
        return

      // Handle Ctrl+C
      if (key.ctrl && key.name === 'c') {
        // Clear input but stay on same line with fresh prompt
        this.currentInput = ''
        this.cursorPosition = 0
        this.historyIndex = -1
        this.originalInput = ''
        this.isShowingSuggestions = false
        this.suggestions = []
        this.selectedIndex = 0
        this.currentSuggestion = ''
        this.historyBrowseActive = false
        this.groupedActive = false
        this.groupedForRender = []
        
        // Move to new line and show fresh prompt
        process.stdout.write('\n')
        this.updateDisplay('❯ ')
        return
      }
      // Handle arrow keys for history navigation
      else if (key.name === 'up') {
        this.navigateHistory('up')
        this.updateDisplay('❯ ')
      }
      else if (key.name === 'down') {
        this.navigateHistory('down')
        this.updateDisplay('❯ ')
      }
      else if (key.name === 'left') {
        this.cursorPosition = Math.max(0, this.cursorPosition - 1)
      }
      else if (key.name === 'right') {
        this.cursorPosition = Math.min(this.currentInput.length, this.cursorPosition + 1)
      }
      // Handle home/end
      else if (key.name === 'home' || (key.ctrl && key.name === 'a')) {
        this.moveToLineStart()
      }
      else if (key.name === 'end' || (key.ctrl && key.name === 'e')) {
        this.moveToLineEnd()
      }
      // Handle backspace
      else if (key.name === 'backspace') {
        if (this.cursorPosition > 0) {
          const before = this.currentInput.slice(0, this.cursorPosition - 1)
          const after = this.currentInput.slice(this.cursorPosition)
          this.currentInput = before + after
          this.cursorPosition--
          this.updateSuggestions()
        }
      }
      // Handle delete
      else if (key.name === 'delete') {
        if (this.cursorPosition < this.currentInput.length) {
          const before = this.currentInput.slice(0, this.cursorPosition)
          const after = this.currentInput.slice(this.cursorPosition + 1)
          this.currentInput = before + after
          this.updateSuggestions()
        }
      }
      // Handle enter
      else if (key.name === 'return') {
        process.stdout.write('\n')
        this.rl?.close()
      }
      // Handle regular character input
      else if (str && str.length === 1 && !key.ctrl && !key.meta) {
        const before = this.currentInput.slice(0, this.cursorPosition)
        const after = this.currentInput.slice(this.cursorPosition)
        this.currentInput = before + str + after
        this.cursorPosition++

        // Reset history browsing when typing
        this.historyBrowseActive = false
        this.historyIndex = -1

        // Get suggestions for the current input
        this.updateSuggestions()
      }

      // Update display after any input change (but not for Ctrl+C or arrow keys)
      if (key.name === 'backspace' || key.name === 'delete' || (str && str.length === 1 && !key.ctrl && !key.meta) || key.name === 'left' || key.name === 'right' || key.name === 'home' || key.name === 'end') {
        this.updateDisplay('❯ ')
      }
    }
  }

  // Update suggestions based on current input
  private updateSuggestions(): void {
    if (!this.shell.getCompletions) {
      return
    }

    try {
      const completions = this.shell.getCompletions(this.currentInput, this.cursorPosition)
      let suggestions: string[] = []

      // Handle grouped completions
      const groups = completions.filter(item =>
        typeof item === 'object' && item !== null && 'title' in item && 'items' in item,
      ) as Array<{ title: string, items: string[] }>

      if (groups.length > 0) {
        // Flatten grouped completions
        for (const group of groups) {
          suggestions.push(...group.items)
        }

        // Add history as a trailing group if we have matching history items
        if (this.shell.history && this.currentInput.trim()) {
          const historyMatches = this.getMatchingHistory(this.currentInput.trim())
          if (historyMatches.length > 0) {
            // Store the enhanced groups for rendering (will be used by updateDisplay)
            this.groupedForRender = [...groups, { title: 'History', items: historyMatches }]
            suggestions.push(...historyMatches)
          }
          else {
            this.groupedForRender = groups
          }
        }
        else {
          this.groupedForRender = groups
        }

        this.groupedActive = true
      }
      else {
        // Handle regular completions (strings or objects with text property)
        suggestions = completions.map(item =>
          typeof item === 'string' ? item : (item as any).text || String(item),
        ).filter(s => typeof s === 'string' && s.length > 0)
        this.groupedActive = false
      }

      // Set the first suggestion as inline suggestion if available
      if (suggestions.length > 0) {
        const currentText = this.currentInput.trim()
        const firstSuggestion = suggestions[this.selectedIndex] || suggestions[0]

        // For typo corrections, show the full suggestion if it's different from current input
        if (currentText && firstSuggestion !== currentText) {
          if (firstSuggestion.toLowerCase().startsWith(currentText.toLowerCase())) {
            // Show remaining part of suggestion
            this.currentSuggestion = firstSuggestion.slice(currentText.length)
          }
          else {
            // Show full suggestion for typo corrections (e.g., 'gti' -> 'git')
            this.currentSuggestion = firstSuggestion
          }
        }
        else if (!currentText && firstSuggestion) {
          this.currentSuggestion = firstSuggestion
        }
        else {
          this.currentSuggestion = ''
        }
      }
      else {
        this.currentSuggestion = ''
      }

      this.suggestions = suggestions
    }
    catch {
      this.currentSuggestion = ''
      this.suggestions = []
    }
  }

  // Public methods
  public async readLine(prompt: string): Promise<string> {
    return new Promise((resolve) => {
      this.rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        prompt: '',
        terminal: true,
        historySize: 0, // We handle history ourselves
      })

      // Set up keypress listener
      const onKeypress = (str: string, key: { name: string, ctrl: boolean, meta?: boolean, shift?: boolean }) => {
        this.handleKeypress(str, { ...key, meta: key.meta || false, shift: key.shift || false })
      }
      
      // Store the listener reference for proper cleanup
      this.keypressListener = onKeypress
      process.stdin.on('keypress', onKeypress)

      // Initial display
      this.updateDisplay(prompt)

      // Handle line input
      this.rl.on('line', (input) => {
        // Clear current line and move to new line
        process.stdout.write('\r\x1B[2K\n')
        // Reset state after command execution
        this.reset()
        resolve(input)
        this.cleanup()
      })

      // Handle close
      this.rl.on('close', () => {
        resolve('') // Resolve with empty string on close
        this.cleanup()
      })
    })
  }

  // Clean up resources
  private cleanup(): void {
    if (this.rl) {
      // Remove our specific keypress listener
      if (this.keypressListener) {
        process.stdin.removeListener('keypress', this.keypressListener)
        this.keypressListener = undefined
      }
      this.rl.close()
      this.rl = null
    }
  }

  // Reset input state
  public reset(): void {
    this.currentInput = ''
    this.cursorPosition = 0
    this.historyIndex = -1
    this.originalInput = ''
    this.isShowingSuggestions = false
    this.suggestions = []
    this.selectedIndex = 0
    this.currentSuggestion = ''
    this.historyBrowseActive = false
    this.groupedActive = false
    this.groupedForRender = []
  }

  // Get completion text from various completion types
  private getCompletionText(comp: string | { text: string } | { items: Array<string | { text: string }> }): string {
    if (typeof comp === 'string')
      return comp
    if ('text' in comp)
      return comp.text
    if ('items' in comp && comp.items.length > 0) {
      const first = comp.items[0]
      return typeof first === 'string' ? first : first.text
    }
    return ''
  }

  // Reverse search functionality
  public startReverseSearch(): void {
    this.reverseSearchManager.start()
    this.currentInput = this.reverseSearchManager.getCurrentMatch()
    this.cursorPosition = this.currentInput.length
    this.updateReverseSearch()
  }

  public cycleReverseSearch(): void {
    const result = this.reverseSearchManager.cycle()
    if (result) {
      this.currentInput = result
      this.cursorPosition = this.currentInput.length
      this.updateReverseSearch()
    }
  }

  public cancelReverseSearch(): void {
    this.reverseSearchManager.cancel()
    this.currentInput = ''
    this.cursorPosition = 0
  }

  public updateReverseSearch(query?: string): void {
    if (query !== undefined) {
      const result = this.reverseSearchManager.update(query)
      if (result) {
        this.currentInput = result
        this.cursorPosition = this.currentInput.length
      }
    }
    this.updateReverseSearchDisplay()
  }

  private updateReverseSearchDisplay(): void {
    if (!this.reverseSearchManager.isActive()) {
      return
    }

    const status = this.reverseSearchStatus()
    process.stdout.write(`\r${status}`)

    // Safety check for terminal columns - fallback to end of status if undefined
    const columns = process.stdout.columns
    if (typeof columns === 'number' && !isNaN(columns) && columns > 0) {
      readline.cursorTo(process.stdout, columns - 1)
    } else {
      // Fallback: position cursor at end of status line
      readline.cursorTo(process.stdout, status.length)
    }
  }

  public reverseSearchStatus(): string {
    return this.reverseSearchManager.getStatus()
  }

  // Get the current input for testing
  public getCurrentInputForTesting(): string {
    return this.currentInput
  }

  // Get the current cursor position for testing
  public getCursorPositionForTesting(): number {
    return this.cursorPosition
  }

  /**
   * Expands history references in the input string
   * @param input Input string containing history references
   * @returns Expanded string with history references replaced
   */
  private expandHistory(input: string): string {
    if (!input.includes('!'))
      return input

    // Use shell history if available, otherwise fall back to shared history
    const history = this.shell.history || sharedHistory.getHistory()

    // Handle !! - replace with last command
    input = input.replace(/!!/g, () => {
      return history[history.length - 1] || ''
    })

    // Handle !n (where n is a number) - replace with nth command (1-based)
    input = input.replace(/!(\d+)/g, (match, n) => {
      const index = Number.parseInt(n, 10) - 1
      return (index >= 0 && index < history.length)
        ? history[index]
        : ''
    })

    // Handle !prefix - replace with most recent matching command
    input = input.replace(/!([^\s!]+)/g, (match, prefix) => {
      // Find the most recent command that starts with the prefix
      for (let i = history.length - 1; i >= 0; i--) {
        if (history[i].startsWith(prefix)) {
          return history[i]
        }
      }
      // If no match, remove the !prefix
      return ''
    })

    return input
  }

  // Get matching history items for grouped completions
  private getMatchingHistory(prefix: string): string[] {
    if (!this.shell.history || !prefix) {
      return []
    }

    const matches: string[] = []
    const seen = new Set<string>()

    // Search from most recent to oldest
    for (let i = this.shell.history.length - 1; i >= 0; i--) {
      const historyItem = this.shell.history[i]
      if (historyItem.startsWith(prefix) && !seen.has(historyItem)) {
        matches.push(historyItem)
        seen.add(historyItem)

        // Limit to maxSuggestions to avoid overwhelming the display
        if (matches.length >= this.options.maxSuggestions) {
          break
        }
      }
    }

    return matches
  }

  // Update display for testing
  public updateDisplayForTesting(prompt: string): void {
    this.updateDisplay(prompt)
  }

  // Apply selected completion
  public applySelectedCompletion(): void {
    // Handle grouped completions - use stored grouped data if available
    const groups = this.groupedActive && this.groupedForRender.length > 0
      ? this.groupedForRender
      : (() => {
          const completions = this.shell.getCompletions?.(this.currentInput, this.cursorPosition)
          return Array.isArray(completions)
            ? completions.filter(item =>
              typeof item === 'object' && item !== null && 'title' in item && 'items' in item,
            ) as Array<{ title: string, items: string[] }>
            : []
        })()

    if (groups.length > 0) {
      // Flatten grouped completions to find the selected item
      const flatItems: string[] = []
      for (const group of groups) {
        flatItems.push(...group.items)
      }

      const completion = flatItems[this.selectedIndex]
      if (completion) {
        this.currentInput = completion
        this.cursorPosition = completion.length
        this.suggestions = []
        this.selectedIndex = 0
        this.isShowingSuggestions = false
      }
      return
    }

    // Handle regular suggestions
    if (this.suggestions.length === 0)
      return

    const completion = this.suggestions[this.selectedIndex]
    if (!completion)
      return

    this.currentInput = completion
    this.cursorPosition = completion.length
    this.suggestions = []
    this.selectedIndex = 0
    this.isShowingSuggestions = false
  }

  // Key helper methods
  public moveCursorLeft(): void {
    this.cursorPosition = Math.max(0, this.cursorPosition - 1)
  }

  public moveCursorRight(): void {
    this.cursorPosition = Math.min(this.currentInput.length, this.cursorPosition + 1)
  }

  public moveWordLeft(): void {
    if (this.cursorPosition === 0)
      return

    let pos = this.cursorPosition - 1
    const input = this.currentInput

    // Skip any whitespace
    while (pos > 0 && /\s/.test(input[pos])) {
      pos--
    }

    // If we're at the start of input, we're done
    if (pos === 0) {
      this.cursorPosition = 0
      return
    }

    // Special case: if we're at a non-word char (like -), move past it
    if (!/\w/.test(input[pos]) && pos > 0) {
      pos--
    }

    // Now find the start of the word
    while (pos > 0) {
      // Break if we hit whitespace
      if (/\s/.test(input[pos - 1]))
        break

      // Break if we hit a word boundary
      const current = input[pos]
      const prev = input[pos - 1]

      // If current is word char and prev is not (or vice versa), we've found a boundary
      const currentIsWord = /\w/.test(current)
      const prevIsWord = /\w/.test(prev)
      if (currentIsWord !== prevIsWord) {
        // If we're at the start of a word, stop here
        if (currentIsWord && !prevIsWord)
          break
        // If we're at the end of a word, move to the start of it
        if (!currentIsWord && prevIsWord) {
          pos--
          break
        }
      }

      pos--
    }

    this.cursorPosition = Math.max(0, pos)
  }

  public moveWordRight(): void {
    if (this.cursorPosition >= this.currentInput.length)
      return

    let pos = this.cursorPosition
    const input = this.currentInput

    // Skip any leading whitespace
    while (pos < input.length && /\s/.test(input[pos])) {
      pos++
    }

    // If we're at a word character, skip to the end of the word
    if (pos < input.length) {
      // Handle word characters
      while (pos < input.length && /[\w-]/.test(input[pos])) {
        pos++
      }
      // Handle non-word, non-whitespace characters (like punctuation)
      while (pos < input.length && !/[\w\s-]/.test(input[pos])) {
        pos++
      }
    }

    this.cursorPosition = Math.min(pos, input.length)
  }

  public deleteCharUnderCursor(): void {
    if (this.cursorPosition < this.currentInput.length) {
      this.currentInput = this.currentInput.slice(0, this.cursorPosition)
        + this.currentInput.slice(this.cursorPosition + 1)
    }
  }

  public killToEnd(): void {
    this.currentInput = this.currentInput.slice(0, this.cursorPosition)
  }

  public killToStart(): void {
    this.currentInput = this.currentInput.slice(this.cursorPosition)
    this.cursorPosition = 0
  }

  public deleteWordLeft(): void {
    if (this.cursorPosition === 0)
      return

    const beforeCursor = this.currentInput.slice(0, this.cursorPosition)
    const afterCursor = this.currentInput.slice(this.cursorPosition)

    // Find the start of the previous word
    // Using [^\w\s-] to match non-word characters (except spaces and hyphens)
    const match = beforeCursor.match(/([\w-]+|[^\w\s-]+)\s*$/)
    if (match) {
      this.currentInput = beforeCursor.slice(0, match.index) + afterCursor
      this.cursorPosition = match.index || 0
    }
  }

  public deleteWordRight(): void {
    if (this.cursorPosition >= this.currentInput.length)
      return

    const beforeCursor = this.currentInput.slice(0, this.cursorPosition)
    const afterCursor = this.currentInput.slice(this.cursorPosition)

    // Find the end of the next word
    const match = afterCursor.match(/^(\s*[^\w-]\s*|\s*\w+)/)
    if (match) {
      this.currentInput = beforeCursor + afterCursor.slice(match[0].length)
    }
  }

  // History navigation for testing
  public historyUpForTesting(): void {
    this.navigateHistory('up')
  }

  public historyDownForTesting(): void {
    this.navigateHistory('down')
  }

  // Grouped navigation for multi-column suggestion lists
  private navigateGrouped(direction: 'up' | 'down' | 'left' | 'right'): boolean {
    if (!this.isShowingSuggestions) {
      return false
    }

    // Get grouped completions from shell
    const completions = this.shell.getCompletions?.(this.currentInput, this.cursorPosition)
    if (!Array.isArray(completions) || completions.length === 0) {
      return false
    }

    // Check if completions are grouped (have title property)
    const groups = completions.filter(item =>
      typeof item === 'object' && item !== null && 'title' in item && 'items' in item,
    ) as Array<{ title: string, items: string[] }>

    if (groups.length === 0) {
      return false
    }

    // Build flat list with group information
    const flatItems: Array<{ text: string, groupIndex: number, itemIndex: number }> = []
    groups.forEach((group, groupIndex) => {
      group.items.forEach((item, itemIndex) => {
        flatItems.push({ text: item, groupIndex, itemIndex })
      })
    })

    if (flatItems.length === 0 || this.selectedIndex >= flatItems.length) {
      return false
    }

    const currentItem = flatItems[this.selectedIndex]
    const currentGroup = groups[currentItem.groupIndex]

    // Calculate layout for current group
    const terminalWidth = process.stdout.columns || 80
    const maxItemLength = Math.max(...currentGroup.items.map(item => item.length))
    const colWidth = Math.min(maxItemLength + 2, Math.floor(terminalWidth / 2))
    const cols = Math.max(1, Math.floor(terminalWidth / colWidth))

    // Calculate current row and column within group
    const currentRow = Math.floor(currentItem.itemIndex / cols)
    const currentCol = currentItem.itemIndex % cols

    let newSelectedIndex = this.selectedIndex

    switch (direction) {
      case 'left': {
        // Move left within current group, wrap to end if at start
        const newItemIndex = currentItem.itemIndex === 0
          ? currentGroup.items.length - 1
          : currentItem.itemIndex - 1

        // Find the flat index for this group item
        let flatIndex = 0
        for (let i = 0; i < currentItem.groupIndex; i++) {
          flatIndex += groups[i].items.length
        }
        newSelectedIndex = flatIndex + newItemIndex
        break
      }

      case 'right': {
        // Move right within current group, wrap to start if at end
        const newItemIndex = currentItem.itemIndex === currentGroup.items.length - 1
          ? 0
          : currentItem.itemIndex + 1

        // Find the flat index for this group item
        let flatIndex = 0
        for (let i = 0; i < currentItem.groupIndex; i++) {
          flatIndex += groups[i].items.length
        }
        newSelectedIndex = flatIndex + newItemIndex
        break
      }

      case 'up': {
        // Move to previous group, preserving row position
        if (currentItem.groupIndex > 0) {
          const targetGroup = groups[currentItem.groupIndex - 1]
          const targetCols = Math.max(1, Math.floor(terminalWidth / colWidth))
          const targetRows = Math.ceil(targetGroup.items.length / targetCols)

          // Preserve row, but clamp to available rows in target group
          const targetRow = Math.min(currentRow, targetRows - 1)
          const targetCol = Math.min(currentCol, targetCols - 1)
          let targetItemIndex = targetRow * targetCols + targetCol

          // Clamp to actual items in target group
          targetItemIndex = Math.min(targetItemIndex, targetGroup.items.length - 1)

          // Find flat index
          let flatIndex = 0
          for (let i = 0; i < currentItem.groupIndex - 1; i++) {
            flatIndex += groups[i].items.length
          }
          newSelectedIndex = flatIndex + targetItemIndex
        }
        break
      }

      case 'down': {
        // First try to move down within current group
        const nextRowIndex = (currentRow + 1) * cols + currentCol
        if (nextRowIndex < currentGroup.items.length) {
          // Move down within current group
          let flatIndex = 0
          for (let i = 0; i < currentItem.groupIndex; i++) {
            flatIndex += groups[i].items.length
          }
          newSelectedIndex = flatIndex + nextRowIndex
        }
        else if (currentItem.groupIndex < groups.length - 1) {
          // Move to next group, preserving column position
          const targetGroup = groups[currentItem.groupIndex + 1]
          const targetCols = Math.max(1, Math.floor(terminalWidth / colWidth))

          // Preserve column, start from first row
          const targetCol = Math.min(currentCol, targetCols - 1)
          let targetItemIndex = targetCol

          // Clamp to actual items in target group
          targetItemIndex = Math.min(targetItemIndex, targetGroup.items.length - 1)

          // Find flat index
          let flatIndex = 0
          for (let i = 0; i <= currentItem.groupIndex; i++) {
            flatIndex += groups[i].items.length
          }
          newSelectedIndex = flatIndex + targetItemIndex
        }
        break
      }
    }

    // Update selected index if it changed
    if (newSelectedIndex !== this.selectedIndex && newSelectedIndex >= 0 && newSelectedIndex < flatItems.length) {
      this.selectedIndex = newSelectedIndex
      return true
    }

    return false
  }

  // Shell mode management
  public setShellMode(_enabled: boolean): void {
    // This method is called by the shell to indicate it manages the prompt
    // Currently we don't need to store this state, but the method needs to exist
    // for compatibility with the shell initialization
  }
}
