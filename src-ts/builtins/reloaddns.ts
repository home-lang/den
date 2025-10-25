import type { BuiltinCommand, CommandResult, Shell } from './types'

export const reloaddnsCommand: BuiltinCommand = {
  name: 'reloaddns',
  description: 'Flush DNS cache on macOS',
  usage: 'reloaddns',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // macOS typical commands
      const hasSh = await shell.executeCommand('sh', ['-c', 'command -v dscacheutil >/dev/null 2>&1'])
      const hasKillall = await shell.executeCommand('sh', ['-c', 'command -v killall >/dev/null 2>&1'])

      if (hasSh.exitCode === 0 && hasKillall.exitCode === 0) {
        // Try without sudo first; if it fails, report guidance
        const flush = await shell.executeCommand('sh', ['-c', 'dscacheutil -flushcache && killall -HUP mDNSResponder'])
        if (flush.exitCode === 0) {
          return { exitCode: 0, stdout: 'DNS cache flushed\n', stderr: '', duration: performance.now() - start }
        }
        return { exitCode: 1, stdout: '', stderr: 'reloaddns: failed. Try: sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder\n', duration: performance.now() - start }
      }

      return { exitCode: 1, stdout: '', stderr: 'reloaddns: unsupported system or missing tools\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
