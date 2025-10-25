import type { Buffer } from 'node:buffer'
import type { ChildProcess } from 'node:child_process'
import type { Logger } from '../logger'
import type { CommandResult, KrustyConfig } from '../types'
import { spawn } from 'node:child_process'
import process from 'node:process'
import { RedirectionHandler } from '../utils/redirection'

interface ChildProcessInfo {
  child: ChildProcess
  exitPromise: Promise<number>
  command: string
}

export class CommandExecutor {
  private children: ChildProcessInfo[] = []
  private stderrChunks: string[] = []
  private stdoutChunks: string[] = []
  private commandFailed = false
  private lastExitCode = 0
  private xtrace = false
  private pipefail = false
  private lastXtraceLine: string | undefined

  constructor(
    private config: KrustyConfig,
    private cwd: string,
    private environment: Record<string, string>,
    private log: Logger,
  ) {}

  setXtrace(enabled: boolean): void {
    this.xtrace = enabled
  }

  setPipefail(enabled: boolean): void {
    this.pipefail = enabled
  }

  getLastExitCode(): number {
    return this.lastExitCode
  }

  getLastXtraceLine(): string | undefined {
    return this.lastXtraceLine
  }

  private processAliasArgument(arg: string): string {
    if (!arg)
      return ''
    // Handle quoted strings
    if ((arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))) {
      return arg.slice(1, -1)
    }
    // Handle escaped characters by removing the backslash
    return arg.replace(/\\(.)/g, '$1')
  }

  private needsInteractiveTTY(command: { name?: string, background?: boolean }, redirections: any[] = []): boolean {
    try {
      if (!process.stdin.isTTY || !process.stdout.isTTY) {
        return false
      }
    }
    catch {
      return false
    }

    if (!command || !command.name || command.background) {
      return false
    }

    // Only consider simple foreground commands without redirections
    if (Array.isArray(redirections) && redirections.length > 0) {
      return false
    }

    const name = String(command.name).toLowerCase()
    // Common interactive commands that require a TTY
    const interactiveNames = new Set(['sudo', 'ssh', 'sftp', 'scp', 'passwd', 'su'])
    return interactiveNames.has(name)
  }

  async executeExternalCommand(
    command: { name: string, args?: string[], background?: boolean },
    _redirections: any[] = [],
  ): Promise<CommandResult> {
    const start = performance.now()
    const commandStr = [command.name, ...(command.args || [])].join(' ')

    if (this.xtrace) {
      process.stderr.write(`+ ${commandStr}\n`)
    }

    // Handle redirections - use static methods
    const { cleanCommand: _, redirections: parsedRedirections } = RedirectionHandler.parseRedirections(commandStr)
    const stdio: ['pipe', 'pipe', 'pipe'] = ['pipe', 'pipe', 'pipe']

    // Prepare environment
    const cleanEnv = {
      ...process.env,
      ...this.environment,
      FORCE_COLOR: '1',
      TERM: process.env.TERM || 'xterm-256color',
    }

    // Spawn the process - use sh -c for shell features but handle quotes properly
    const args = command.args || []
    const shouldStream = (this.config.streamOutput !== false) && !command.background
    const escapedArgs = args.map((arg) => {
      // If arg contains single quotes, wrap in double quotes
      if (arg.includes('\'')) {
        return `"${arg}"`
      }
      // If arg contains spaces but no quotes, wrap in single quotes
      if (arg.includes(' ') && !arg.startsWith('"') && !arg.startsWith('\'')) {
        return `'${arg}'`
      }
      return arg
    })
    const fullCommand = [command.name, ...escapedArgs].join(' ')

    const child = spawn('/bin/sh', ['-c', fullCommand], {
      cwd: this.cwd,
      env: cleanEnv,
      stdio,
      windowsHide: true,
    }) as ChildProcess

    // Handle background processes
    if (command.background) {
      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
        streamed: false,
      }
    }

    // Apply redirections after spawning (non-blocking)
    if (parsedRedirections.length > 0) {
      RedirectionHandler.applyRedirections(child, parsedRedirections, this.cwd).catch(() => {})
    }

    // Capture output and handle process completion
    let stdout = ''
    let stderr = ''

    if (child.stdout) {
      child.stdout.on('data', (data: Buffer) => {
        const str = data.toString()
        stdout += str
        if (shouldStream) {
          process.stdout.write(str)
        }
      })
    }

    if (child.stderr) {
      child.stderr.on('data', (data: Buffer) => {
        const str = data.toString()
        stderr += str
        if (shouldStream) {
          process.stderr.write(str)
        }
      })
    }

    // Wait for process completion with timeout
    const timeoutMs = this.config.execution?.defaultTimeoutMs ?? (process.env.NODE_ENV === 'test' ? 10000 : 1000)
    let timedOut = false

    const exitCode = await Promise.race([
      new Promise<number>((resolve) => {
        child.on('exit', (code: number | null, signal: NodeJS.Signals | null) => {
          this.children = this.children.filter(c => c.child.pid !== child.pid)
          resolve(code ?? (signal === 'SIGINT' ? 130 : 1))
        })
      }),
      new Promise<number>((resolve) => {
        setTimeout(() => {
          timedOut = true
          child.kill(this.config.execution?.killSignal as NodeJS.Signals || 'SIGTERM')
          // Give process a chance to exit gracefully, then force kill
          setTimeout(() => {
            if (!child.killed) {
              child.kill('SIGKILL')
            }
          }, 100)
          this.children = this.children.filter(c => c.child.pid !== child.pid)
          resolve(124) // timeout exit code
        }, timeoutMs)
      }),
    ])

    // Add timeout message to stderr if process timed out
    if (timedOut) {
      stderr += `krusty: process timed out after ${timeoutMs}ms\n`
    }

    const end = performance.now()
    const duration = end - start

    if (this.xtrace) {
      process.stderr.write(`[exit] ${exitCode} (${duration.toFixed(2)}ms)\n`)
    }

    this.lastExitCode = exitCode

    return {
      exitCode,
      stdout,
      stderr,
      duration,
      streamed: shouldStream,
    }
  }

  async executePipedCommands(
    commands: Array<{ name: string, args?: string[], background?: boolean }>,
    _redirections: any[] = [],
  ): Promise<CommandResult> {
    if (commands.length === 0) {
      return {
        exitCode: 0,
        stdout: '',
        stderr: 'No commands provided',
        duration: 0,
        streamed: false,
      }
    }

    // For single command, use executeExternalCommand
    if (commands.length === 1) {
      return this.executeExternalCommand(commands[0], _redirections)
    }

    const start = performance.now()
    const commandStr = commands.map(cmd => `${cmd.name} ${(cmd.args || []).join(' ')}`).join(' | ')

    if (this.xtrace) {
      process.stderr.write(`+ ${commandStr}\n`)
    }

    const cleanEnv = {
      ...process.env,
      ...this.environment,
      FORCE_COLOR: '1',
      TERM: process.env.TERM || 'xterm-256color',
    }

    try {
      // If pipefail is enabled, we need to handle it ourselves by executing commands individually
      if (this.pipefail) {
        return await this.executePipelineWithPipefail(commands, cleanEnv, start)
      }

      // Default behavior: delegate to shell with normal pipeline semantics
      const child = spawn('/bin/sh', ['-c', commandStr], {
        cwd: this.cwd,
        env: cleanEnv,
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      }) as ChildProcess

      let stdout = ''
      let stderr = ''

      if (child.stdout) {
        child.stdout.on('data', (data: Buffer) => {
          stdout += data.toString()
        })
      }

      if (child.stderr) {
        child.stderr.on('data', (data: Buffer) => {
          stderr += data.toString()
        })
      }

      // Wait for process completion with timeout
      const timeoutMs = this.config.execution?.defaultTimeoutMs ?? (process.env.NODE_ENV === 'test' ? 10000 : 2000)
      let timedOut = false

      const exitCode = await Promise.race([
        new Promise<number>((resolve) => {
          child.on('exit', (code: number | null, signal: NodeJS.Signals | null) => {
            resolve(code ?? (signal === 'SIGINT' ? 130 : 1))
          })
        }),
        new Promise<number>((resolve) => {
          setTimeout(() => {
            timedOut = true
            child.kill(this.config.execution?.killSignal as NodeJS.Signals || 'SIGTERM')
            // Give process a chance to exit gracefully, then force kill
            setTimeout(() => {
              if (!child.killed) {
                child.kill('SIGKILL')
              }
            }, 100)
            resolve(124) // timeout exit code
          }, timeoutMs)
        }),
      ])

      // Add timeout message to stderr if process timed out
      if (timedOut) {
        stderr += `krusty: process timed out after ${timeoutMs}ms\n`
      }

      const end = performance.now()
      const duration = end - start

      if (this.xtrace) {
        process.stderr.write(`[pipeline exit] ${exitCode} (${duration.toFixed(2)}ms)\n`)
      }

      return {
        exitCode,
        stdout,
        stderr,
        duration,
        streamed: this.config.streamOutput !== false,
      }
    }
    catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error)
      return {
        exitCode: 1,
        stdout: '',
        stderr: `Error executing pipeline: ${errorMessage}\n`,
        duration: performance.now() - start,
        streamed: false,
      }
    }
  }

  private async executePipelineWithPipefail(
    commands: Array<{ name: string, args?: string[], background?: boolean }>,
    cleanEnv: Record<string, string>,
    start: number,
  ): Promise<CommandResult> {
    // When pipefail is enabled, we use shell's built-in pipefail support
    const commandStr = commands.map(cmd => `${cmd.name} ${(cmd.args || []).join(' ')}`).join(' | ')

    // Use bash with pipefail enabled for proper pipeline error handling
    // Note: pipefail is a bash feature, not available in basic sh
    const child = spawn('/bin/bash', ['-c', `set -o pipefail; ${commandStr}`], {
      cwd: this.cwd,
      env: cleanEnv,
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    }) as ChildProcess

    let stdout = ''
    let stderr = ''

    if (child.stdout) {
      child.stdout.on('data', (data: Buffer) => {
        stdout += data.toString()
      })
    }

    if (child.stderr) {
      child.stderr.on('data', (data: Buffer) => {
        stderr += data.toString()
      })
    }

    // Wait for process completion with timeout
    const timeoutMs = this.config.execution?.defaultTimeoutMs ?? (process.env.NODE_ENV === 'test' ? 10000 : 2000)
    let timedOut = false

    const exitCode = await Promise.race([
      new Promise<number>((resolve) => {
        child.on('exit', (code: number | null, signal: NodeJS.Signals | null) => {
          resolve(code ?? (signal === 'SIGINT' ? 130 : 1))
        })
      }),
      new Promise<number>((resolve) => {
        setTimeout(() => {
          timedOut = true
          child.kill(this.config.execution?.killSignal as NodeJS.Signals || 'SIGTERM')
          // Give process a chance to exit gracefully, then force kill
          setTimeout(() => {
            if (!child.killed) {
              child.kill('SIGKILL')
            }
          }, 100)
          resolve(124) // timeout exit code
        }, timeoutMs)
      }),
    ])

    // Add timeout message to stderr if process timed out
    if (timedOut) {
      stderr += `krusty: process timed out after ${timeoutMs}ms\n`
    }

    const end = performance.now()
    const duration = end - start

    if (this.xtrace) {
      process.stderr.write(`[pipefail pipeline exit] ${exitCode} (${duration.toFixed(2)}ms)\n`)
    }

    return {
      exitCode,
      stdout,
      stderr,
      duration,
      streamed: this.config.streamOutput !== false,
    }
  }
}
