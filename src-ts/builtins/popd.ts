import type { BuiltinCommand, CommandResult, Shell } from './types'

function getStack(shell: Shell): string[] {
  return (shell as any)._dirStack ?? ((shell as any)._dirStack = [])
}

export const popdCommand: BuiltinCommand = {
  name: 'popd',
  description: 'Pop directory from stack and change to it',
  usage: 'popd',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const stack = getStack(shell)
    const next = stack.shift()
    if (!next)
      return { exitCode: 1, stdout: '', stderr: 'popd: directory stack empty\n', duration: performance.now() - start }

    const ok = shell.changeDirectory(next)
    if (!ok)
      return { exitCode: 1, stdout: '', stderr: `popd: ${next}: no such directory\n`, duration: performance.now() - start }

    const out = `${[shell.cwd, ...stack].join(' ')}\n`
    return { exitCode: 0, stdout: out, stderr: '', duration: performance.now() - start }
  },
}
