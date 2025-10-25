import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import type { BuiltinCommand } from './types'

interface TreeOptions {
  all: boolean
  directories: boolean
  maxDepth: number
  sizes: boolean
  unicode: boolean
  pattern?: string
}

export const tree: BuiltinCommand = {
  name: 'tree',
  description: 'Display directory tree structure',
  usage: 'tree [path] [options]',
  async execute(shell, args) {
    if (args.includes('--help') || args.includes('-h')) {
      shell.output(`Usage: tree [path] [options]

Display a tree view of directory structure.

Options:
  -a, --all          Show hidden files
  -d, --directories  Show directories only
  -L LEVEL          Max depth level
  -s, --sizes        Show file sizes
  --ascii           Use ASCII characters instead of Unicode
  -P PATTERN        Show only files matching pattern

Examples:
  tree                    Show current directory tree
  tree /tmp               Show /tmp tree
  tree -a -L 2            Show all files, max depth 2
  tree -d                 Show directories only
  tree -P "*.ts"          Show only TypeScript files
`)
      return { success: true, exitCode: 0 }
    }

    const options = parseTreeOptions(args)
    const path = args.find(arg => !arg.startsWith('-')) || '.'

    try {
      const result = generateTree(path, options)
      shell.output(result)
      return { success: true, exitCode: 0 }
    } catch (error) {
      shell.error(`tree: ${error.message}`)
      return { success: false, exitCode: 1 }
    }
  },
}

function parseTreeOptions(args: string[]): TreeOptions {
  const options: TreeOptions = {
    all: false,
    directories: false,
    maxDepth: 10,
    sizes: false,
    unicode: true,
  }

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]

    switch (arg) {
      case '-a':
      case '--all':
        options.all = true
        break
      case '-d':
      case '--directories':
        options.directories = true
        break
      case '-L':
        options.maxDepth = parseInt(args[++i], 10) || 10
        break
      case '-s':
      case '--sizes':
        options.sizes = true
        break
      case '--ascii':
        options.unicode = false
        break
      case '-P':
        options.pattern = args[++i]
        break
    }
  }

  return options
}

function generateTree(rootPath: string, options: TreeOptions): string {
  const symbols = options.unicode
    ? { branch: '├── ', lastBranch: '└── ', vertical: '│   ', space: '    ' }
    : { branch: '|-- ', lastBranch: '`-- ', vertical: '|   ', space: '    ' }

  const output: string[] = [rootPath]
  let fileCount = 0
  let dirCount = 0

  function walkDirectory(dirPath: string, prefix = '', depth = 0) {
    if (depth >= options.maxDepth) return

    try {
      let entries = readdirSync(dirPath)

      // Filter hidden files if not showing all
      if (!options.all) {
        entries = entries.filter(entry => !entry.startsWith('.'))
      }

      // Filter by pattern if specified
      if (options.pattern) {
        const regex = new RegExp(options.pattern.replace(/\*/g, '.*'))
        entries = entries.filter(entry => regex.test(entry))
      }

      // Sort entries (directories first, then files)
      entries.sort((a, b) => {
        const aPath = join(dirPath, a)
        const bPath = join(dirPath, b)

        try {
          const aStat = statSync(aPath)
          const bStat = statSync(bPath)

          if (aStat.isDirectory() && !bStat.isDirectory()) return -1
          if (!aStat.isDirectory() && bStat.isDirectory()) return 1
          return a.localeCompare(b)
        } catch {
          return a.localeCompare(b)
        }
      })

      entries.forEach((entry, index) => {
        const isLast = index === entries.length - 1
        const entryPath = join(dirPath, entry)

        try {
          const stat = statSync(entryPath)
          const isDirectory = stat.isDirectory()

          // Skip files if only showing directories
          if (options.directories && !isDirectory) return

          // Count files and directories
          if (isDirectory) {
            dirCount++
          } else {
            fileCount++
          }

          // Format entry
          let entryDisplay = entry
          if (isDirectory) {
            entryDisplay += '/'
          }

          if (options.sizes && !isDirectory) {
            entryDisplay += ` (${formatSize(stat.size)})`
          }

          // Add to output
          const symbol = isLast ? symbols.lastBranch : symbols.branch
          output.push(prefix + symbol + entryDisplay)

          // Recurse into directories
          if (isDirectory && depth < options.maxDepth - 1) {
            const newPrefix = prefix + (isLast ? symbols.space : symbols.vertical)
            walkDirectory(entryPath, newPrefix, depth + 1)
          }
        } catch (error) {
          // Skip entries we can't access
        }
      })
    } catch (error) {
      // Skip directories we can't access
    }
  }

  walkDirectory(rootPath)

  // Add summary
  output.push('')
  output.push(`${dirCount} directories, ${fileCount} files`)

  return output.join('\n')
}

function formatSize(bytes: number): string {
  const units = ['B', 'K', 'M', 'G', 'T']
  let size = bytes
  let unitIndex = 0

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024
    unitIndex++
  }

  return `${size.toFixed(unitIndex === 0 ? 0 : 1)}${units[unitIndex]}`
}