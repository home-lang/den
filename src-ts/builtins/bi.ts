import type { BuiltinCommand, CommandResult, Shell } from './types'

export const biCommand: BuiltinCommand = {
  name: 'bi',
  description: 'Install dependencies via bun install',
  usage: 'bi [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasBun = await shell.executeCommand('sh', ['-c', 'command -v bun >/dev/null 2>&1'])
      if (hasBun.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'bi: bun not found\n', duration: performance.now() - start }

      const res = await shell.executeCommand('bun', ['install', ...args])
      if (res.exitCode === 0)
        return { exitCode: 0, stdout: res.stdout || '', stderr: '', duration: performance.now() - start }
      return { exitCode: res.exitCode || 1, stdout: res.stdout || '', stderr: res.stderr || 'bi: install failed\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
