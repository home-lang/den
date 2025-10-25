import type { BuiltinCommand, CommandResult, Shell } from './types'

const SHRUG = '¯\\_(ツ)_/¯'

export const shrugCommand: BuiltinCommand = {
  name: 'shrug',
  description: 'Copy ¯\\_(ツ)_/¯ to clipboard (when available) or print it',
  usage: 'shrug',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Avoid noisy streaming if we invoke subshells
    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // Prefer macOS: use sh -c with pbcopy if available
      const hasSh = await shell.executeCommand('sh', ['-c', 'command -v pbcopy >/dev/null 2>&1'])
      if (hasSh.exitCode === 0) {
        await shell.executeCommand('sh', ['-c', `printf %s '${SHRUG}' | pbcopy`])
        return {
          exitCode: 0,
          stdout: `${SHRUG}\n`,
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Fallback to osascript if available
      const hasOSA = await shell.executeCommand('sh', ['-c', 'command -v osascript >/dev/null 2>&1'])
      if (hasOSA.exitCode === 0) {
        // Escape backslashes for AppleScript
        const face = SHRUG.replace(/\\/g, '\\\\')
        await shell.executeCommand('osascript', ['-e', `set the clipboard to "${face}"`])
        return {
          exitCode: 0,
          stdout: `${SHRUG}\n`,
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Otherwise, just print it
      return {
        exitCode: 0,
        stdout: `${SHRUG}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
