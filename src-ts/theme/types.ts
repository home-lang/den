export type Color = string | number | null

export interface ThemeColors {
  // Basic colors
  primary: Color
  secondary: Color
  success: Color
  error: Color
  warning: Color
  info: Color

  // Text colors
  text: Color
  textDim: Color
  textInverted: Color

  // Background colors
  bg: Color
  bgHighlight: Color

  // Git status colors
  gitAdded: Color
  gitModified: Color
  gitDeleted: Color
  gitUntracked: Color
  gitStaged: Color
  gitConflict: Color
}

export interface PromptSegment {
  content: string
  fg?: Color
  bg?: Color
  bold?: boolean
  dim?: boolean
  italic?: boolean
  underline?: boolean
  inverted?: boolean
  hidden?: boolean
  strikethrough?: boolean
}

export interface Theme {
  name: string
  colors: ThemeColors

  // Prompt configuration
  prompt: {
    left: (segments: PromptSegment[]) => string
    right?: (segments: PromptSegment[]) => string
    separator: string
    separatorColor: Color
  }

  // Apply theme to shell
  apply?: () => void
}

export interface ThemeConfig {
  currentTheme: string
  themes: Record<string, Theme>
  enableRightPrompt: boolean
  enableGitStatus: boolean
}

export type ThemeSegment = string | PromptSegment | (() => string | PromptSegment)
