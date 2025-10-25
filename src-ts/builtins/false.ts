import type { BuiltinCommand, CommandResult } from './types'

export const falseCommand: BuiltinCommand = {
  name: 'false',
  description: 'Do nothing, unsuccessfully',
  usage: 'false',
  async execute(): Promise<CommandResult> {
    return { exitCode: 1, stdout: '', stderr: '', duration: 0 }
  },
}
