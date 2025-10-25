import type { BuiltinCommand, CommandResult, Shell } from './types'

export const bfCommand: BuiltinCommand = {
  name: 'bf',
  description: 'Format code using pickier (or prettier)',
  usage: 'bf [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      // Check for package.json format script first
      const hasFormatScript = await shell.executeCommand('sh', ['-c', 'test -f package.json && jq -e .scripts.format package.json >/dev/null 2>&1'])
      if (hasFormatScript.exitCode === 0) {
        const res = await shell.executeCommand('bun', ['run', 'format', ...args])
        return { exitCode: res.exitCode, stdout: res.stdout || '', stderr: res.stderr, duration: performance.now() - start }
      }

      // Check for pickier
      const hasPickier = await shell.executeCommand('sh', ['-c', 'command -v pickier >/dev/null 2>&1'])
      if (hasPickier.exitCode === 0) {
        const res = await shell.executeCommand('pickier', ['--fix', '.', ...args])
        return {
          exitCode: res.exitCode,
          stdout: res.stdout || '',
          stderr: res.stderr,
          duration: performance.now() - start,
        }
      }

      // Fallback to prettier if available
      const hasPrettier = await shell.executeCommand('sh', ['-c', 'command -v prettier >/dev/null 2>&1'])
      if (hasPrettier.exitCode === 0) {
        const res = await shell.executeCommand('prettier', ['--write', '.', ...args])
        return {
          exitCode: res.exitCode,
          stdout: res.stdout || '',
          stderr: res.stderr,
          duration: performance.now() - start,
        }
      }

      return {
        exitCode: 1,
        stdout: '',
        stderr: 'bf: no formatter found (tried: package.json format script, pickier, prettier)\n',
        duration: performance.now() - start,
      }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
