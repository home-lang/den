import type { BuiltinCommand, CommandResult, Shell } from './types'

export const emptytrashCommand: BuiltinCommand = {
  name: 'emptytrash',
  description: 'Empty the user Trash on macOS (no sudo). Fails gracefully elsewhere.',
  usage: 'emptytrash',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const home = shell.environment.HOME || ''
      if (!home)
        return { exitCode: 1, stdout: '', stderr: 'emptytrash: HOME not set\n', duration: performance.now() - start }

      const trashPath = `${home}/.Trash`
      const hasSh = await shell.executeCommand('sh', ['-c', 'command -v sh >/dev/null 2>&1'])
      if (hasSh.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'emptytrash: missing shell\n', duration: performance.now() - start }

      // Remove contents of ~/.Trash only (avoid sudo/system-wide operations here)
      const res = await shell.executeCommand('sh', ['-c', `if [ -d "${trashPath}" ]; then rm -rf "${trashPath}"/* "${trashPath}"/.* 2>/dev/null || true; fi`])
      if (res.exitCode === 0)
        return { exitCode: 0, stdout: 'Trash emptied\n', stderr: '', duration: performance.now() - start }

      return { exitCode: 1, stdout: '', stderr: 'emptytrash: failed to empty Trash\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
