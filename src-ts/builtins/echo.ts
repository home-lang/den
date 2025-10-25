import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Echo command - displays text to standard output
 * Supports the -n flag to suppress the trailing newline
 */
export const echoCommand: BuiltinCommand = {
  name: 'echo',
  description: 'Display text',
  usage: 'echo [-n] [string ...]',
  async execute(args: string[], _shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    let noNewline = false
    let textArgs = args

    if (args[0] === '-n') {
      noNewline = true
      textArgs = args.slice(1)
    }

    const output = textArgs.join(' ')

    return {
      exitCode: 0,
      stdout: noNewline ? output : `${output}\n`,
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
