import type { BuiltinCommand, CommandResult } from './types'

export const trueCommand: BuiltinCommand = {
  name: 'true',
  description: 'Do nothing, successfully',
  usage: 'true',
  async execute(): Promise<CommandResult> {
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  },
}
