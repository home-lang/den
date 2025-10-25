import type { BuiltinCommand, Shell } from './types'

function getStack(shell: Shell): string[] {
  return (shell as any)._dirStack ?? ((shell as any)._dirStack = [])
}

export const dirsCommand: BuiltinCommand = {
  name: 'dirs',
  description: 'Display the directory stack',
  usage: 'dirs [-v]',
  examples: [
    'dirs',
    'dirs -v',
  ],
  async execute(args: string[], shell: Shell): Promise<{ exitCode: number, stdout: string, stderr: string, duration: number }> {
    const start = performance.now()
    const stack = getStack(shell)
    const list = [shell.cwd, ...stack]
    if (shell.config.verbose)
      shell.log.debug('[dirs] stack', list)

    const verbose = args.includes('-v')
    if (!verbose)
      return { exitCode: 0, stdout: `${list.join(' ')}\n`, stderr: '', duration: performance.now() - start }

    const lines = list.map((dir, i) => `${i}  ${dir}`)
    return { exitCode: 0, stdout: `${lines.join('\n')}\n`, stderr: '', duration: performance.now() - start }
  },
}
