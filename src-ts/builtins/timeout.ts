import type { BuiltinCommand, CommandResult, Shell } from './types'
import { spawn } from 'node:child_process'
import process from 'node:process'

function parseDuration(input: string): number | null {
  // Supports float seconds with optional unit: s (seconds), m (minutes), h (hours), d (days)
  // Defaults to seconds if no unit.
  const m = input.match(/^(\d+(?:\.\d+)?|\.\d+)\s*([smhd])?$/)
  if (!m)
    return null
  const value = Number.parseFloat(m[1])
  if (Number.isNaN(value) || value < 0)
    return null
  const unit = m[2] || 's'
  const multipliers: Record<string, number> = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 }
  return Math.floor(value * multipliers[unit])
}

/**
 * timeout - run a command with a time limit
 * Usage: timeout SECONDS command [args...]
 *
 * Notes:
 * - This implementation reports a timeout (exit 124) if the time limit elapses,
 *   but cannot forcibly terminate a running builtin or external command due to
 *   API constraints. Tests avoid relying on hard cancellation.
 */
export const timeoutCommand: BuiltinCommand = {
  name: 'timeout',
  description: 'Run a command with a time limit',
  usage: 'timeout [ -s SIGNAL ] [ -k DURATION ] DURATION command [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'timeout: missing duration\n',
        duration: performance.now() - start,
      }
    }
    // Options
    let signal: NodeJS.Signals | number | undefined = 'SIGTERM'
    let killAfterMs: number | undefined
    const positional: string[] = []

    // Parse options like: -s SIGNAL | --signal=SIGNAL, -k DURATION | --kill-after=DURATION
    while (args.length && args[0].startsWith('-')) {
      const opt = args.shift()!
      if (opt === '--')
        break
      if (opt === '-s' || opt === '--signal') {
        const v = args.shift()
        if (!v) {
          return { exitCode: 1, stdout: '', stderr: 'timeout: missing signal\n', duration: performance.now() - start }
        }
        signal = (v.toUpperCase().startsWith('SIG') ? v.toUpperCase() : (`SIG${v.toUpperCase()}`)) as NodeJS.Signals
        continue
      }
      if (opt.startsWith('--signal=')) {
        const v = opt.split('=')[1]
        signal = (v.toUpperCase().startsWith('SIG') ? v.toUpperCase() : (`SIG${v.toUpperCase()}`)) as NodeJS.Signals
        continue
      }
      if (opt === '-k' || opt === '--kill-after') {
        const v = args.shift()
        const ms = v ? parseDuration(v) : null
        if (ms === null) {
          return { exitCode: 1, stdout: '', stderr: `timeout: ${v}: invalid duration\n`, duration: performance.now() - start }
        }
        killAfterMs = ms
        continue
      }
      if (opt.startsWith('--kill-after=')) {
        const v = opt.split('=')[1]
        const ms = parseDuration(v)
        if (ms === null) {
          return { exitCode: 1, stdout: '', stderr: `timeout: ${v}: invalid duration\n`, duration: performance.now() - start }
        }
        killAfterMs = ms
        continue
      }
      // Unrecognized options fall through to positional (for simplicity)
      positional.push(opt)
      break
    }

    // Reconstruct remaining args
    const rest = [...positional, ...args]
    if (rest.length === 0) {
      return { exitCode: 1, stdout: '', stderr: 'timeout: missing duration\n', duration: performance.now() - start }
    }

    const durationStr = rest.shift()!
    const ms = parseDuration(durationStr)
    if (ms === null) {
      return { exitCode: 1, stdout: '', stderr: `timeout: ${durationStr}: invalid duration\n`, duration: performance.now() - start }
    }

    if (rest.length === 0) {
      return { exitCode: 1, stdout: '', stderr: 'timeout: missing command\n', duration: performance.now() - start }
    }

    // If duration is 0 ms, immediate timeout behavior: do not run the command
    if (ms === 0) {
      return { exitCode: 124, stdout: '', stderr: 'timeout: command timed out\n', duration: performance.now() - start }
    }

    const command = rest[0]
    const commandArgs = rest.slice(1)

    // If the command is a builtin, we cannot kill it; fall back to executeCommand with timeout flag
    if (shell.builtins.has(command)) {
      let timedOut = false
      let timer: ReturnType<typeof setTimeout> | null = null
      try {
        timer = setTimeout(() => {
          timedOut = true
        }, ms)
        const result = await shell.executeCommand(command, commandArgs)
        if (timer)
          clearTimeout(timer)
        if (timedOut) {
          return { exitCode: 124, stdout: '', stderr: 'timeout: command timed out\n', duration: performance.now() - start }
        }
        return { ...result, duration: performance.now() - start }
      }
      catch (error) {
        if (timer)
          clearTimeout(timer)
        return { exitCode: 1, stdout: '', stderr: `timeout: ${error instanceof Error ? error.message : 'execution failed'}\n`, duration: performance.now() - start }
      }
    }

    // External command execution with real termination
    const cleanEnv = Object.fromEntries(
      Object.entries({
        ...shell.environment,
        FORCE_COLOR: '3',
        COLORTERM: 'truecolor',
        TERM: 'xterm-256color',
        BUN_FORCE_COLOR: '3',
      }).filter(([_, v]) => v !== undefined) as [string, string][],
    )

    const child = spawn(command, commandArgs, { cwd: shell.cwd, env: cleanEnv, stdio: ['pipe', 'pipe', 'pipe'] })

    let stdout = ''
    let stderr = ''
    const shouldStream = shell.config.streamOutput !== false
    let timedOut = false

    const timeoutTimer = setTimeout(() => {
      timedOut = true
      try {
        child.kill(signal as any)
      }
      catch {}
      if (killAfterMs !== undefined) {
        setTimeout(() => {
          try {
            child.kill('SIGKILL')
          }
          catch {}
        }, killAfterMs)
      }
    }, ms)

    child.stdout?.on('data', (d) => {
      const s = d.toString()
      stdout += s
      if (shouldStream)
        process.stdout.write(s)
    })
    child.stderr?.on('data', (d) => {
      const s = d.toString()
      stderr += s
      if (shouldStream)
        process.stderr.write(s)
    })

    const result: CommandResult = await new Promise((resolve) => {
      child.on('error', () => {
        resolve({ exitCode: 127, stdout: '', stderr: `krusty: ${command}: command not found\n`, duration: performance.now() - start, streamed: false })
      })
      child.on('close', (code, _sig) => {
        clearTimeout(timeoutTimer)
        if (timedOut) {
          resolve({ exitCode: 124, stdout: '', stderr: 'timeout: command timed out\n', duration: performance.now() - start, streamed: shouldStream })
          return
        }
        resolve({ exitCode: code ?? 0, stdout, stderr, duration: performance.now() - start, streamed: shouldStream })
      })
    })

    return result
  },
}
