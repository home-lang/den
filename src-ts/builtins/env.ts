import type { BuiltinCommand, CommandResult, Shell } from '../types'
import { spawn } from 'node:child_process'
import process from 'node:process'

export const envCommand: BuiltinCommand = {
  name: 'env',
  description: 'Print or run a command in a modified environment',
  usage: 'env [-i] [NAME=VALUE]... [command [args...]]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Parse options
    let ignoreEnv = false
    const assigns: Record<string, string> = {}
    const rest: string[] = []

    while (args.length) {
      const tok = args[0]
      if (tok === '-i') { // ignore environment
        ignoreEnv = true
        args.shift()
        continue
      }
      if (tok === '--') {
        args.shift()
        break
      }
      // NAME=VALUE assignments
      const m = tok.match(/^([A-Z_]\w*)=(.*)$/i)
      if (m) {
        assigns[m[1]] = m[2]
        args.shift()
        continue
      }
      break
    }

    // Remaining are command + args
    rest.push(...args)

    // Build the environment for printing or for the child
    const baseEnv = ignoreEnv ? {} as Record<string, string> : { ...shell.environment }
    const tempEnv: Record<string, string> = { ...baseEnv, ...assigns }

    // If there is no command, print environment (sorted). Respect -i by not injecting PWD.
    if (rest.length === 0) {
      if (!ignoreEnv) {
        try {
          if (shell.cwd)
            tempEnv.PWD = shell.cwd
        }
        catch {}
      }
      const lines = Object.keys(tempEnv)
        .sort((a, b) => a.localeCompare(b))
        .map(k => `${k}=${tempEnv[k]}`)
        .join('\n')
      return { exitCode: 0, stdout: lines + (lines ? '\n' : ''), stderr: '', duration: performance.now() - start }
    }

    // Execute a command with the temporary environment
    const command = rest[0]
    const commandArgs = rest.slice(1)

    // Builtin path: temporarily swap shell.environment
    if (shell.builtins.has(command)) {
      const prevEnv = shell.environment
      shell.environment = { ...tempEnv }
      try {
        const result = await shell.executeCommand(command, commandArgs)
        return { ...result, duration: performance.now() - start }
      }
      finally {
        shell.environment = prevEnv
      }
    }

    // External command: spawn
    const cleanEnv = Object.fromEntries(
      Object.entries({
        ...tempEnv,
        FORCE_COLOR: '3',
        COLORTERM: 'truecolor',
        TERM: 'xterm-256color',
        BUN_FORCE_COLOR: '3',
      }).filter(([_, v]) => v !== undefined) as [string, string][],
    )

    return await new Promise<CommandResult>((resolve) => {
      const child = spawn(command, commandArgs, { cwd: shell.cwd, env: cleanEnv, stdio: ['ignore', 'pipe', 'pipe'] })
      let stdout = ''
      let stderr = ''
      child.stdout?.on('data', (d) => {
        const s = d.toString()
        stdout += s
        if (shell.config.streamOutput !== false)
          process.stdout.write(s)
      })
      child.stderr?.on('data', (d) => {
        const s = d.toString()
        stderr += s
        if (shell.config.streamOutput !== false)
          process.stderr.write(s)
      })
      child.on('close', code => resolve({ exitCode: code ?? 0, stdout, stderr, duration: performance.now() - start }))
      child.on('error', () => resolve({ exitCode: 127, stdout: '', stderr: `krusty: ${command}: command not found\n`, duration: performance.now() - start }))
    })
  },
}
