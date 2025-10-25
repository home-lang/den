import { readFileSync, statSync } from 'node:fs'
import type { BuiltinCommand } from './types'

interface GrepOptions {
  ignoreCase: boolean
  invertMatch: boolean
  lineNumber: boolean
  count: boolean
  filesOnly: boolean
  recursive: boolean
  extended: boolean
  fixed: boolean
  wordRegexp: boolean
  lineRegexp: boolean
  color: 'auto' | 'always' | 'never'
  beforeContext: number
  afterContext: number
  context: number
  maxCount: number
}

export const grep: BuiltinCommand = {
  name: 'grep',
  description: 'Search text patterns in files',
  usage: 'grep [options] pattern [files...]',
  async execute(shell, args) {
    if (args.includes('--help') || args.includes('-h')) {
      shell.output(`Usage: grep [options] pattern [files...]

Search for patterns in text files.

Options:
  -i, --ignore-case       Ignore case distinctions
  -v, --invert-match      Invert match (show non-matching lines)
  -n, --line-number       Show line numbers
  -c, --count             Show only count of matching lines
  -l, --files-with-matches Show only filenames with matches
  -r, --recursive         Search directories recursively
  -E, --extended-regexp   Use extended regular expressions
  -F, --fixed-strings     Treat pattern as fixed string
  -w, --word-regexp       Match whole words only
  -x, --line-regexp       Match whole lines only
  --color[=WHEN]          Colorize output (auto/always/never)
  -A NUM                  Print NUM lines after matches
  -B NUM                  Print NUM lines before matches
  -C NUM                  Print NUM lines before and after matches
  -m NUM                  Stop after NUM matches

Examples:
  grep "error" log.txt              Search for "error" in log.txt
  grep -i "warning" *.log           Case-insensitive search in log files
  grep -n -C 2 "TODO" src/*.ts      Show line numbers with 2 lines context
  grep -r "function" src/           Recursive search in src directory
  grep -v "debug" log.txt           Show lines that don't contain "debug"

Note: This is a simplified grep implementation. For full functionality,
use the system grep: command grep [args]
`)
      return { success: true, exitCode: 0 }
    }

    if (args.length === 0) {
      shell.error('grep: missing pattern')
      return { success: false, exitCode: 2 }
    }

    const { options, pattern, files } = parseGrepArgs(args)

    if (!pattern) {
      shell.error('grep: missing pattern')
      return { success: false, exitCode: 2 }
    }

    try {
      const result = await searchFiles(pattern, files, options, shell)
      return result
    } catch (error) {
      shell.error(`grep: ${error.message}`)
      return { success: false, exitCode: 2 }
    }
  },
}

function parseGrepArgs(args: string[]): { options: GrepOptions; pattern: string; files: string[] } {
  const options: GrepOptions = {
    ignoreCase: false,
    invertMatch: false,
    lineNumber: false,
    count: false,
    filesOnly: false,
    recursive: false,
    extended: false,
    fixed: false,
    wordRegexp: false,
    lineRegexp: false,
    color: 'auto',
    beforeContext: 0,
    afterContext: 0,
    context: 0,
    maxCount: 0,
  }

  let pattern = ''
  const files: string[] = []
  let patternFound = false

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]

    if (!arg.startsWith('-')) {
      if (!patternFound) {
        pattern = arg
        patternFound = true
      } else {
        files.push(arg)
      }
      continue
    }

    switch (arg) {
      case '-i':
      case '--ignore-case':
        options.ignoreCase = true
        break
      case '-v':
      case '--invert-match':
        options.invertMatch = true
        break
      case '-n':
      case '--line-number':
        options.lineNumber = true
        break
      case '-c':
      case '--count':
        options.count = true
        break
      case '-l':
      case '--files-with-matches':
        options.filesOnly = true
        break
      case '-r':
      case '--recursive':
        options.recursive = true
        break
      case '-E':
      case '--extended-regexp':
        options.extended = true
        break
      case '-F':
      case '--fixed-strings':
        options.fixed = true
        break
      case '-w':
      case '--word-regexp':
        options.wordRegexp = true
        break
      case '-x':
      case '--line-regexp':
        options.lineRegexp = true
        break
      case '--color':
        options.color = 'always'
        break
      case '--color=auto':
        options.color = 'auto'
        break
      case '--color=always':
        options.color = 'always'
        break
      case '--color=never':
        options.color = 'never'
        break
      case '-A':
        options.afterContext = parseInt(args[++i], 10) || 0
        break
      case '-B':
        options.beforeContext = parseInt(args[++i], 10) || 0
        break
      case '-C':
        options.context = parseInt(args[++i], 10) || 0
        if (options.context > 0) {
          options.beforeContext = options.context
          options.afterContext = options.context
        }
        break
      case '-m':
        options.maxCount = parseInt(args[++i], 10) || 0
        break
      default:
        if (arg.startsWith('-A')) {
          options.afterContext = parseInt(arg.slice(2), 10) || 0
        } else if (arg.startsWith('-B')) {
          options.beforeContext = parseInt(arg.slice(2), 10) || 0
        } else if (arg.startsWith('-C')) {
          const context = parseInt(arg.slice(2), 10) || 0
          options.beforeContext = context
          options.afterContext = context
        } else if (arg.startsWith('-m')) {
          options.maxCount = parseInt(arg.slice(2), 10) || 0
        } else {
          // Unknown option, treat as pattern if not found yet
          if (!patternFound) {
            pattern = arg
            patternFound = true
          } else {
            files.push(arg)
          }
        }
    }
  }

  return { options, pattern, files }
}

async function searchFiles(pattern: string, files: string[], options: GrepOptions, shell: any): Promise<any> {
  if (files.length === 0) {
    shell.error('grep: reading from stdin not supported in this implementation')
    return { success: false, exitCode: 2 }
  }

  let totalMatches = 0
  let hasMatch = false

  const shouldColor = options.color === 'always' || (options.color === 'auto' && process.stdout.isTTY)

  // Build regex
  let regexPattern = pattern
  if (options.fixed) {
    regexPattern = pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  }
  if (options.wordRegexp) {
    regexPattern = `\\b${regexPattern}\\b`
  }
  if (options.lineRegexp) {
    regexPattern = `^${regexPattern}$`
  }

  const flags = options.ignoreCase ? 'gi' : 'g'
  const regex = new RegExp(regexPattern, flags)

  for (const file of files) {
    try {
      const stat = statSync(file)
      if (stat.isDirectory()) {
        if (options.recursive) {
          // TODO: Implement recursive directory search
          shell.error(`grep: ${file}: Is a directory (recursive search not fully implemented)`)
          continue
        } else {
          shell.error(`grep: ${file}: Is a directory`)
          continue
        }
      }

      const content = readFileSync(file, 'utf8')
      const lines = content.split('\n')
      let fileMatches = 0
      const matches: Array<{ lineNumber: number; line: string; isMatch: boolean }> = []

      // Find matches
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i]
        const isMatch = regex.test(line) !== options.invertMatch

        if (isMatch) {
          fileMatches++
          hasMatch = true

          if (options.maxCount && fileMatches >= options.maxCount) {
            break
          }
        }

        // Store line info for context printing
        matches.push({ lineNumber: i + 1, line, isMatch })
      }

      totalMatches += fileMatches

      // Output results
      if (options.count) {
        const prefix = files.length > 1 ? `${file}:` : ''
        shell.output(`${prefix}${fileMatches}`)
      } else if (options.filesOnly) {
        if (fileMatches > 0) {
          shell.output(file)
        }
      } else if (fileMatches > 0) {
        printMatches(matches, file, files.length > 1, options, shouldColor, shell)
      }
    } catch (error) {
      shell.error(`grep: ${file}: ${error.message}`)
    }
  }

  return { success: hasMatch, exitCode: hasMatch ? 0 : 1 }
}

function printMatches(
  matches: Array<{ lineNumber: number; line: string; isMatch: boolean }>,
  filename: string,
  showFilename: boolean,
  options: GrepOptions,
  shouldColor: boolean,
  shell: any,
) {
  const { beforeContext, afterContext } = options

  for (let i = 0; i < matches.length; i++) {
    if (!matches[i].isMatch) continue

    // Print before context
    for (let j = Math.max(0, i - beforeContext); j < i; j++) {
      if (matches[j].isMatch) continue // Skip if already printed as match
      printLine(matches[j], filename, showFilename, false, options, shouldColor, shell)
    }

    // Print match
    printLine(matches[i], filename, showFilename, true, options, shouldColor, shell)

    // Print after context
    for (let j = i + 1; j <= Math.min(matches.length - 1, i + afterContext); j++) {
      if (matches[j].isMatch) break // Will be printed as match later
      printLine(matches[j], filename, showFilename, false, options, shouldColor, shell)
    }

    if (beforeContext > 0 || afterContext > 0) {
      shell.output('--')
    }
  }
}

function printLine(
  match: { lineNumber: number; line: string },
  filename: string,
  showFilename: boolean,
  isMatch: boolean,
  options: GrepOptions,
  shouldColor: boolean,
  shell: any,
) {
  let output = ''

  if (showFilename) {
    output += shouldColor ? `\x1b[35m${filename}\x1b[0m:` : `${filename}:`
  }

  if (options.lineNumber) {
    output += shouldColor ? `\x1b[32m${match.lineNumber}\x1b[0m:` : `${match.lineNumber}:`
  }

  let line = match.line
  if (isMatch && shouldColor) {
    // Highlight matches in red
    line = line.replace(/(.+)/g, '\x1b[31m$1\x1b[0m')
  }

  output += line
  shell.output(output)
}