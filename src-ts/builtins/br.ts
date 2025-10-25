import type { BuiltinCommand, CommandResult, Shell } from './types'

export const brCommand: BuiltinCommand = {
  name: 'br',
  description: 'Run script via bun run (default: start)',
  usage: 'br [script] [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasBun = await shell.executeCommand('sh', ['-c', 'command -v bun >/dev/null 2>&1'])
      if (hasBun.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'br: bun not found\n', duration: performance.now() - start }

      // Default to 'start' if no script provided
      const script = args[0] || 'start'
      const scriptArgs = args[0] ? args.slice(1) : []

      const res = await shell.executeCommand('bun', ['run', script, ...scriptArgs])
      if (res.exitCode === 0)
        return { exitCode: 0, stdout: res.stdout || '', stderr: '', duration: performance.now() - start }
      return { exitCode: res.exitCode || 1, stdout: res.stdout || '', stderr: res.stderr || `br: script '${script}' failed\n`, duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
