import type { BuiltinCommand, CommandResult, Shell } from './types'
import process from 'node:process'

/**
 * Export command - sets environment variables
 * Supports setting variables in both shell and process environment
 */
export const exportCommand: BuiltinCommand = {
  name: 'export',
  description: 'Set environment variables',
  usage: 'export [name[=value] ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      // Display all environment variables
      const output = Object.entries(shell.environment)
        .map(([name, value]) => `${name}=${value}`)
        .join('\n')

      return {
        exitCode: 0,
        stdout: output ? `${output}\n` : '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    for (const arg of args) {
      if (arg.includes('=')) {
        const [name, ...valueParts] = arg.split('=')
        const value = valueParts.join('=').replace(/^["']|["']$/g, '')
        shell.environment[name] = value
        process.env[name] = value // Also set in process environment
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
