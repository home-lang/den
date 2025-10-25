import type { BuiltinCommand, CommandResult, Shell } from './types'

export const blCommand: BuiltinCommand = {
  name: 'bl',
  description: 'Lint code using pickier (or eslint)',
  usage: 'bl [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      // Check for package.json lint script first
      const hasLintScript = await shell.executeCommand('sh', ['-c', 'test -f package.json && jq -e .scripts.lint package.json >/dev/null 2>&1'])
      if (hasLintScript.exitCode === 0) {
        const res = await shell.executeCommand('bun', ['run', 'lint', ...args])
        return {
          exitCode: res.exitCode,
          stdout: res.stdout || '',
          stderr: res.stderr,
          duration: performance.now() - start,
        }
      }

      // Check for pickier
      const hasPickier = await shell.executeCommand('sh', ['-c', 'command -v pickier >/dev/null 2>&1'])
      if (hasPickier.exitCode === 0) {
        const res = await shell.executeCommand('pickier', ['.', ...args])
        return {
          exitCode: res.exitCode,
          stdout: res.stdout || '',
          stderr: res.stderr,
          duration: performance.now() - start,
        }
      }

      // Fallback to eslint if available
      const hasEslint = await shell.executeCommand('sh', ['-c', 'command -v eslint >/dev/null 2>&1'])
      if (hasEslint.exitCode === 0) {
        const res = await shell.executeCommand('eslint', ['.', ...args])
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
        stderr: 'bl: no linter found (tried: package.json lint script, pickier, eslint)\n',
        duration: performance.now() - start,
      }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
