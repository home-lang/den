import type { BuiltinCommand, CommandResult } from './types'

export const logParse: BuiltinCommand = {
  name: 'log-parse',
  description: 'Parse and analyze structured log files',
  usage: 'log-parse FILE [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: log-parse FILE [options]

Parse and analyze structured log files with various formats.

Options:
  -f, --format FORMAT       Log format: json, apache, nginx, csv, custom
  -p, --pattern PATTERN     Custom regex pattern for parsing
  -o, --output FORMAT       Output format: json, table, csv, summary (default: table)
  -s, --select FIELDS       Select specific fields (comma-separated)
  -w, --where CONDITION     Filter with conditions (e.g., "status>=400")
  --group-by FIELD          Group results by field
  --count                   Show count of grouped results
  --sort FIELD              Sort by field
  --limit NUMBER            Limit number of results
  --stats                   Show statistics for numeric fields
  --errors-only             Show only error entries
  --time-range START,END    Filter by time range
  --export FILE             Export results to file
  --no-header               Don't show table headers

Built-in Formats:
  json     - JSON lines format
  apache   - Apache Common/Combined log format
  nginx    - Nginx access log format
  csv      - Comma-separated values
  syslog   - Syslog format

Examples:
  log-parse access.log -f apache                    Parse Apache logs
  log-parse app.log -f json -s "timestamp,level"    Select specific fields
  log-parse access.log -f nginx --errors-only       Show only errors
  log-parse access.log -w "status>=400" --group-by status
  log-parse app.log -f json --stats                 Show statistics
  log-parse logs.csv -f csv -o json                 Convert CSV to JSON
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
        stderr: 'log-parse: missing file argument\nUsage: log-parse FILE [options]\n',
        duration: performance.now() - start,
      }
    }

    try {
      const result = await executeLogParse(args)
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
        stderr: `log-parse: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface LogParseOptions {
  file: string
  format: string
  pattern?: string
  output: 'json' | 'table' | 'csv' | 'summary'
  select?: string[]
  where?: string
  groupBy?: string
  count: boolean
  sort?: string
  limit?: number
  stats: boolean
  errorsOnly: boolean
  timeRange?: { start: Date; end: Date }
  export?: string
  noHeader: boolean
}

interface LogEntry {
  [key: string]: any
}

async function executeLogParse(args: string[]): Promise<{ output: string; verbose?: string }> {
  const options: LogParseOptions = {
    file: args[0],
    format: 'auto',
    output: 'table',
    count: false,
    stats: false,
    errorsOnly: false,
    noHeader: false,
  }

  // Parse arguments
  let i = 1
  while (i < args.length) {
    const arg = args[i]

    switch (arg) {
      case '-f':
      case '--format':
        options.format = args[++i]
        break
      case '-p':
      case '--pattern':
        options.pattern = args[++i]
        break
      case '-o':
      case '--output':
        const output = args[++i]
        if (['json', 'table', 'csv', 'summary'].includes(output)) {
          options.output = output as any
        }
        break
      case '-s':
      case '--select':
        options.select = args[++i].split(',').map(f => f.trim())
        break
      case '-w':
      case '--where':
        options.where = args[++i]
        break
      case '--group-by':
        options.groupBy = args[++i]
        break
      case '--count':
        options.count = true
        break
      case '--sort':
        options.sort = args[++i]
        break
      case '--limit':
        options.limit = parseInt(args[++i]) || 100
        break
      case '--stats':
        options.stats = true
        break
      case '--errors-only':
        options.errorsOnly = true
        break
      case '--time-range':
        const range = args[++i].split(',')
        if (range.length === 2) {
          options.timeRange = {
            start: new Date(range[0].trim()),
            end: new Date(range[1].trim()),
          }
        }
        break
      case '--export':
        options.export = args[++i]
        break
      case '--no-header':
        options.noHeader = true
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
      throw new Error(`File not found: ${options.file}`)
    }
  } catch (error) {
    throw new Error(`Cannot access file: ${error.message}`)
  }

  const result = await parseLogFile(options)
  return result
}

async function parseLogFile(options: LogParseOptions): Promise<{ output: string; verbose?: string }> {
  try {
    const file = Bun.file(options.file)
    const content = await file.text()
    const lines = content.split('\n').filter(line => line.trim() !== '')

    // Auto-detect format if needed
    if (options.format === 'auto') {
      options.format = detectLogFormat(lines[0] || '')
    }

    // Parse entries
    let entries: LogEntry[] = []
    for (const line of lines) {
      try {
        const entry = parseLogLine(line, options.format, options.pattern)
        if (entry) entries.push(entry)
      } catch {
        // Skip unparseable lines
      }
    }

    // Apply filters
    entries = applyFilters(entries, options)

    // Apply transformations
    entries = applyTransformations(entries, options)

    // Generate output
    const output = formatOutput(entries, options)

    // Export if requested
    if (options.export) {
      await Bun.write(options.export, output)
      return { output: `Results exported to ${options.export}` }
    }

    return { output }

  } catch (error) {
    throw new Error(`Error parsing file: ${error.message}`)
  }
}

function detectLogFormat(sampleLine: string): string {
  // Try to detect format from first line
  if (sampleLine.startsWith('{') && sampleLine.endsWith('}')) {
    return 'json'
  }

  if (sampleLine.includes(' - - [') && sampleLine.includes('] "')) {
    return 'apache'
  }

  if (sampleLine.match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)) {
    return 'nginx'
  }

  if (sampleLine.includes(',') && sampleLine.split(',').length > 3) {
    return 'csv'
  }

  return 'custom'
}

function parseLogLine(line: string, format: string, customPattern?: string): LogEntry | null {
  switch (format) {
    case 'json':
      return parseJsonLine(line)
    case 'apache':
      return parseApacheLine(line)
    case 'nginx':
      return parseNginxLine(line)
    case 'csv':
      return parseCsvLine(line)
    case 'syslog':
      return parseSyslogLine(line)
    case 'custom':
      return parseCustomLine(line, customPattern)
    default:
      throw new Error(`Unsupported format: ${format}`)
  }
}

function parseJsonLine(line: string): LogEntry | null {
  try {
    return JSON.parse(line)
  } catch {
    return null
  }
}

function parseApacheLine(line: string): LogEntry | null {
  // Apache Common Log Format: IP - - [timestamp] "method path protocol" status size
  const pattern = /^(\S+) (\S+) (\S+) \[([^\]]+)\] "([^"]*)" (\d+) (\S+)/
  const match = line.match(pattern)

  if (!match) return null

  const [, ip, , , timestamp, request, status, size] = match
  const [method, path, protocol] = request.split(' ')

  return {
    ip,
    timestamp: new Date(timestamp),
    method,
    path,
    protocol,
    status: parseInt(status),
    size: size === '-' ? 0 : parseInt(size),
    raw: line,
  }
}

function parseNginxLine(line: string): LogEntry | null {
  // Nginx access log format (similar to Apache but may vary)
  const pattern = /^(\S+) - (\S+) \[([^\]]+)\] "([^"]*)" (\d+) (\d+) "([^"]*)" "([^"]*)"/
  const match = line.match(pattern)

  if (!match) return null

  const [, ip, user, timestamp, request, status, size, referer, userAgent] = match
  const [method, path, protocol] = request.split(' ')

  return {
    ip,
    user: user === '-' ? null : user,
    timestamp: new Date(timestamp),
    method,
    path,
    protocol,
    status: parseInt(status),
    size: parseInt(size),
    referer: referer === '-' ? null : referer,
    userAgent,
    raw: line,
  }
}

function parseCsvLine(line: string): LogEntry | null {
  const values = line.split(',').map(v => v.trim().replace(/^"|"$/g, ''))

  // Assume first line contains headers (in real implementation, this would be handled differently)
  const headers = ['field1', 'field2', 'field3', 'field4', 'field5', 'field6', 'field7', 'field8']

  const entry: LogEntry = { raw: line }
  values.forEach((value, index) => {
    const header = headers[index] || `field${index + 1}`
    entry[header] = isNaN(Number(value)) ? value : Number(value)
  })

  return entry
}

function parseSyslogLine(line: string): LogEntry | null {
  // Syslog format: timestamp hostname service: message
  const pattern = /^(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+([^:]+):\s*(.*)$/
  const match = line.match(pattern)

  if (!match) return null

  const [, timestamp, hostname, service, message] = match

  return {
    timestamp: new Date(timestamp),
    hostname,
    service,
    message,
    raw: line,
  }
}

function parseCustomLine(line: string, pattern?: string): LogEntry | null {
  if (!pattern) return { raw: line }

  try {
    const regex = new RegExp(pattern)
    const match = line.match(regex)

    if (!match) return { raw: line }

    const entry: LogEntry = { raw: line }
    match.groups && Object.assign(entry, match.groups)

    return entry
  } catch {
    return { raw: line }
  }
}

function applyFilters(entries: LogEntry[], options: LogParseOptions): LogEntry[] {
  let filtered = entries

  // Time range filter
  if (options.timeRange) {
    filtered = filtered.filter(entry => {
      if (!entry.timestamp) return true
      const ts = new Date(entry.timestamp)
      return ts >= options.timeRange!.start && ts <= options.timeRange!.end
    })
  }

  // Errors only filter
  if (options.errorsOnly) {
    filtered = filtered.filter(entry => {
      const status = entry.status || entry.level
      return status && (
        (typeof status === 'number' && status >= 400) ||
        (typeof status === 'string' && /error|err|fatal|critical/i.test(status))
      )
    })
  }

  // Where condition filter
  if (options.where) {
    filtered = filtered.filter(entry => evaluateCondition(entry, options.where!))
  }

  return filtered
}

function evaluateCondition(entry: LogEntry, condition: string): boolean {
  // Simple condition evaluation (field>=value, field=value, etc.)
  const operators = ['>=', '<=', '!=', '=', '>', '<']

  for (const op of operators) {
    if (condition.includes(op)) {
      const [field, value] = condition.split(op).map(s => s.trim())
      const entryValue = entry[field]
      const compareValue = isNaN(Number(value)) ? value.replace(/['"]/g, '') : Number(value)

      switch (op) {
        case '>=': return entryValue >= compareValue
        case '<=': return entryValue <= compareValue
        case '>': return entryValue > compareValue
        case '<': return entryValue < compareValue
        case '!=': return entryValue != compareValue
        case '=': return entryValue == compareValue
      }
    }
  }

  return true
}

function applyTransformations(entries: LogEntry[], options: LogParseOptions): LogEntry[] {
  let transformed = entries

  // Field selection
  if (options.select) {
    transformed = transformed.map(entry => {
      const selected: LogEntry = {}
      for (const field of options.select!) {
        if (entry[field] !== undefined) {
          selected[field] = entry[field]
        }
      }
      return selected
    })
  }

  // Sorting
  if (options.sort) {
    transformed.sort((a, b) => {
      const aVal = a[options.sort!]
      const bVal = b[options.sort!]

      if (typeof aVal === 'number' && typeof bVal === 'number') {
        return aVal - bVal
      }

      return String(aVal).localeCompare(String(bVal))
    })
  }

  // Limit
  if (options.limit) {
    transformed = transformed.slice(0, options.limit)
  }

  return transformed
}

function formatOutput(entries: LogEntry[], options: LogParseOptions): string {
  if (options.stats) {
    return formatStats(entries)
  }

  if (options.groupBy) {
    return formatGrouped(entries, options)
  }

  switch (options.output) {
    case 'json':
      return JSON.stringify(entries, null, 2)
    case 'csv':
      return formatCsv(entries, options)
    case 'table':
      return formatTable(entries, options)
    case 'summary':
      return formatSummary(entries)
    default:
      return JSON.stringify(entries, null, 2)
  }
}

function formatStats(entries: LogEntry[]): string {
  const stats: any = {
    totalEntries: entries.length,
    fields: {},
  }

  // Analyze each field
  if (entries.length > 0) {
    const fields = Object.keys(entries[0])

    for (const field of fields) {
      const values = entries.map(e => e[field]).filter(v => v !== undefined && v !== null)
      const numericValues = values.filter(v => typeof v === 'number' || !isNaN(Number(v))).map(Number)

      stats.fields[field] = {
        count: values.length,
        unique: new Set(values).size,
      }

      if (numericValues.length > 0) {
        stats.fields[field].min = Math.min(...numericValues)
        stats.fields[field].max = Math.max(...numericValues)
        stats.fields[field].avg = numericValues.reduce((a, b) => a + b, 0) / numericValues.length
      }
    }
  }

  return JSON.stringify(stats, null, 2)
}

function formatGrouped(entries: LogEntry[], options: LogParseOptions): string {
  const groups: { [key: string]: LogEntry[] } = {}

  for (const entry of entries) {
    const key = String(entry[options.groupBy!] || 'unknown')
    if (!groups[key]) groups[key] = []
    groups[key].push(entry)
  }

  const lines: string[] = []
  lines.push(`Grouped by: ${options.groupBy}`)
  lines.push('='.repeat(40))

  for (const [key, group] of Object.entries(groups)) {
    lines.push(`${key}: ${group.length} entries`)
  }

  return lines.join('\n')
}

function formatCsv(entries: LogEntry[], options: LogParseOptions): string {
  if (entries.length === 0) return ''

  const fields = Object.keys(entries[0])
  const lines: string[] = []

  if (!options.noHeader) {
    lines.push(fields.join(','))
  }

  for (const entry of entries) {
    const values = fields.map(field => {
      const value = entry[field]
      return typeof value === 'string' && value.includes(',') ? `"${value}"` : String(value || '')
    })
    lines.push(values.join(','))
  }

  return lines.join('\n')
}

function formatTable(entries: LogEntry[], options: LogParseOptions): string {
  if (entries.length === 0) return 'No entries found'

  const fields = Object.keys(entries[0])
  const lines: string[] = []

  // Calculate column widths
  const widths: { [field: string]: number } = {}
  for (const field of fields) {
    widths[field] = Math.max(
      field.length,
      ...entries.map(e => String(e[field] || '').length)
    )
  }

  // Header
  if (!options.noHeader) {
    const header = fields.map(field => field.padEnd(widths[field])).join(' | ')
    lines.push(header)
    lines.push(fields.map(field => '-'.repeat(widths[field])).join('-|-'))
  }

  // Rows
  for (const entry of entries) {
    const row = fields.map(field => {
      const value = String(entry[field] || '')
      return value.padEnd(widths[field])
    }).join(' | ')
    lines.push(row)
  }

  return lines.join('\n')
}

function formatSummary(entries: LogEntry[]): string {
  const lines: string[] = []
  lines.push(`Total entries: ${entries.length}`)

  if (entries.length > 0) {
    const fields = Object.keys(entries[0])
    lines.push(`Fields: ${fields.join(', ')}`)

    // Show sample entry
    lines.push('\nSample entry:')
    lines.push(JSON.stringify(entries[0], null, 2))
  }

  return lines.join('\n')
}