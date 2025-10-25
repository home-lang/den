import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Help command - displays help information about builtin commands
 * Can show general help or specific command help
 */
export const helpCommand: BuiltinCommand = {
  name: 'help',
  description: 'Display help information',
  usage: 'help [command]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      // Display all commands
      const output = Array.from(shell.builtins.values())
        .map(cmd => `${cmd.name.padEnd(12)} ${cmd.description}`)
        .join('\n')

      return {
        exitCode: 0,
        stdout: `Built-in commands:\n${output}\n\nUse 'help <command>' for detailed information.\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    const commandName = args[0]
    const command = shell.builtins.get(commandName)

    if (!command) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `help: Unknown command: ${commandName}\n`,
        duration: performance.now() - start,
      }
    }

    const examples = command.examples && command.examples.length
      ? `\nExamples:\n${command.examples.map(e => `  ${e}`).join('\n')}`
      : ''

    return {
      exitCode: 0,
      stdout: `${command.name}: ${command.description}\nUsage: ${command.usage}${examples}\n`,
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
