import type { BuiltinCommand, CommandResult, Shell } from './types'
import { access } from 'node:fs/promises'
import { join } from 'node:path'

/**
 * Type command - show the type of a command
 * Identifies if a command is an alias, builtin, file, or not found
 */
export const typeCommand: BuiltinCommand = {
  name: 'type',
  description: 'Display the type of a command',
  usage: 'type [-afptP] [name ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'type: missing argument\n',
        duration: performance.now() - start,
      }
    }

    const results: string[] = []
    let allFound = true
    let showAll = false
    let fileOnly = false
    let noPath = false
    let showPath = false

    // Parse options
    while (args[0]?.startsWith('-')) {
      const arg = args.shift()!
      if (arg === '--')
        break

      for (let i = 1; i < arg.length; i++) {
        const flag = arg[i]
        switch (flag) {
          case 'a': showAll = true
            break
          case 'f': fileOnly = true
            break
          case 'p': noPath = true
            break
          case 'P': showPath = true
            break
          case 't': fileOnly = true
            noPath = true
            break
          default:
            return {
              exitCode: 1,
              stdout: '',
              stderr: `type: -${flag}: invalid option\ntype: usage: type [-afptP] name [name ...]\n`,
              duration: performance.now() - start,
            }
        }
      }
    }

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'type: missing argument\n',
        duration: performance.now() - start,
      }
    }

    if (shell.config.verbose)
      shell.log.debug('[type] flags: showAll=%s fileOnly=%s noPath=%s showPath=%s names=%o', String(showAll), String(fileOnly), String(noPath), String(showPath), args)

    for (const name of args) {
      if (!name)
        continue

      let found = false

      // Check for alias
      if (!fileOnly && shell.aliases[name]) {
        found = true
        if (noPath) {
          results.push('alias')
        }
        else {
          results.push(`${name} is an alias for ${shell.aliases[name]}`)
        }
        if (!showAll)
          continue
      }

      // Check for builtin
      if (!fileOnly && shell.builtins.has(name)) {
        found = true
        if (noPath) {
          results.push('builtin')
        }
        else {
          results.push(`${name} is a shell builtin`)
        }
        if (!showAll)
          continue
      }

      // Check for file in PATH
      const pathDirs = (shell.environment.PATH || '').split(':')
      let filePath = ''

      if (name.includes('/')) {
        // Absolute or relative path provided
        try {
          await access(name)
          filePath = name
          found = true
        }
        catch {
          // File not found, continue to next check
        }
      }
      else {
        // Search in PATH
        for (const dir of pathDirs) {
          if (!dir)
            continue
          const fullPath = join(dir, name)
          try {
            await access(fullPath)
            filePath = fullPath
            found = true
            break
          }
          catch {
            // File not found in this directory, continue searching
          }
        }
      }

      if (filePath) {
        if (noPath) {
          results.push('file')
        }
        else if (showPath) {
          results.push(filePath)
        }
        else {
          results.push(`${name} is ${filePath}`)
        }
        continue
      }

      // If we get here, command was not found
      if (!found) {
        allFound = false
        results.push(`type: ${name}: not found`)
      }
    }

    if (shell.config.verbose)
      shell.log.debug('[type] evaluated=%d allFound=%s', args.length, String(allFound))

    return {
      exitCode: allFound ? 0 : 1,
      stdout: `${results.join('\n')}\n`,
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
