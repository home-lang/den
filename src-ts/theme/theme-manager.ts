import type { ThemeColors, ThemeConfig, ThemeGitColors, ThemeGitSymbols, ThemeSymbols } from '../types'
import process from 'node:process'
import { config } from '../config'

export class ThemeManager {
  private currentTheme: ThemeConfig
  private colorScheme: 'light' | 'dark' | 'auto' = 'auto'
  private systemColorScheme: 'light' | 'dark' = 'light'

  constructor(themeConfig?: ThemeConfig) {
    this.currentTheme = themeConfig || config.theme || {}
    this.detectSystemColorScheme()
    this.applyColorScheme()
  }

  private detectSystemColorScheme(): void {
    // In a terminal environment, we can check environment variables or terminal capabilities
    // For now, default to dark mode as most terminal environments use dark themes
    const termProgram = process.env.TERM_PROGRAM
    const _colorTerm = process.env.COLORTERM

    // Basic heuristic: assume dark mode for most terminal environments
    this.systemColorScheme = 'dark'

    // Could be extended to check specific terminal programs or user preferences
    if (termProgram === 'Apple_Terminal' || termProgram === 'iTerm.app') {
      // Could potentially detect light/dark mode through other means
      this.systemColorScheme = 'dark'
    }
  }

  private applyColorScheme(): void {
    const scheme = this.colorScheme === 'auto'
      ? this.systemColorScheme
      : this.colorScheme

    // In terminal environment, we don't manipulate DOM but could set environment variables
    // or update internal state for theme-aware components
    process.env.KRUSTY_THEME = scheme
  }

  public setColorScheme(scheme: 'light' | 'dark' | 'auto'): void {
    this.colorScheme = scheme
    this.applyColorScheme()
  }

  public getColorScheme(): 'light' | 'dark' | 'auto' {
    return this.colorScheme
  }

  public getColors(): ThemeColors {
    return this.currentTheme.colors || {}
  }

  public getSymbols(): ThemeSymbols {
    return this.currentTheme.symbols || {}
  }

  public getGitColors(): ThemeGitColors {
    return this.getColors().git || {}
  }

  public getGitSymbols(): ThemeGitSymbols {
    return this.getSymbols().git || {}
  }

  public formatGitStatus(status: {
    branch?: string
    ahead?: number
    behind?: number
    staged?: number
    unstaged?: number
    untracked?: number
    conflict?: boolean
  }): string {
    const { branch, ahead = 0, behind = 0, staged = 0, unstaged = 0, untracked = 0, conflict = false } = status
    if (!branch)
      return ''

    const parts: string[] = []
    const colors = this.getGitColors()
    const symbols = this.getGitSymbols()

    // Add branch name
    parts.push(`%F{${colors.branch || 'green'}}${symbols.branch || ''} ${branch}%f`)

    // Add ahead/behind indicators
    if (ahead > 0) {
      parts.push(`%F{${colors.ahead || 'green'}}${symbols.ahead || '↑'}${ahead}%f`)
    }
    if (behind > 0) {
      parts.push(`%F{${colors.behind || 'red'}}${symbols.behind || '↓'}${behind}%f`)
    }

    // Add status indicators
    if (conflict) {
      parts.push(`%F{${colors.conflict || 'red'}}${symbols.conflict || '!'}%f`)
    }
    if (staged > 0) {
      parts.push(`%F{${colors.staged || 'green'}}${symbols.staged || '+'}${staged}%f`)
    }
    if (unstaged > 0) {
      parts.push(`%F{${colors.unstaged || 'red'}}${symbols.unstaged || '!'}${unstaged}%f`)
    }
    if (untracked > 0) {
      parts.push(`%F{${colors.untracked || 'red'}}${symbols.untracked || '?'}${untracked}%f`)
    }

    return parts.join(' ')
  }

  public renderPrompt(left: string, right: string = ''): string {
    if (!this.currentTheme.prompt)
      return left

    let result = left

    // Apply right prompt if enabled and content exists
    if (this.currentTheme.enableRightPrompt && right) {
      const padding = Math.max(0, process.stdout.columns - (left.length + right.length) - 1)
      result = `${left}${' '.repeat(padding)}${right}`
    }

    return result
  }
}

export const themeManager: ThemeManager = new ThemeManager()
