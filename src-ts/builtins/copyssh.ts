import type { BuiltinCommand, CommandResult, Shell } from './types'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import process from 'node:process'

export const copysshCommand: BuiltinCommand = {
  name: 'copyssh',
  description: 'Copy ~/.ssh/id_ed25519.pub to clipboard when available, else print',
  usage: 'copyssh',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    const home = shell.environment.HOME || process.env.HOME || ''
    const pubKeyPath = join(home, '.ssh', 'id_ed25519.pub')

    if (!home || !existsSync(pubKeyPath)) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `copyssh: public key not found at ${pubKeyPath}\n`,
        duration: performance.now() - start,
      }
    }

    const content = readFileSync(pubKeyPath, 'utf8').trim()

    // Avoid noisy streaming if we invoke subshells
    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // Try pbcopy via sh -c for portability
      const hasPbcopy = await shell.executeCommand('sh', ['-c', 'command -v pbcopy >/dev/null 2>&1'])
      if (hasPbcopy.exitCode === 0) {
        await shell.executeCommand('sh', ['-c', `printf %s '${content.replace(/'/g, '\'\\\'\'')}' | pbcopy`])
        return { exitCode: 0, stdout: `${content}\n`, stderr: '', duration: performance.now() - start }
      }

      // Fallback to osascript on macOS
      const hasOSA = await shell.executeCommand('sh', ['-c', 'command -v osascript >/dev/null 2>&1'])
      if (hasOSA.exitCode === 0) {
        const escaped = content.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
        await shell.executeCommand('osascript', ['-e', `set the clipboard to "${escaped}"`])
        return { exitCode: 0, stdout: `${content}\n`, stderr: '', duration: performance.now() - start }
      }

      // Otherwise, just print
      return { exitCode: 0, stdout: `${content}\n`, stderr: '', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
