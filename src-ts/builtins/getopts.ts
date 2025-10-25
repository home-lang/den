import type { BuiltinCommand, CommandResult, Shell } from './types'

// Minimal POSIX-like getopts: getopts optstring name [args...]
// Sets OPTIND, OPTARG; returns 0 while options remain, 1 at end or on error
export const getoptsCommand: BuiltinCommand = {
  name: 'getopts',
  description: 'Parse positional parameters as options',
  usage: 'getopts optstring name [args...]',
  examples: [
    'getopts "ab:" opt -a -b val',
    'getopts "f:" opt -f file.txt',
  ],
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    if (args.length < 2)
      return { exitCode: 2, stdout: '', stderr: 'getopts: usage: getopts optstring name [args]\n', duration: performance.now() - start }

    const optstring = args[0]
    const name = args[1]
    const params = args.slice(2)
    const env = shell.environment
    const optind = Number.parseInt(env.OPTIND || '1', 10) || 1

    if (shell.config.verbose)
      shell.log.debug('[getopts] start', { optstring, name, OPTIND: env.OPTIND ?? '1', params })

    if (optind > params.length) {
      env[name] = '?'
      env.OPTARG = ''
      return { exitCode: 1, stdout: '', stderr: '', duration: performance.now() - start }
    }

    const current = params[optind - 1]
    if (!current || !current.startsWith('-') || current === '-') {
      env[name] = '?'
      env.OPTARG = ''
      return { exitCode: 1, stdout: '', stderr: '', duration: performance.now() - start }
    }

    if (current === '--') {
      env.OPTIND = String(optind + 1)
      env[name] = '?'
      env.OPTARG = ''
      return { exitCode: 1, stdout: '', stderr: '', duration: performance.now() - start }
    }

    const flag = current.slice(1, 2)
    const expectsArg = optstring.includes(`${flag}:`)

    env[name] = flag

    if (expectsArg) {
      const next = params[optind] || ''
      env.OPTARG = next
      env.OPTIND = String(optind + 2)
    }
    else {
      env.OPTARG = ''
      env.OPTIND = String(optind + 1)
    }

    if (shell.config.verbose)
      shell.log.debug('[getopts] parsed', { flag, expectsArg, OPTARG: env.OPTARG, OPTIND: env.OPTIND })

    return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
  },
}
