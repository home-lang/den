import type { BuiltinCommand, CommandResult, Shell } from '../types'

export const setCommand: BuiltinCommand = {
  name: 'set',
  description: 'Set shell options and positional parameters or display variables',
  usage: 'set [-eux] [-o option] [+eux] [+o option] [name=value ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // If no args: print all environment variables as KEY=VALUE, sorted
    if (args.length === 0) {
      const lines = Object.keys(shell.environment)
        .sort((a, b) => a.localeCompare(b))
        .map(k => `${k}=${shell.environment[k]}`)
        .join('\n')
      return {
        exitCode: 0,
        stdout: lines + (lines ? '\n' : ''),
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Parse flags: -e (ignored here), -u, -x, -o pipefail and their + counterparts
    let i = 0
    let sawE = false
    const setOption = (opt: string, on: boolean) => {
      switch (opt) {
        case 'u': shell.nounset = on
          break
        case 'x': shell.xtrace = on
          break
        default: break
      }
    }
    while (i < args.length && args[i].startsWith('-')) {
      const opt = args[i]
      if (opt === '--') {
        i++
        break
      }
      // If this is the dedicated option token (-o), stop here and let the
      // -o/+o handler below process it together with its option name.
      if (opt === '-o' || opt === '+o') {
        break
      }
      // handle combined flags like -ex; only -e recognized
      for (let j = 1; j < opt.length; j++) {
        const flag = opt[j]
        switch (flag) {
          case 'e':
            // could set a flag on shell.options if exists
            sawE = true
            break
          case 'u':
            setOption('u', true)
            break
          case 'x':
            setOption('x', true)
            break
          default:
            // ignore unknown flags for compatibility; continue
            break
        }
      }
      i++
    }

    // Handle + flags (disable)
    while (i < args.length && args[i].startsWith('+')) {
      const opt = args[i]
      // If this is the dedicated option token (+o), stop here and let the
      // -o/+o handler below process it together with its option name.
      if (opt === '+o') {
        break
      }
      for (let j = 1; j < opt.length; j++) {
        const flag = opt[j]
        if (flag === 'u' || flag === 'x')
          setOption(flag, false)
      }
      i++
    }

    // Handle -o / +o
    while (i < args.length && (args[i] === '-o' || args[i] === '+o')) {
      const enable = args[i] === '-o'
      const name = args[i + 1]
      if (!name)
        break
      if (name === 'pipefail') {
        shell.pipefail = enable
        // Sync with command executor if available (KrustyShell instance)
        if ('syncPipefailToExecutor' in shell && typeof shell.syncPipefailToExecutor === 'function') {
          shell.syncPipefailToExecutor(enable)
        }
      }
      i += 2
    }

    // Remaining args should be NAME=VALUE pairs
    const assignments: Array<{ name: string, value: string }> = []
    for (; i < args.length; i++) {
      const tok = args[i]
      if (!tok)
        continue
      const eq = tok.indexOf('=')
      if (eq === -1)
        continue
      const name = tok.slice(0, eq)
      let value = tok.slice(eq + 1)
      // If value is wrapped in matching quotes, strip them
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith('\'') && value.endsWith('\''))) {
        value = value.slice(1, -1)
      }
      if (name)
        shell.environment[name] = value
      assignments.push({ name, value })
    }

    if (shell.config.verbose) {
      shell.log.debug('[set] flags: -e=%s, nounset=%s, xtrace=%s, pipefail=%s, assignments: %o', String(sawE), String(shell.nounset), String(shell.xtrace), String(shell.pipefail), assignments)
    }

    return {
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
