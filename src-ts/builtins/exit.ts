import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Exit command - exits the shell with an optional status code
 * Stops the shell's execution when called
 */
export const exitCommand: BuiltinCommand = {
  name: 'exit',
  description: 'Exit the shell',
  usage: 'exit [code]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    let exitCode = 0
    if (args[0]) {
      const parsed = Number.parseInt(args[0], 10)
      if (Number.isNaN(parsed)) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'exit: numeric argument required\n',
          duration: performance.now() - start,
        }
      }
      exitCode = parsed
    }

    // Signal shell to exit
    shell.stop()

    return {
      exitCode,
      stdout: '',
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
