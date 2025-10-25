import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import type { BuiltinCommand } from './types'

interface FindOptions {
  name?: string
  type?: 'f' | 'd' | 'l' // file, directory, symlink
  maxdepth?: number
  mindepth?: number
  size?: string
  mtime?: string
  exec?: string
  fuzzy?: boolean
  interactive?: boolean
}

export const find: BuiltinCommand = {
  name: 'find',
  description: 'Find files and directories with optional fuzzy matching',
  usage: 'find [path] [options]',
  async execute(shell, args) {
    if (args.includes('--help') || args.includes('-h')) {
      shell.output(`Usage: find [path] [options]

Search for files and directories.

Options:
  -name PATTERN     Search for files matching the pattern
  -type TYPE        File type: f (file), d (directory), l (symlink)
  -maxdepth N       Maximum search depth
  -mindepth N       Minimum search depth
  -size SIZE        File size criteria (e.g., +1M, -10k)
  -mtime DAYS       Modified time criteria (e.g., -7, +30)
  -exec COMMAND     Execute command on found files
  --fuzzy           Enable fuzzy pattern matching
  --interactive     Interactive selection mode

Examples:
  find . -name "*.ts"           Find TypeScript files
  find /tmp -type d             Find directories
  find . -name "test" --fuzzy   Fuzzy search for "test"
  find . -type f --interactive  Interactive file finder

Note: This is a simplified find implementation. For full functionality,
use the system find command: command find [args]
`)
      return { success: true, exitCode: 0 }
    }

    const startPath = args[0] && !args[0].startsWith('-') ? args[0] : '.'
    const options = parseOptions(args.slice(args[0] && !args[0].startsWith('-') ? 1 : 0))

    if (!existsSync(startPath)) {
      shell.error(`find: '${startPath}': No such file or directory`)
      return { success: false, exitCode: 1 }
    }

    try {
      if (options.fuzzy || options.interactive) {
        return await fuzzyFind(shell, startPath, options)
      } else {
        return await systemFind(shell, startPath, options)
      }
    } catch (error) {
      shell.error(`find: ${error.message}`)
      return { success: false, exitCode: 1 }
    }
  },
}

function parseOptions(args: string[]): FindOptions {
  const options: FindOptions = {}

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]

    switch (arg) {
      case '-name':
        options.name = args[++i]
        break
      case '-type':
        options.type = args[++i] as 'f' | 'd' | 'l'
        break
      case '-maxdepth':
        options.maxdepth = parseInt(args[++i], 10)
        break
      case '-mindepth':
        options.mindepth = parseInt(args[++i], 10)
        break
      case '-size':
        options.size = args[++i]
        break
      case '-mtime':
        options.mtime = args[++i]
        break
      case '-exec':
        options.exec = args[++i]
        break
      case '--fuzzy':
        options.fuzzy = true
        break
      case '--interactive':
        options.interactive = true
        break
    }
  }

  return options
}

async function systemFind(shell: any, startPath: string, options: FindOptions): Promise<any> {
  return new Promise((resolve, reject) => {
    const args = [startPath]

    if (options.maxdepth !== undefined) {
      args.push('-maxdepth', options.maxdepth.toString())
    }
    if (options.mindepth !== undefined) {
      args.push('-mindepth', options.mindepth.toString())
    }
    if (options.type) {
      args.push('-type', options.type)
    }
    if (options.name) {
      args.push('-name', options.name)
    }
    if (options.size) {
      args.push('-size', options.size)
    }
    if (options.mtime) {
      args.push('-mtime', options.mtime)
    }
    if (options.exec) {
      args.push('-exec', options.exec, '{}', ';')
    }

    const find = spawn('find', args, { stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    let errorOutput = ''

    find.stdout?.on('data', (data) => {
      output += data.toString()
    })

    find.stderr?.on('data', (data) => {
      errorOutput += data.toString()
    })

    find.on('close', (code) => {
      if (code === 0) {
        if (output.trim()) {
          shell.output(output.trim())
        }
        resolve({ success: true, exitCode: 0 })
      } else {
        if (errorOutput.trim()) {
          shell.error(errorOutput.trim())
        }
        resolve({ success: false, exitCode: code || 1 })
      }
    })

    find.on('error', (error) => {
      reject(error)
    })
  })
}

async function fuzzyFind(shell: any, startPath: string, options: FindOptions): Promise<any> {
  const { readdirSync, statSync } = await import('node:fs')
  const { join } = await import('node:path')

  const results: string[] = []
  const maxDepth = options.maxdepth || 10
  const minDepth = options.mindepth || 0

  function walkDirectory(dir: string, currentDepth = 0) {
    if (currentDepth > maxDepth) return

    try {
      const entries = readdirSync(dir)

      for (const entry of entries) {
        if (entry.startsWith('.') && entry !== '.' && entry !== '..') continue

        const fullPath = join(dir, entry)

        try {
          const stat = statSync(fullPath)
          const isFile = stat.isFile()
          const isDir = stat.isDirectory()
          const isSymlink = stat.isSymbolicLink()

          // Type filtering
          if (options.type === 'f' && !isFile) continue
          if (options.type === 'd' && !isDir) continue
          if (options.type === 'l' && !isSymlink) continue

          // Depth filtering
          if (currentDepth < minDepth) continue

          // Name filtering with fuzzy support
          if (options.name) {
            const matches = options.fuzzy
              ? fuzzyMatch(entry, options.name)
              : entry.includes(options.name)

            if (!matches) continue
          }

          results.push(fullPath)

          // Recurse into directories
          if (isDir && currentDepth < maxDepth) {
            walkDirectory(fullPath, currentDepth + 1)
          }
        } catch (error) {
          // Skip files we can't access
          continue
        }
      }
    } catch (error) {
      // Skip directories we can't access
    }
  }

  walkDirectory(resolve(startPath))

  // Sort results by relevance
  if (options.name && options.fuzzy) {
    results.sort((a, b) => {
      const scoreA = fuzzyScore(a, options.name!)
      const scoreB = fuzzyScore(b, options.name!)
      return scoreA - scoreB
    })
  } else {
    results.sort()
  }

  if (options.interactive && results.length > 1) {
    return await interactiveSelect(shell, results)
  } else {
    for (const result of results) {
      shell.output(result)
    }
    return { success: true, exitCode: 0 }
  }
}

function fuzzyMatch(text: string, pattern: string): boolean {
  const t = text.toLowerCase()
  const p = pattern.toLowerCase()

  let textIndex = 0
  let patternIndex = 0

  while (textIndex < t.length && patternIndex < p.length) {
    if (t[textIndex] === p[patternIndex]) {
      patternIndex++
    }
    textIndex++
  }

  return patternIndex === p.length
}

function fuzzyScore(text: string, pattern: string): number {
  const t = text.toLowerCase()
  const p = pattern.toLowerCase()

  if (t.includes(p)) return p.length - t.length // Exact matches score better

  let score = 0
  let lastIndex = -1

  for (const char of p) {
    const index = t.indexOf(char, lastIndex + 1)
    if (index === -1) return 1000 // Penalty for missing characters
    score += index - lastIndex
    lastIndex = index
  }

  return score
}

async function interactiveSelect(shell: any, options: string[]): Promise<any> {
  const readline = await import('node:readline')

  return new Promise((resolve) => {
    if (options.length === 0) {
      shell.output('No matches found')
      resolve({ success: true, exitCode: 0 })
      return
    }

    if (options.length === 1) {
      shell.output(options[0])
      resolve({ success: true, exitCode: 0 })
      return
    }

    shell.output('Multiple matches found. Select one:')
    options.forEach((option, index) => {
      shell.output(`${index + 1}. ${option}`)
    })

    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    })

    rl.question('Enter number (1-' + options.length + '): ', (answer) => {
      const choice = parseInt(answer.trim(), 10)

      if (choice >= 1 && choice <= options.length) {
        shell.output(options[choice - 1])
        resolve({ success: true, exitCode: 0 })
      } else {
        shell.error('Invalid selection')
        resolve({ success: false, exitCode: 1 })
      }

      rl.close()
    })
  })
}