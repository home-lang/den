import type { BuiltinCommand, CommandResult, Shell } from './types'
import process from 'node:process'

export const dotfilesCommand: BuiltinCommand = {
  name: 'dotfiles',
  description: 'Open $DOTFILES in your preferred editor ($EDITOR) or default to VS Code',
  usage: 'dotfiles [editor]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const dotfiles = shell.environment.DOTFILES || process.env.DOTFILES

    if (!dotfiles) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'dotfiles: DOTFILES environment variable is not set\n',
        duration: performance.now() - start,
      }
    }

    const prevStream = shell.config.streamOutput
    shell.config.streamOutput = false

    try {
      // Determine which editor to use (in order of preference):
      // 1. Explicit argument (e.g., 'dotfiles vim')
      // 2. $EDITOR environment variable
      // 3. Default to 'code' (VS Code)
      const editor = args[0] || process.env.EDITOR || 'code'

      // Check if the editor command exists
      const checkEditor = await shell.executeCommand('sh', [
        '-c',
        `command -v ${editor.split(' ')[0]} >/dev/null 2>&1`,
      ])

      if (checkEditor.exitCode === 0) {
        // If we're on macOS and the editor is in Applications, use 'open'
        if (process.platform === 'darwin' && editor.includes('.app')) {
          await shell.executeCommand('open', ['-a', editor, dotfiles])
        }
        else {
          // Otherwise, run the editor command directly
          await shell.executeCommand(editor, [dotfiles])
        }
        return {
          exitCode: 0,
          stdout: `Opening ${dotfiles} with ${editor}\n`,
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // If we get here, the specified editor wasn't found
      return {
        exitCode: 1,
        stdout: '',
        stderr: `dotfiles: Could not find editor '${editor}'. Please set $EDITOR or specify a valid editor.\n`,
        duration: performance.now() - start,
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `dotfiles: Error: ${error instanceof Error ? error.message : String(error)}\n`,
        duration: performance.now() - start,
      }
    }
    finally {
      shell.config.streamOutput = prevStream
    }
  },
}
