import type { BuiltinCommand, CommandResult, Shell } from '../types'

/**
 * Umask command - set or display the file mode creation mask
 * Controls the default permissions for newly created files and directories
 */
export const umaskCommand: BuiltinCommand = {
  name: 'umask',
  description: 'Get or set the file mode creation mask',
  usage: 'umask [-p] [-S] [mode]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Initialize umask if it doesn't exist
    if (shell.umask === undefined) {
      shell.umask = 0o022 // Default umask (rwxr-xr-x)
    }
    if (shell.config.verbose)
      shell.log.debug('[umask] start current=%s', shell.umask.toString(8).padStart(3, '0'))

    // Parse options
    let printSymbolic = false
    let preserveOutput = false
    let modeArg: string | null = null

    for (let i = 0; i < args.length; i++) {
      const arg = args[i]

      if (arg === '--') {
        modeArg = args.slice(i + 1).join(' ')
        break
      }
      else if (arg.startsWith('-')) {
        for (let j = 1; j < arg.length; j++) {
          const flag = arg[j]
          if (flag === 'S') {
            printSymbolic = true
          }
          else if (flag === 'p') {
            preserveOutput = true
          }
          else {
            return {
              exitCode: 1,
              stdout: '',
              stderr: `umask: -${flag}: invalid option\numask: usage: umask [-p] [-S] [mode]\n`,
              duration: performance.now() - start,
            }
          }
        }
      }
      else if (!modeArg) {
        modeArg = arg
      }
    }
    if (shell.config.verbose)
      shell.log.debug('[umask] parsed flags: %o modeArg=%s', { S: printSymbolic, p: preserveOutput }, String(modeArg))

    // If mode is provided, set the umask
    if (modeArg) {
      let newUmask: number

      if (modeArg.startsWith('0')) {
        // Octal mode
        newUmask = Number.parseInt(modeArg, 8)
      }
      else if (/^[0-7]+$/.test(modeArg)) {
        // Numeric mode without leading 0 (treat as octal)
        newUmask = Number.parseInt(modeArg, 8)
      }
      else if (/^[ugoa]*[+=-][rwxXst]+$/.test(modeArg)) {
        // Symbolic mode (e.g., u=rwx,g=rx,o=rx)
        // This is a simplified implementation
        // In a real shell, this would be more complex
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'umask: symbolic mode not yet implemented\n',
          duration: performance.now() - start,
        }
      }
      else {
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'umask: invalid mode\n',
          duration: performance.now() - start,
        }
      }

      if (Number.isNaN(newUmask) || newUmask < 0 || newUmask > 0o777) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: 'umask: invalid mode\n',
          duration: performance.now() - start,
        }
      }

      shell.umask = newUmask
      const res: CommandResult = {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
      if (shell.config.verbose)
        shell.log.debug('[umask] set to %s in %dms', shell.umask.toString(8).padStart(3, '0'), Math.round(res.duration || 0))
      return res
    }

    // No mode provided, display current umask
    let output = ''

    if (preserveOutput) {
      output = `umask ${shell.umask.toString(8).padStart(3, '0')}\n`
    }
    else if (printSymbolic) {
      // Convert umask to symbolic representation (e.g., u=rwx,g=rx,o=rx)
      const u = (shell.umask >> 6) & 0o7
      const g = (shell.umask >> 3) & 0o7
      const o = shell.umask & 0o7

      const toSymbolic = (mask: number) => {
        const r = (mask & 0o4) ? '' : 'r'
        const w = (mask & 0o2) ? '' : 'w'
        const x = (mask & 0o1) ? '' : 'x'
        return r + w + x
      }

      output = `u=${toSymbolic(u)},g=${toSymbolic(g)},o=${toSymbolic(o)}\n`
    }
    else {
      output = `${shell.umask.toString(8).padStart(3, '0')}\n`
    }

    const res: CommandResult = {
      exitCode: 0,
      stdout: output,
      stderr: '',
      duration: performance.now() - start,
    }
    if (shell.config.verbose)
      shell.log.debug('[umask] display mode=%s output=%s in %dms', preserveOutput ? 'preserve' : printSymbolic ? 'symbolic' : 'numeric', output.trim(), Math.round(res.duration || 0))
    return res
  },
}
