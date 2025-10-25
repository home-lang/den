import type { BuiltinCommand, CommandResult } from './types'

export const json: BuiltinCommand = {
  name: 'json',
  description: 'Parse and format JSON data with query support',
  usage: 'json [options] [query] [file]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()
    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: json [options] [query] [file]

Parse, format, and query JSON data.

Options:
  -p, --pretty          Pretty-print JSON with indentation
  -c, --compact         Compact JSON output (remove whitespace)
  -q, --query QUERY     Query JSON using dot notation (e.g., "users.0.name")
  -v, --validate        Validate JSON without output
  -s, --sort-keys       Sort object keys alphabetically
  -r, --raw             Raw string output (no quotes for strings)

Examples:
  echo '{"name": "John"}' | json -p           Pretty-print JSON
  json -q "users.0.name" data.json            Extract specific value
  json -v config.json                         Validate JSON file
  echo '{"b": 1, "a": 2}' | json -s           Sort keys
  json -c data.json                           Compact JSON

Queries:
  - Use dot notation: "user.profile.name"
  - Array access: "users.0" or "users[0]"
  - Wildcards: "users.*.name" (gets all names)
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    const options = parseOptions(args)
    let input = ''

    // Read from file or stdin
    if (options.file) {
      try {
        const { readFileSync } = await import('node:fs')
        input = readFileSync(options.file, 'utf8')
      } catch (error) {
        shell.error(`json: cannot read '${options.file}': ${error.message}`)
        return { success: false, exitCode: 1 }
      }
    } else {
      // Read from stdin (for piped input)
      try {
        // In a real implementation, we'd read from process.stdin
        // For now, we'll just handle the file case
        shell.error('json: reading from stdin not yet implemented')
        return { success: false, exitCode: 1 }
      } catch (error) {
        shell.error(`json: ${error.message}`)
        return { success: false, exitCode: 1 }
      }
    }

    try {
      let data = JSON.parse(input)

      // Apply query if provided
      if (options.query) {
        data = queryJson(data, options.query)
      }

      // Sort keys if requested
      if (options.sortKeys && typeof data === 'object' && data !== null) {
        data = sortObjectKeys(data)
      }

      // Validate only
      if (options.validate) {
        shell.output('Valid JSON')
        return { success: true, exitCode: 0 }
      }

      // Format output
      let output: string
      if (options.raw && typeof data === 'string') {
        output = data
      } else if (options.compact) {
        output = JSON.stringify(data)
      } else if (options.pretty) {
        output = JSON.stringify(data, null, 2)
      } else {
        output = JSON.stringify(data, null, 2) // Default to pretty
      }

      shell.output(output)
      return { success: true, exitCode: 0 }
    } catch (error) {
      shell.error(`json: invalid JSON: ${error.message}`)
      return { success: false, exitCode: 1 }
    }
  },
}

interface JsonOptions {
  pretty: boolean
  compact: boolean
  query?: string
  validate: boolean
  sortKeys: boolean
  raw: boolean
  file?: string
}

function parseOptions(args: string[]): JsonOptions {
  const options: JsonOptions = {
    pretty: false,
    compact: false,
    validate: false,
    sortKeys: false,
    raw: false,
  }

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]

    switch (arg) {
      case '-p':
      case '--pretty':
        options.pretty = true
        break
      case '-c':
      case '--compact':
        options.compact = true
        break
      case '-q':
      case '--query':
        options.query = args[++i]
        break
      case '-v':
      case '--validate':
        options.validate = true
        break
      case '-s':
      case '--sort-keys':
        options.sortKeys = true
        break
      case '-r':
      case '--raw':
        options.raw = true
        break
      default:
        if (!arg.startsWith('-') && !options.file) {
          options.file = arg
        }
    }
  }

  return options
}

function queryJson(data: any, query: string): any {
  const parts = query.split('.')
  let result = data

  for (const part of parts) {
    if (result === null || result === undefined) {
      return undefined
    }

    // Handle array access: users[0] or users.0
    const arrayMatch = part.match(/^(.+)\[(\d+)\]$/) || (part.match(/^\d+$/) ? [null, null, part] : null)

    if (arrayMatch) {
      const [, key, index] = arrayMatch
      if (key) {
        result = result[key]
      }
      if (Array.isArray(result)) {
        result = result[parseInt(index, 10)]
      } else {
        return undefined
      }
    } else if (part === '*') {
      // Wildcard: return array of values
      if (Array.isArray(result)) {
        return result
      } else if (typeof result === 'object' && result !== null) {
        return Object.values(result)
      } else {
        return undefined
      }
    } else {
      result = result[part]
    }
  }

  return result
}

function sortObjectKeys(obj: any): any {
  if (Array.isArray(obj)) {
    return obj.map(sortObjectKeys)
  } else if (typeof obj === 'object' && obj !== null) {
    const sorted: any = {}
    const keys = Object.keys(obj).sort()
    for (const key of keys) {
      sorted[key] = sortObjectKeys(obj[key])
    }
    return sorted
  }
  return obj
}