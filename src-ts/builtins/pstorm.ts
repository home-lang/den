import type { BuiltinCommand, CommandResult, Shell } from './types'

export const pstormCommand: BuiltinCommand = {
  name: 'pstorm',
  description: 'Open the current directory in PhpStorm',
  usage: 'pstorm',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // Prefer pstorm CLI if available
      const hasPstorm = await shell.executeCommand('sh', ['-c', 'command -v pstorm >/dev/null 2>&1'])
      if (hasPstorm.exitCode === 0) {
        await shell.executeCommand('pstorm', [shell.cwd])
        return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
      }

      // Fallback to macOS open
      const hasOpen = await shell.executeCommand('sh', ['-c', 'command -v open >/dev/null 2>&1'])
      if (hasOpen.exitCode === 0) {
        await shell.executeCommand('open', ['-a', '/Applications/PhpStorm.app', shell.cwd])
        return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
      }

      return { exitCode: 1, stdout: '', stderr: 'pstorm: PhpStorm not found (missing pstorm CLI and open)\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
