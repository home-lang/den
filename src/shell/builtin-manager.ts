import type { BuiltinCommand, CommandResult, Shell } from '../types'
import process from 'node:process'
import { createBuiltins } from '../builtins'

export class BuiltinManager {
  private builtins: Map<string, BuiltinCommand>
  private shell: Shell

  constructor(shell: Shell) {
    this.shell = shell
    this.builtins = createBuiltins()
  }

  getBuiltins(): Map<string, BuiltinCommand> {
    return this.builtins
  }

  hasBuiltin(name: string): boolean {
    return this.builtins.has(name)
  }

  getBuiltin(name: string): BuiltinCommand | undefined {
    return this.builtins.get(name)
  }

  async executeBuiltin(name: string, args: string[], redirections?: any[]): Promise<CommandResult> {
    const builtin = this.builtins.get(name)
    if (!builtin) {
      throw new Error(`Builtin command '${name}' not found`)
    }

    // Handle background processes for builtins
    const command = { name, args, background: false }
    if ((command as any).background) {
      // For background builtins, execute asynchronously and add to jobs
      const jobId = this.shell.addJob((command as any).raw || `${name} ${args.join(' ')}`)

      // Execute builtin in background (don't await)
      builtin.execute(args, this.shell).then(async (result) => {
        // Apply redirections if needed
        if (redirections && redirections.length > 0) {
          await this.applyRedirectionsToBuiltinResult(result, redirections)
        }
        // Mark job as done
        this.shell.setJobStatus(jobId, 'done')
      }).catch(() => {
        this.shell.setJobStatus(jobId, 'done')
      })

      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: 0,
      }
    }

    // xtrace for builtins: print command before execution
    if ((this.shell as any).xtrace) {
      const formatArg = (a: string) => (/\s/.test(a) ? `"${a}"` : a)
      const argsStr = Array.isArray(args) ? args.map((a: string) => formatArg(a)).join(' ') : ''
      const line = `+ ${name}${argsStr ? ` ${argsStr}` : ''}`
      ;(this.shell as any).lastXtraceLine = line
      try {
        process.stderr.write(`${line}\n`)
      }
      catch {}
    }

    // Process arguments to remove quotes for builtin commands (except alias which handles quotes itself)
    const processedArgs = name === 'alias'
      ? args
      : args.map((arg: string) => this.processAliasArgument(arg))

    const result = await builtin.execute(processedArgs, this.shell)

    // Apply redirections to builtin output if needed
    if (redirections && redirections.length > 0) {
      await this.applyRedirectionsToBuiltinResult(result, redirections)
      // Determine which streams were redirected and clear them from the buffered result
      const affectsStdout = redirections.some(r => r?.type === 'file' && (
        r.direction === 'output' || r.direction === 'append' || r.direction === 'both'
      ))
      const affectsStderr = redirections.some(r => r?.type === 'file' && (
        r.direction === 'error' || r.direction === 'error-append' || r.direction === 'both'
      ))
      return {
        ...result,
        stdout: affectsStdout ? '' : (result.stdout || ''),
        stderr: affectsStderr ? '' : (result.stderr || ''),
      }
    }

    return result
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

  /**
   * Apply redirections to builtin command results
   */
  private async applyRedirectionsToBuiltinResult(result: CommandResult, redirections: any[]): Promise<void> {
    for (const redirection of redirections) {
      // Handle FD duplication/closing for builtin results by manipulating buffers
      if (redirection.type === 'fd') {
        const fd: number | undefined = redirection.fd
        const dst: string = redirection.target
        if (typeof fd === 'number') {
          if (dst === '&-') {
            // Close: discard the selected stream buffer
            if (fd === 1) {
              result.stdout = ''
            }
            else if (fd === 2) {
              result.stderr = ''
            }
            else if (fd === 0) {
              // stdin close has no effect on already-produced builtin output
            }
          }
          else {
            const m = dst.match(/^&(\d+)$/)
            if (m) {
              const targetFd = Number.parseInt(m[1], 10)
              // Duplicate: merge buffers accordingly
              if (fd === 2 && targetFd === 1) {
                // 2>&1: send stderr to stdout
                result.stdout = (result.stdout || '') + (result.stderr || '')
                result.stderr = ''
              }
              else if (fd === 1 && targetFd === 2) {
                // 1>&2: send stdout to stderr
                result.stderr = (result.stderr || '') + (result.stdout || '')
                result.stdout = ''
              }
              // Other FDs are not represented for builtins; ignore safely
            }
          }
        }
        continue
      }

      if (redirection.type === 'file') {
        let rawTarget = typeof redirection.target === 'string' && redirection.target.startsWith('APPEND::')
          ? redirection.target.replace(/^APPEND::/, '')
          : redirection.target
        if (typeof rawTarget === 'string' && ((rawTarget.startsWith('"') && rawTarget.endsWith('"')) || (rawTarget.startsWith('\'') && rawTarget.endsWith('\'')))) {
          rawTarget = rawTarget.slice(1, -1)
        }
        if (typeof rawTarget !== 'string') {
          continue
        }
        const outputFile: string = rawTarget.startsWith('/') ? rawTarget : `${(this.shell as any).cwd}/${rawTarget}`

        if (redirection.direction === 'input') {
          // Input redirections do not affect builtin buffered output here
          continue
        }

        if (redirection.direction === 'output') {
          const { writeFileSync } = await import('node:fs')
          writeFileSync(outputFile, result.stdout || '')
          // If only stdout was redirected, clear it from the result
          result.stdout = ''
        }
        else if (redirection.direction === 'append') {
          const { appendFileSync } = await import('node:fs')
          appendFileSync(outputFile, result.stdout || '')
          result.stdout = ''
        }
        else if (redirection.direction === 'error') {
          const { writeFileSync } = await import('node:fs')
          writeFileSync(outputFile, result.stderr || '')
          result.stderr = ''
        }
        else if (redirection.direction === 'error-append') {
          const { appendFileSync } = await import('node:fs')
          appendFileSync(outputFile, result.stderr || '')
          result.stderr = ''
        }
        else if (redirection.direction === 'both') {
          const isAppend = typeof redirection.target === 'string' && redirection.target.startsWith('APPEND::')
          if (isAppend) {
            const { appendFileSync } = await import('node:fs')
            if (result.stdout) {
              appendFileSync(outputFile, result.stdout)
            }
            if (result.stderr) {
              appendFileSync(outputFile, result.stderr)
            }
          }
          else {
            const { writeFileSync } = await import('node:fs')
            // Write stdout then stderr to mimic streaming order approximation
            writeFileSync(outputFile, result.stdout || '')
            if (result.stderr) {
              const { appendFileSync } = await import('node:fs')
              appendFileSync(outputFile, result.stderr)
            }
          }
          // Clear both since they were redirected together
          result.stdout = ''
          result.stderr = ''
        }
      }
    }
  }
}
