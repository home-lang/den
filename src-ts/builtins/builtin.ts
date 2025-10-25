import type { BuiltinCommand, CommandResult, Shell } from './types'

// Execute the named builtin directly
export const builtinCommand: BuiltinCommand = {
  name: 'builtin',
  description: 'Run a shell builtin explicitly',
  usage: 'builtin name [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const name = args.shift()
    if (!name)
      return { exitCode: 2, stdout: '', stderr: 'builtin: name required\n', duration: performance.now() - start }

    const builtin = shell.builtins.get(name)
    if (!builtin)
      return { exitCode: 1, stdout: '', stderr: `builtin: ${name}: not a builtin\n`, duration: performance.now() - start }

    return builtin.execute(args, shell)
  },
}
