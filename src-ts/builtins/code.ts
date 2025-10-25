import type { BuiltinCommand, CommandResult, Shell } from './types'

export const codeCommand: BuiltinCommand = {
  name: 'code',
  description: 'Open the current directory in Visual Studio Code',
  usage: 'code',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // Prefer VS Code CLI if available
      const hasCode = await shell.executeCommand('sh', ['-c', 'command -v code >/dev/null 2>&1'])
      if (hasCode.exitCode === 0) {
        await shell.executeCommand('code', [shell.cwd])
        return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
      }

      // Fallback to macOS open
      const hasOpen = await shell.executeCommand('sh', ['-c', 'command -v open >/dev/null 2>&1'])
      if (hasOpen.exitCode === 0) {
        await shell.executeCommand('open', ['-a', 'Visual Studio Code', shell.cwd])
        return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
      }

      return { exitCode: 1, stdout: '', stderr: 'code: VS Code not found (missing code CLI and open)\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
