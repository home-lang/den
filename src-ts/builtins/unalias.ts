import type { BuiltinCommand, CommandResult, Shell } from '../types'

/**
 * Unalias command - removes command aliases
 * Supports removing individual aliases or all aliases with -a flag
 */
export const unaliasCommand: BuiltinCommand = {
  name: 'unalias',
  description: 'Remove aliases',
  usage: 'unalias [-a] name [name ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args[0] === '-a') {
      // Remove all aliases
      for (const key of Object.keys(shell.aliases)) {
        delete shell.aliases[key]
      }
      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Remove specific aliases
    const notFound: string[] = []

    for (const name of args) {
      if (name in shell.aliases) {
        delete shell.aliases[name]
      }
      else {
        notFound.push(name)
      }
    }

    if (notFound.length > 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `unalias: ${notFound.join(' ')}: not found\n`,
        duration: performance.now() - start,
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
