import * as process from 'node:process'
import { config } from './config'

/**
 * Log level type
 */
type LogLevel = 'debug' | 'info' | 'warn' | 'error'

/**
 * ANSI color codes for terminal output
 */
const ANSI_COLORS = {
  reset: '\u001B[0m',
  bold: '\u001B[1m',
  dim: '\u001B[2m',
  italic: '\u001B[3m',
  underline: '\u001B[4m',
  blink: '\u001B[5m',
  reverse: '\u001B[7m',
  hidden: '\u001B[8m',
  // Foreground colors
  black: '\u001B[30m',
  red: '\u001B[31m',
  green: '\u001B[32m',
  yellow: '\u001B[33m',
  blue: '\u001B[34m',
  magenta: '\u001B[35m',
  cyan: '\u001B[36m',
  white: '\u001B[37m',
  // Background colors
  bgBlack: '\u001B[40m',
  bgRed: '\u001B[41m',
  bgGreen: '\u001B[42m',
  bgYellow: '\u001B[43m',
  bgBlue: '\u001B[44m',
  bgMagenta: '\u001B[45m',
  bgCyan: '\u001B[46m',
  bgWhite: '\u001B[47m',
} as const

/**
 * Logger class with theme support
 */
export class Logger {
  private verbose: boolean
  private scopeName?: string
  private useColors: boolean

  constructor(verbose = false, scopeName?: string) {
    this.verbose = verbose || config.verbose
    this.scopeName = scopeName
    this.useColors = process.stdout.isTTY && !process.env.NO_COLOR
  }

  /**
   * Enable or disable verbose logging
   */
  setVerbose(verbose: boolean): void {
    this.verbose = verbose
  }

  /**
   * Create a new logger instance with a scope
   */
  withScope(scope: string): Logger {
    return new Logger(this.verbose, scope)
  }

  /**
   * Format a log message with scope and theme colors
   */
  private format(level: LogLevel, message: string): string {
    let formatted = ''

    // Add timestamp if timestamps are enabled in config
    const timestampsEnabled = Boolean(config.logging && 'timestamps' in config.logging && config.logging.timestamps)
    if (timestampsEnabled) {
      const now = new Date()
      const timestamp = now.toISOString()
      formatted += this.colorize(timestamp, 'dim')
      formatted += ' '
    }

    // Add log level
    const levelStr = this.getLevelString(level)
    formatted = `${formatted}${levelStr} `

    // Add scope if available
    if (this.scopeName) {
      formatted = `${formatted}${this.colorize(`[${this.scopeName}]`, 'dim')} `
    }

    // Add the actual message
    formatted += message

    return formatted
  }

  /**
   * Get formatted log level string with colors
   */
  private getLevelString(level: LogLevel): string {
    const prefixes = {
      debug: config.logging?.prefixes?.debug ?? 'DEBUG',
      info: config.logging?.prefixes?.info ?? 'INFO',
      warn: config.logging?.prefixes?.warn ?? 'WARN',
      error: config.logging?.prefixes?.error ?? 'ERROR',
    }

    const levelStr = prefixes[level]

    if (!this.useColors) {
      return `[${levelStr}]`
    }

    const colors = {
      debug: ANSI_COLORS.cyan,
      info: ANSI_COLORS.blue,
      warn: ANSI_COLORS.yellow,
      error: ANSI_COLORS.red,
    }

    return `${colors[level]}[${levelStr}]${ANSI_COLORS.reset}`
  }

  /**
   * Apply color to text if colors are enabled
   */
  private colorize(text: string, style: keyof typeof ANSI_COLORS | 'none' = 'none'): string {
    if (!this.useColors || style === 'none') {
      return text
    }
    return `${ANSI_COLORS[style]}${text}${ANSI_COLORS.reset}`
  }

  /**
   * Log a debug message
   */
  debug(message: string, ...args: any[]): void {
    if (!this.verbose)
      return
    const formatted = this.format('debug', message)
    const output = `${formatted}${args.length ? ` ${args.map(String).join(' ')}` : ''}\n`
    process.stdout.write(output)
  }

  /**
   * Log an info message
   */
  info(message: string, ...args: any[]): void {
    const formatted = this.format('info', message)
    const output = `${formatted}${args.length ? ` ${args.map(String).join(' ')}` : ''}\n`
    process.stdout.write(output)
  }

  /**
   * Log a warning message
   */
  warn(message: string, ...args: any[]): void {
    const formatted = this.format('warn', message)
    const output = `${formatted}${args.length ? ` ${args.map(String).join(' ')}` : ''}\n`
    process.stderr.write(output)
  }

  /**
   * Log an error message
   */
  error(message: string, ...args: any[]): void {
    const formatted = this.format('error', message)
    const output = `${formatted}${args.length ? ` ${args.map(String).join(' ')}` : ''}\n`
    process.stderr.write(output)
  }
}

// Create a default logger instance
export const logger: Logger = new Logger(config.verbose)
