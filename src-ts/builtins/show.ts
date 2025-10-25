import type { BuiltinCommand, CommandResult, Shell } from './types'

export const showCommand: BuiltinCommand = {
  name: 'show',
  description: 'Show hidden files in Finder (macOS)',
  usage: 'show',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasDefaults = await shell.executeCommand('sh', ['-c', 'command -v defaults >/dev/null 2>&1'])
      const hasKillall = await shell.executeCommand('sh', ['-c', 'command -v killall >/dev/null 2>&1'])
      if (hasDefaults.exitCode === 0 && hasKillall.exitCode === 0) {
        const res = await shell.executeCommand('sh', ['-c', 'defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder'])
        if (res.exitCode === 0)
          return { exitCode: 0, stdout: 'Finder hidden files: ON\n', stderr: '', duration: performance.now() - start }
        return { exitCode: 1, stdout: '', stderr: 'show: failed to toggle Finder\n', duration: performance.now() - start }
      }
      return { exitCode: 1, stdout: '', stderr: 'show: unsupported system or missing tools\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
