import type { BuiltinCommand, CommandResult, Shell } from './types'

// 'c' builtin: clear the screen using ANSI escape sequences
export const clearCommand: BuiltinCommand = {
  name: 'c',
  description: 'Clear the screen',
  usage: 'c',
  async execute(_args: string[], _shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    // ANSI: clear screen and move cursor to home
    const seq = '\u001B[2J\u001B[H'
    return {
      exitCode: 0,
      stdout: seq,
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
