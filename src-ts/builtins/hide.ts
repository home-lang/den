import type { BuiltinCommand, CommandResult, Shell } from './types'

export const hideCommand: BuiltinCommand = {
  name: 'hide',
  description: 'Hide hidden files in Finder (macOS)',
  usage: 'hide',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasDefaults = await shell.executeCommand('sh', ['-c', 'command -v defaults >/dev/null 2>&1'])
      const hasKillall = await shell.executeCommand('sh', ['-c', 'command -v killall >/dev/null 2>&1'])
      if (hasDefaults.exitCode === 0 && hasKillall.exitCode === 0) {
        const res = await shell.executeCommand('sh', ['-c', 'defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder'])
        if (res.exitCode === 0)
          return { exitCode: 0, stdout: 'Finder hidden files: OFF\n', stderr: '', duration: performance.now() - start }
        return { exitCode: 1, stdout: '', stderr: 'hide: failed to toggle Finder\n', duration: performance.now() - start }
      }
      return { exitCode: 1, stdout: '', stderr: 'hide: unsupported system or missing tools\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
