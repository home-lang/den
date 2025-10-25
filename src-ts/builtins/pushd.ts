import type { BuiltinCommand, CommandResult, Shell } from './types'

function getStack(shell: Shell): string[] {
  return (shell as any)._dirStack ?? ((shell as any)._dirStack = [])
}

export const pushdCommand: BuiltinCommand = {
  name: 'pushd',
  description: 'Save current directory on stack and change to DIR',
  usage: 'pushd [dir]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const stack = getStack(shell)
    const dir = args[0]
    if (!dir)
      return { exitCode: 2, stdout: '', stderr: 'pushd: directory required\n', duration: performance.now() - start }

    const prev = shell.cwd
    const ok = shell.changeDirectory(dir)
    if (!ok)
      return { exitCode: 1, stdout: '', stderr: `pushd: ${dir}: no such directory\n`, duration: performance.now() - start }

    stack.unshift(prev)
    const out = `${[shell.cwd, ...stack].join(' ')}\n`
    return { exitCode: 0, stdout: out, stderr: '', duration: performance.now() - start }
  },
}
