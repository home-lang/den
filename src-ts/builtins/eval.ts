import type { BuiltinCommand, CommandResult, Shell } from './types'

export const evalCommand: BuiltinCommand = {
  name: 'eval',
  description: 'Concatenate arguments and evaluate as a command',
  usage: 'eval [arguments...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const cmd = args.join(' ')
    const res = await shell.execute(cmd)
    return { ...res, duration: performance.now() - start }
  },
}
