import type { BuiltinCommand, CommandResult, Shell } from './types'
import { existsSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import process from 'node:process'

export const libraryCommand: BuiltinCommand = {
  name: 'library',
  description: 'cd to $HOME/Library',
  usage: 'library',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const home = shell.environment.HOME || process.env.HOME || ''
    const target = resolve(home, 'Library')

    if (!home || !existsSync(target) || !statSync(target).isDirectory()) {
      return { exitCode: 1, stdout: '', stderr: `library: directory not found: ${target}\n`, duration: performance.now() - start }
    }

    const ok = shell.changeDirectory(target)
    if (!ok) {
      return { exitCode: 1, stdout: '', stderr: `library: permission denied: ${target}\n`, duration: performance.now() - start }
    }

    return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
  },
}
