import type { BuiltinCommand, CommandResult, Shell } from '../types'

/**
 * Trap command - handle signals and other events
 * Allows setting up signal handlers for the shell
 */
export const trapCommand: BuiltinCommand = {
  name: 'trap',
  description: 'Trap signals and other events',
  usage: 'trap [action] [signal...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Initialize signal handlers if they don't exist
    if (!shell.signalHandlers) {
      shell.signalHandlers = new Map()
    }

    // If no arguments, list all traps
    if (args.length === 0) {
      if (shell.config.verbose)
        shell.log.debug('[trap] listing traps')
      const output: string[] = []

      for (const [signal, handler] of shell.signalHandlers.entries()) {
        if (handler) {
          output.push(`trap -- '${handler}' ${signal}`)
        }
        else {
          output.push(`trap -- '' ${signal}`)
        }
      }

      // Add default traps for common signals if not explicitly set
      const commonSignals = ['EXIT', 'SIGINT', 'SIGTERM', 'SIGHUP']

      for (const signal of commonSignals) {
        if (!shell.signalHandlers.has(signal)) {
          output.push(`trap -- '' ${signal}`)
        }
      }

      return {
        exitCode: 0,
        stdout: `${output.join('\n')}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // If first argument is '--', skip it (for POSIX compatibility)
    if (args[0] === '--') {
      args.shift()
    }

    // If no signals specified, default to all signals
    if (args.length === 1) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'trap: usage: trap [-lp] [[arg] signal_spec ...]\n',
        duration: performance.now() - start,
      }
    }

    const action = args[0]
    const signals = args.slice(1)
    if (shell.config.verbose)
      shell.log.debug('[trap] action=%s signals=%o', action, signals)

    // Handle -l flag (list signal names)
    if (action === '-l' || action === '--list') {
      const signalList = [
        'HUP',
        'INT',
        'QUIT',
        'ILL',
        'TRAP',
        'ABRT',
        'BUS',
        'FPE',
        'KILL',
        'USR1',
        'SEGV',
        'USR2',
        'PIPE',
        'ALRM',
        'TERM',
        'STKFLT',
        'CHLD',
        'CONT',
        'STOP',
        'TSTP',
        'TTIN',
        'TTOU',
        'URG',
        'XCPU',
        'XFSZ',
        'VTALRM',
        'PROF',
        'WINCH',
        'IO',
        'PWR',
        'SYS',
        'RTMIN',
        'RTMIN+1',
        'RTMIN+2',
        'RTMIN+3',
        'RTMAX-3',
        'RTMAX-2',
        'RTMAX-1',
        'RTMAX',
      ]

      return {
        exitCode: 0,
        stdout: `${signalList.map((sig, i) => `${i + 1}) ${sig}`).join('\n')}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Handle -p flag (print trap commands in a form that can be reused)
    if (action === '-p' || action === '--print') {
      const output: string[] = []

      for (const signal of signals) {
        const handler = shell.signalHandlers.get(signal)
        if (handler !== undefined) {
          output.push(`trap -- '${handler}' ${signal}`)
        }
      }

      return {
        exitCode: 0,
        stdout: `${output.join('\n')}\n`,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // If action is empty string, remove the trap
    if (action === '') {
      for (const signal of signals) {
        shell.signalHandlers.delete(signal)
      }

      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // If action is '-', reset to default handler
    if (action === '-') {
      for (const signal of signals) {
        shell.signalHandlers.set(signal, null)
      }

      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Set up the trap
    for (const signal of signals) {
      shell.signalHandlers.set(signal, action)

      // In a real implementation, we would set up the actual signal handler
      // For now, we'll just store the action
    }

    return {
      exitCode: 0,
      stdout: '',
      stderr: '',
      duration: performance.now() - start,
    }
  },
}
