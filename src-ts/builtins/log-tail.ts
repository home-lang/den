import type { BuiltinCommand, CommandResult } from './types'

export const logTail: BuiltinCommand = {
  name: 'log-tail',
  description: 'Enhanced tail with filtering and log analysis',
  usage: 'log-tail FILE [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: log-tail FILE [options]

Enhanced tail with filtering and log analysis capabilities.

Options:
  -n, --lines NUMBER         Number of lines to show (default: 10)
  -f, --follow              Follow file changes (watch mode)
  -F, --retry               Retry if file doesn't exist or gets deleted
  -c, --bytes NUMBER        Show last N bytes instead of lines
  -q, --quiet               Suppress headers
  -v, --verbose             Verbose output
  --filter PATTERN          Filter lines matching pattern (regex)
  --exclude PATTERN         Exclude lines matching pattern (regex)
  --level LEVEL             Filter by log level (error, warn, info, debug)
  --since TIME              Show logs since time (e.g., "1h", "30m", "2024-01-01")
  --until TIME              Show logs until time
  --format FORMAT           Output format: plain, json, colored (default: colored)
  --highlight PATTERN       Highlight matching patterns
  --stats                   Show log statistics
  --no-color                Disable colored output

Examples:
  log-tail app.log                          Show last 10 lines
  log-tail app.log -n 50                    Show last 50 lines
  log-tail app.log -f                       Follow file changes
  log-tail app.log --filter "ERROR"         Show only ERROR lines
  log-tail app.log --level error            Show only error level logs
  log-tail app.log --since "1h"             Show logs from last hour
  log-tail app.log --stats                  Show log statistics
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'log-tail: missing file argument\nUsage: log-tail FILE [options]\n',
        duration: performance.now() - start,
      }
    }

    try {
      const result = await executeLogTail(args)
      return {
        exitCode: 0,
        stdout: result.output,
        stderr: result.verbose || '',
        duration: performance.now() - start,
      }
    } catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `log-tail: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface LogTailOptions {
  file: string
  lines: number
  bytes?: number
  follow: boolean
  retry: boolean
  quiet: boolean
  verbose: boolean
  filter?: RegExp
  exclude?: RegExp
  level?: string
  since?: Date
  until?: Date
  format: 'plain' | 'json' | 'colored'
  highlight?: RegExp
  stats: boolean
  noColor: boolean
}

interface LogStats {
  totalLines: number
  errorLines: number
  warnLines: number
  infoLines: number
  debugLines: number
  timeRange?: { start: Date; end: Date }
}

async function executeLogTail(args: string[]): Promise<{ output: string; verbose?: string }> {
  const options: LogTailOptions = {
    file: args[0],
    lines: 10,
    follow: false,
    retry: false,
    quiet: false,
    verbose: false,
    format: 'colored',
    stats: false,
    noColor: false,
  }

  // Parse arguments
  let i = 1
  while (i < args.length) {
    const arg = args[i]

    switch (arg) {
      case '-n':
      case '--lines':
        options.lines = parseInt(args[++i]) || 10
        break
      case '-f':
      case '--follow':
        options.follow = true
        break
      case '-F':
      case '--retry':
        options.retry = true
        options.follow = true
        break
      case '-c':
      case '--bytes':
        options.bytes = parseInt(args[++i]) || 1024
        break
      case '-q':
      case '--quiet':
        options.quiet = true
        break
      case '-v':
      case '--verbose':
        options.verbose = true
        break
      case '--filter':
        options.filter = new RegExp(args[++i], 'i')
        break
      case '--exclude':
        options.exclude = new RegExp(args[++i], 'i')
        break
      case '--level':
        options.level = args[++i].toLowerCase()
        break
      case '--since':
        options.since = parseTimeInput(args[++i])
        break
      case '--until':
        options.until = parseTimeInput(args[++i])
        break
      case '--format':
        const format = args[++i]
        if (['plain', 'json', 'colored'].includes(format)) {
          options.format = format as any
        }
        break
      case '--highlight':
        options.highlight = new RegExp(args[++i], 'gi')
        break
      case '--stats':
        options.stats = true
        break
      case '--no-color':
        options.noColor = true
        break
      default:
        throw new Error(`Unknown option: ${arg}`)
    }
    i++
  }

  // Check if file exists
  try {
    const file = Bun.file(options.file)
    if (!(await file.exists())) {
      if (options.retry) {
        return { output: `log-tail: waiting for ${options.file} to appear...` }
      }
      throw new Error(`File not found: ${options.file}`)
    }
  } catch (error) {
    throw new Error(`Cannot access file: ${error.message}`)
  }

  const result = await readLogFile(options)
  return result
}

async function readLogFile(options: LogTailOptions): Promise<{ output: string; verbose?: string }> {
  try {
    const file = Bun.file(options.file)
    const content = await file.text()

    let lines = content.split('\n').filter(line => line.trim() !== '')

    // Apply filtering
    if (options.filter) {
      lines = lines.filter(line => options.filter!.test(line))
    }

    if (options.exclude) {
      lines = lines.filter(line => !options.exclude!.test(line))
    }

    if (options.level) {
      lines = lines.filter(line => containsLogLevel(line, options.level!))
    }

    if (options.since || options.until) {
      lines = lines.filter(line => {
        const timestamp = extractTimestamp(line)
        if (!timestamp) return true // Include lines without timestamps

        if (options.since && timestamp < options.since) return false
        if (options.until && timestamp > options.until) return false
        return true
      })
    }

    // Get the last N lines (or bytes)
    if (options.bytes) {
      const fullText = lines.join('\n')
      const truncated = fullText.slice(-options.bytes)
      lines = truncated.split('\n')
    } else {
      lines = lines.slice(-options.lines)
    }

    // Generate output
    if (options.stats) {
      const stats = generateLogStats(lines)
      return { output: formatLogStats(stats, options) }
    }

    return { output: formatLogOutput(lines, options) }

  } catch (error) {
    throw new Error(`Error reading file: ${error.message}`)
  }
}

function parseTimeInput(input: string): Date {
  // Handle relative time (e.g., "1h", "30m", "2d")
  const relativeMatch = input.match(/^(\d+)([hdm])$/)
  if (relativeMatch) {
    const value = parseInt(relativeMatch[1])
    const unit = relativeMatch[2]
    const now = new Date()

    switch (unit) {
      case 'h':
        return new Date(now.getTime() - value * 60 * 60 * 1000)
      case 'm':
        return new Date(now.getTime() - value * 60 * 1000)
      case 'd':
        return new Date(now.getTime() - value * 24 * 60 * 60 * 1000)
    }
  }

  // Handle absolute time
  const date = new Date(input)
  if (isNaN(date.getTime())) {
    throw new Error(`Invalid time format: ${input}`)
  }
  return date
}

function containsLogLevel(line: string, level: string): boolean {
  const levelPatterns = {
    error: /\b(error|err|fatal|critical)\b/i,
    warn: /\b(warn|warning)\b/i,
    info: /\b(info|information)\b/i,
    debug: /\b(debug|trace)\b/i,
  }

  const pattern = levelPatterns[level as keyof typeof levelPatterns]
  return pattern ? pattern.test(line) : false
}

function extractTimestamp(line: string): Date | null {
  // Try various timestamp formats
  const patterns = [
    /(\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:\.\d{3})?(?:Z|[+-]\d{2}:\d{2})?)/,
    /(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})/,
    /(\d{2}\/\d{2}\/\d{4}\s+\d{2}:\d{2}:\d{2})/,
  ]

  for (const pattern of patterns) {
    const match = line.match(pattern)
    if (match) {
      const date = new Date(match[1])
      if (!isNaN(date.getTime())) {
        return date
      }
    }
  }

  return null
}

function generateLogStats(lines: string[]): LogStats {
  const stats: LogStats = {
    totalLines: lines.length,
    errorLines: 0,
    warnLines: 0,
    infoLines: 0,
    debugLines: 0,
  }

  const timestamps: Date[] = []

  for (const line of lines) {
    if (containsLogLevel(line, 'error')) stats.errorLines++
    else if (containsLogLevel(line, 'warn')) stats.warnLines++
    else if (containsLogLevel(line, 'info')) stats.infoLines++
    else if (containsLogLevel(line, 'debug')) stats.debugLines++

    const timestamp = extractTimestamp(line)
    if (timestamp) timestamps.push(timestamp)
  }

  if (timestamps.length > 0) {
    timestamps.sort((a, b) => a.getTime() - b.getTime())
    stats.timeRange = {
      start: timestamps[0],
      end: timestamps[timestamps.length - 1],
    }
  }

  return stats
}

function formatLogStats(stats: LogStats, options: LogTailOptions): string {
  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Log Statistics', '1;36'))
  lines.push(color('='.repeat(40), '36'))
  lines.push('')

  lines.push(`${color('Total Lines:', '1;33')} ${stats.totalLines}`)
  lines.push(`${color('Error Lines:', '1;31')} ${stats.errorLines}`)
  lines.push(`${color('Warning Lines:', '1;33')} ${stats.warnLines}`)
  lines.push(`${color('Info Lines:', '1;32')} ${stats.infoLines}`)
  lines.push(`${color('Debug Lines:', '1;34')} ${stats.debugLines}`)

  if (stats.timeRange) {
    lines.push('')
    lines.push(`${color('Time Range:', '1;33')}`)
    lines.push(`  Start: ${stats.timeRange.start.toISOString()}`)
    lines.push(`  End:   ${stats.timeRange.end.toISOString()}`)
  }

  return lines.join('\n')
}

function formatLogOutput(lines: string[], options: LogTailOptions): string {
  if (options.format === 'json') {
    const jsonLines = lines.map((line, index) => ({
      line: index + 1,
      content: line,
      timestamp: extractTimestamp(line)?.toISOString(),
      level: detectLogLevel(line),
    }))
    return JSON.stringify(jsonLines, null, 2)
  }

  if (options.format === 'plain' || options.noColor) {
    return lines.join('\n')
  }

  // Colored format
  return lines.map(line => colorizeLogLine(line, options)).join('\n')
}

function detectLogLevel(line: string): string | null {
  if (containsLogLevel(line, 'error')) return 'error'
  if (containsLogLevel(line, 'warn')) return 'warn'
  if (containsLogLevel(line, 'info')) return 'info'
  if (containsLogLevel(line, 'debug')) return 'debug'
  return null
}

function colorizeLogLine(line: string, options: LogTailOptions): string {
  if (options.noColor) return line

  let coloredLine = line

  // Color by log level
  const level = detectLogLevel(line)
  switch (level) {
    case 'error':
      coloredLine = `\x1b[31m${coloredLine}\x1b[0m` // Red
      break
    case 'warn':
      coloredLine = `\x1b[33m${coloredLine}\x1b[0m` // Yellow
      break
    case 'info':
      coloredLine = `\x1b[32m${coloredLine}\x1b[0m` // Green
      break
    case 'debug':
      coloredLine = `\x1b[34m${coloredLine}\x1b[0m` // Blue
      break
  }

  // Highlight patterns
  if (options.highlight) {
    coloredLine = coloredLine.replace(options.highlight, '\x1b[1;43m$&\x1b[0m')
  }

  return coloredLine
}