export interface AutoSuggestOptions {
  maxSuggestions?: number
  showInline?: boolean
  highlightColor?: string
  suggestionColor?: string
  // Keymap for line editing controls
  keymap?: 'emacs' | 'vi'
  // Enable lightweight syntax highlighting in input rendering
  syntaxHighlight?: boolean
  // Optional fine-grained colors for syntax tokens
  syntaxColors?: Partial<{
    command: string
    subcommand: string
    string: string
    operator: string
    variable: string
    flag: string
    number: string
    path: string
    comment: string
  }>
}

export interface InputState {
  currentInput: string
  currentSuggestion: string
  cursorPosition: number
  suggestions: string[]
  selectedIndex: number
  isShowingSuggestions: boolean
  isNavigatingSuggestions: boolean
}

export interface GroupedSuggestion {
  title: string
  items: Array<string | { text: string }>
}

export interface HistoryState {
  historyBrowseActive: boolean
  historyBrowseIndex: number
  historyBrowseSaved: string
  historyFilteredIndexes: number[]
  historyFilteredPosition: number
}

export interface ReverseSearchState {
  reverseSearchActive: boolean
  reverseSearchQuery: string
  reverseSearchMatches: string[]
  reverseSearchIndex: number
}

export interface ViModeState {
  viMode: 'insert' | 'normal'
}
