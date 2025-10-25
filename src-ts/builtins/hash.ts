import type { BuiltinCommand, CommandResult, Shell } from '../types'
import { access } from 'node:fs/promises'
import { join } from 'node:path'

/**
 * Hash command - remember or display command locations
 * Maintains a hash table of command paths to avoid repeated PATH lookups
 */
export const hashCommand: BuiltinCommand = {
  name: 'hash',
  description: 'Remember or display command locations',
  usage: 'hash [-r] [name ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Initialize hash table if it doesn't exist
    if (!shell.hashTable) {
      shell.hashTable = new Map<string, string>()
    }

    // Handle -r flag to clear the hash table
    if (args[0] === '-r') {
      if (shell.config.verbose)
        shell.log.debug('[hash] clearing hash table')
      shell.hashTable.clear()
      args.shift()

      if (args.length === 0) {
        return {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: performance.now() - start,
        }
      }
    }

    // If no arguments, display the current hash table
    if (args.length === 0) {
      const entries = Array.from(shell.hashTable.entries())
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([cmd, path]) => `builtin hash -p ${path} ${cmd}`)
        .join('\n')

      if (shell.config.verbose)
        shell.log.debug('[hash] listing %d entries', shell.hashTable.size)

      return {
        exitCode: 0,
        stdout: `${entries}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Process each command name
    const results: string[] = []
    let allFound = true

    for (const name of args) {
      if (!name)
        continue

      // Check for -p option (add path manually)
      if (name === '-p' && args.length > 1) {
        const path = args.shift()
        const cmd = args.shift()
        if (path && cmd) {
          shell.hashTable.set(cmd, path)
          if (shell.config.verbose)
            shell.log.debug('[hash] set -p %s=%s', cmd, path)
          continue
        }
      }

      // Check if already in hash table
      if (shell.hashTable.has(name)) {
        results.push(`hash: ${name} found: ${shell.hashTable.get(name)}`)
        continue
      }

      // Find command in PATH
      const pathDirs = (shell.environment.PATH || '').split(':')
      let found = false

      for (const dir of pathDirs) {
        if (!dir)
          continue
        const fullPath = join(dir, name)

        try {
          await access(fullPath)
          shell.hashTable.set(name, fullPath)
          results.push(`hash: ${name} found: ${fullPath}`)
          found = true
          break
        }
        catch {
          // File not found, continue searching
        }
      }

      if (!found) {
        allFound = false
        results.push(`hash: ${name}: command not found`)
      }
    }

    if (shell.config.verbose)
      shell.log.debug('[hash] processed=%d found_all=%s', args.length, String(allFound))

    return {
      exitCode: allFound ? 0 : 1,
      stdout: `${results.join('\n')}\n`,
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
