import type { BuiltinCommand, CommandResult, Shell } from './types'
import { spawn } from 'node:child_process'
import process from 'node:process'

export const execCommand: BuiltinCommand = {
  name: 'exec',
  description: 'Execute a command',
  usage: 'exec command [arguments...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const name = args.shift()
    if (!name)
      return { exitCode: 2, stdout: '', stderr: 'exec: command required\n', duration: performance.now() - start }

    // Minimal: execute external command with shell environment/cwd and stream output
    return new Promise<CommandResult>((resolve) => {
      const child = spawn(name, args, { cwd: shell.cwd, env: shell.environment, stdio: ['inherit', 'pipe', 'pipe'] })
      let stdout = ''
      let stderr = ''
      child.stdout?.on('data', (d) => {
        const s = d.toString()
        stdout += s
        process.stdout.write(s)
      })
      child.stderr?.on('data', (d) => {
        const s = d.toString()
        stderr += s
        process.stderr.write(s)
      })
      child.on('close', (code) => {
        resolve({ exitCode: code ?? 0, stdout, stderr, duration: performance.now() - start })
      })
      child.on('error', () => {
        resolve({ exitCode: 127, stdout: '', stderr: `exec: ${name}: command not found\n`, duration: performance.now() - start })
      })
    })
  },
}
