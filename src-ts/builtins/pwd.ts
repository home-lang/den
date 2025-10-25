import type { BuiltinCommand, CommandResult, Shell } from './types'
import { existsSync } from 'node:fs'

/**
 * PWD (Print Working Directory) command - outputs the current working directory
 * This is a simple command but includes error handling for consistency
 */
export const pwdCommand: BuiltinCommand = {
  name: 'pwd',
  description: 'Print the current working directory',
  usage: 'pwd',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    try {
      // Verify we have a valid working directory
      if (!shell.cwd || typeof shell.cwd !== 'string') {
        throw new Error('Invalid working directory')
      }

      // Ensure the directory still exists and is accessible
      if (!existsSync(shell.cwd)) {
        throw new Error('Current working directory no longer exists')
      }

      return {
        exitCode: 0,
        stdout: `${shell.cwd}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `pwd: ${error instanceof Error ? error.message : 'Failed to get working directory'}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
