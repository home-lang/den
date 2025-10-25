import type { BuiltinCommand, CommandResult, Shell } from './types'

export const bdCommand: BuiltinCommand = {
  name: 'bd',
  description: 'Run dev via bun run dev',
  usage: 'bd',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasBun = await shell.executeCommand('sh', ['-c', 'command -v bun >/dev/null 2>&1'])
      if (hasBun.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'bd: bun not found\n', duration: performance.now() - start }

      const scriptCheck = await shell.executeCommand('sh', ['-c', 'test -f package.json && jq -e .scripts.dev package.json >/dev/null 2>&1'])
      if (scriptCheck.exitCode === 0) {
        const res = await shell.executeCommand('bun', ['run', 'dev'])
        return { exitCode: res.exitCode, stdout: res.stdout || '', stderr: res.exitCode === 0 ? '' : (res.stderr || 'bd: dev failed\n'), duration: performance.now() - start }
      }

      return { exitCode: 1, stdout: '', stderr: 'bd: no dev script found\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
