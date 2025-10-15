import type { BuiltinCommand, CommandResult, Shell } from '../types'

/**
 * Alias command - defines or displays command aliases
 * Supports creating, listing, and looking up aliases
 */
export const aliasCommand: BuiltinCommand = {
  name: 'alias',
  description: 'Define or display aliases',
  usage: 'alias [name[=value] ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Helper function to format alias output in the format: name=value
    const formatAlias = (name: string, value: string): string => {
      return `${name}=${value}`
    }

    // If no arguments, list all aliases
    if (args.length === 0) {
      // List all aliases
      const aliasEntries = Object.entries(shell.aliases)
      if (aliasEntries.length === 0) {
        return { exitCode: 0, stdout: '', stderr: '' }
      }

      const output = aliasEntries
        .map(([name, value]) => `${name}=${value}`)
        .join('\n')

      return { exitCode: 0, stdout: `${output}\n`, stderr: '' }
    }

    if (args.length === 1 && !args[0].includes('=')) {
      const aliasName = args[0].trim()
      if (aliasName in shell.aliases) {
        return {
          exitCode: 0,
          stdout: `${formatAlias(aliasName, shell.aliases[aliasName])}\n`,
          stderr: '',
          duration: performance.now() - start,
        }
      }
      else {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `alias: ${aliasName}: not found\n`,
          duration: performance.now() - start,
        }
      }
    }

    // Process arguments to set aliases
    // Handle the case where alias value is split across multiple arguments
    let i = 0
    while (i < args.length) {
      const arg = args[i].trim()
      if (!arg) {
        i++
        continue
      }

      const eq = arg.indexOf('=')
      if (eq === -1) {
        // No '=' in this token -> treat as lookup for specific alias
        const aliasNameLookup = arg
        if (aliasNameLookup in shell.aliases) {
          return {
            exitCode: 0,
            stdout: `${formatAlias(aliasNameLookup, shell.aliases[aliasNameLookup])}\n`,
            stderr: '',
            duration: performance.now() - start,
          }
        }
        else {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `alias: ${aliasNameLookup}: not found\n`,
            duration: performance.now() - start,
          }
        }
      }

      // Parse alias definition
      let aliasName = arg.substring(0, eq).trim()
      let aliasValue = arg.substring(eq + 1)

      // Collect remaining arguments as part of the alias value
      const remainingArgs = args.slice(i + 1)
      if (remainingArgs.length > 0) {
        aliasValue = [aliasValue, ...remainingArgs].join(' ')
        i = args.length // Skip all remaining args since we consumed them
      }
      else {
        i++
      }

      if (!aliasName) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'alias: invalid empty alias name\n',
          duration: performance.now() - start,
        }
      }

      // Remove quotes from alias name if present
      if ((aliasName.startsWith('"') && aliasName.endsWith('"'))
        || (aliasName.startsWith('\'') && aliasName.endsWith('\''))) {
        aliasName = aliasName.slice(1, -1)
      }

      // Handle quote preservation in alias values based on test expectations
      if (aliasValue.startsWith('"') && aliasValue.endsWith('"') && aliasValue.length > 1) {
        // Remove outer double quotes for values like "echo it's ok"
        shell.aliases[aliasName] = aliasValue.slice(1, -1)
      }
      else if (aliasValue.startsWith('\'') && aliasValue.endsWith('\'') && aliasValue.length > 1) {
        // Remove outer single quotes for values like 'echo long text'
        shell.aliases[aliasName] = aliasValue.slice(1, -1)
      }
      else {
        // Unquoted values as-is
        shell.aliases[aliasName] = aliasValue
      }
    }

    return {
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
