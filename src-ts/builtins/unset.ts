import type { BuiltinCommand, CommandResult, Shell } from '../types'
import process from 'node:process'

export const unsetCommand: BuiltinCommand = {
  name: 'unset',
  description: 'Unset (remove) shell variables or functions',
  usage: 'unset [-v] name [name ...] | unset -f name [name ...]',
  examples: [
    'unset PATH',
    'unset -v MY_VAR OTHER_VAR',
    'unset -f my_function',
  ],
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Parse flags: -v (variables, default), -f (functions)
    let mode: 'vars' | 'funcs' = 'vars'
    const names: string[] = []
    let error: string | undefined

    for (const a of args) {
      if (a === '-v') {
        mode = 'vars'
        continue
      }
      if (a === '-f') {
        mode = 'funcs'
        continue
      }
      if (a.startsWith('-')) {
        error = `unset: invalid option: ${a}\n`
        break
      }
      names.push(a)
    }

    if (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: error,
        duration: performance.now() - start,
      }
    }

    if (names.length === 0) {
      // No-op is success per POSIX
      return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
    }

    if (mode === 'funcs') {
      // Functions are not globally managed in the current Shell API.
      // Provide a clear error indicating unsupported operation for now.
      const msg = `unset: -f not supported: functions are scoped to scripts and not globally managed\n`
      if (shell.config.verbose)
        shell.log.debug('[unset] -f requested for: %o', names)
      return { exitCode: 1, stdout: '', stderr: msg, duration: performance.now() - start }
    }

    // mode === 'vars'
    for (const name of names) {
      if (!name)
        continue
      // Remove from environment if present
      delete (shell.environment as Record<string, unknown>)[name]
      // Reflect change in process.env for external commands consistency
      try {
        delete (process.env as Record<string, unknown>)[name]
      }
      catch {}
    }

    const res: CommandResult = {
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: performance.now() - start,
    }
    if (shell.config.verbose)
      shell.log.debug('[unset] removed %d variable(s) in %dms', names.length, Math.round(res.duration || 0))
    return res
  },
}
