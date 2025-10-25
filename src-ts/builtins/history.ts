import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * HISTORY command - displays or manipulates the command history
 * Supports clearing history and limiting output
 */
export const historyCommand: BuiltinCommand = {
  name: 'history',
  description: 'Display or manipulate the command history',
  usage: 'history [-c] [-n number]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    try {
      // Handle clear history flag
      if (args.includes('-c')) {
        const originalLength = shell.history.length
        shell.history.length = 0
        return {
          exitCode: 0,
          stdout: `History cleared (${originalLength} entries removed)\n`,
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Default to showing all history
      let limit = shell.history.length

      // Check for -n flag to limit output
      const nIndex = args.indexOf('-n')
      if (nIndex !== -1 && args[nIndex + 1]) {
        const parsed = Number.parseInt(args[nIndex + 1], 10)
        if (!Number.isNaN(parsed) && parsed > 0) {
          limit = Math.min(parsed, shell.history.length)
        }
        else {
          return {
            exitCode: 1,
            stdout: '',
            stderr: 'history: -n requires a positive integer argument\n',
            duration: performance.now() - start,
          }
        }
      }

      // Handle negative or zero limit
      if (limit <= 0) {
        return {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Get the slice of history to display
      const historyToShow = shell.history.slice(-limit)
      const output = historyToShow
        .map((cmd, index) => {
          const lineNum = shell.history.length - limit + index + 1
          return `${String(lineNum).padStart(5)}  ${cmd}`
        })
        .join('\n')

      return {
        exitCode: 0,
        stdout: output ? `${output}\n` : '',
        stderr: '',
        duration: performance.now() - start,
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `history: ${error instanceof Error ? error.message : 'Failed to access command history'}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
