import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Time command - measures the execution time of another command
 * Displays real, user, and system time statistics
 */
export const timeCommand: BuiltinCommand = {
  name: 'time',
  description: 'Measure command execution time',
  usage: 'time command [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'time: missing command\n',
        duration: performance.now() - start,
      }
    }

    // Execute the command
    const command = args[0]
    const commandArgs = args.slice(1)

    try {
      // Use the shell's executeCommand method to run the command
      const result = await shell.executeCommand(command, commandArgs)

      // Format the time
      const end = performance.now()
      const elapsed = (end - start) / 1000 // Convert to seconds
      const timeOutput = `\nreal\t${elapsed.toFixed(3)}s\nuser\t0.000s\nsys\t0.000s\n`

      return {
        ...result,
        stdout: result.stdout + (result.stderr ? `\n${result.stderr}` : '') + timeOutput,
        stderr: '',
        duration: end - start,
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `time: ${error instanceof Error ? error.message : 'Command execution failed'}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
