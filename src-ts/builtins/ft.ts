import type { BuiltinCommand, CommandResult, Shell } from './types'

export const ftCommand: BuiltinCommand = {
  name: 'ft',
  description: 'Fix/Unstick macOS Touch Bar when it freezes',
  usage: 'ft',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasKillall = await shell.executeCommand('sh', ['-c', 'command -v killall >/dev/null 2>&1'])
      const hasPkill = await shell.executeCommand('sh', ['-c', 'command -v pkill >/dev/null 2>&1'])
      if (hasKillall.exitCode === 0 && hasPkill.exitCode === 0) {
        // Ignore non-zero exit codes from kill commands; attempt both
        await shell.executeCommand('sh', ['-c', 'killall ControlStrip >/dev/null 2>&1 || true']) // restart ControlStrip
        await shell.executeCommand('sh', ['-c', 'pkill \'Touch Bar agent\' >/dev/null 2>&1 || true']) // kill Touch Bar agent
        return { exitCode: 0, stdout: 'Touch Bar restarted\n', stderr: '', duration: performance.now() - start }
      }
      return { exitCode: 1, stdout: '', stderr: 'ft: unsupported system or missing tools\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
