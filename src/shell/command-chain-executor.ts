import type { CommandResult, ParsedCommand, Shell } from '../types'
import { ParseError } from '../parser'

export class CommandChainExecutor {
  private shell: Shell

  constructor(shell: Shell) {
    this.shell = shell
  }

  /**
   * Split input into operator-aware segments preserving quotes/escapes.
   */
  splitByOperators(input: string): Array<{ segment: string, op: ';' | '&&' | '||' | null }> {
    const segments: Array<{ segment: string, op: ';' | '&&' | '||' | null }> = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false
    let currentOp: ';' | '&&' | '||' | null = null // operator to the left of the segment being built

    const push = () => {
      const seg = current.trim()
      if (seg.length > 0)
        segments.push({ segment: seg, op: currentOp })
      current = ''
    }

    for (let i = 0; i < input.length; i++) {
      const ch = input[i]
      const next = input[i + 1]

      if (escaped) {
        current += ch
        escaped = false
        continue
      }
      if (ch === '\\') {
        escaped = true
        current += ch
        continue
      }
      if (!inQuotes && (ch === '"' || ch === '\'')) {
        inQuotes = true
        quoteChar = ch
        current += ch
        continue
      }
      if (inQuotes && ch === quoteChar) {
        inQuotes = false
        quoteChar = ''
        current += ch
        continue
      }

      if (!inQuotes) {
        // Detect && and ||
        if (ch === '&' && next === '&') {
          push()
          currentOp = '&&'
          i++ // skip next
          continue
        }
        if (ch === '|' && next === '|') {
          push()
          currentOp = '||'
          i++ // skip next
          continue
        }
        if (ch === ';') {
          push()
          currentOp = ';'
          continue
        }
      }

      current += ch
    }

    // push final with its left operator
    push()

    return segments
  }

  aggregateResults(base: CommandResult | null, next: CommandResult): CommandResult {
    if (!base)
      return { ...next }
    return {
      exitCode: next.exitCode,
      stdout: (base.stdout || '') + (next.stdout || ''),
      stderr: (base.stderr || '') + (next.stderr || ''),
      duration: (base.duration || 0) + (next.duration || 0),
      streamed: (base.streamed === true) || (next.streamed === true),
    }
  }

  async executeCommandChain(input: string, options?: { bypassAliases?: boolean, bypassFunctions?: boolean, bypassScriptDetection?: boolean, aliasDepth?: number }): Promise<CommandResult> {
    const start = performance.now()

    try {
      // Skip empty commands
      if (!input.trim()) {
        return {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: performance.now() - start,
        }
      }

      // Check if this is a script before doing any parsing (but only if not bypassing script detection)
      if (!options?.bypassScriptDetection) {
        const scriptExecutor = (this.shell as any).scriptExecutor
        if (scriptExecutor && scriptExecutor.isScript(input)) {
          const result = await scriptExecutor.executeScript(input)
          return {
            ...result,
            duration: performance.now() - start,
          }
        }
      }

      // Operator-aware chaining: split into segments with ;, &&, ||
      const chain = (this.shell as any).parser.splitByOperatorsDetailed(input)
      if (chain.length > 1) {
        let aggregate: CommandResult | null = null
        let lastExit = 0
        for (let i = 0; i < chain.length; i++) {
          const { segment } = chain[i]
          // Conditional execution based on previous operator
          if (i > 0) {
            const prevOp = chain[i - 1].op
            if (prevOp === '&&' && lastExit !== 0)
              continue
            if (prevOp === '||' && lastExit === 0)
              continue
          }

          // If this segment is a script construct (if/for/while/functions/etc),
          // execute it via the script engine and treat its exit code for chaining.
          try {
            const scriptExecutor = (this.shell as any).scriptExecutor
            if (scriptExecutor && scriptExecutor.isScript(segment)) {
              const segResult = await scriptExecutor.executeScript(segment)
              lastExit = segResult.exitCode
              aggregate = this.aggregateResults(aggregate, segResult)
              continue
            }
          }
          catch (err) {
            const msg = err instanceof Error ? err.message : String(err)
            const stderr = `krusty: script error: ${msg}\n`
            const segResult = { exitCode: 2, stdout: '', stderr, duration: 0 }
            aggregate = this.aggregateResults(aggregate, segResult)
            lastExit = segResult.exitCode
            break
          }

          // Check for alias expansion in this segment before parsing
          let expandedSegment = segment
          if (!options?.bypassAliases) {
            const parser = (this.shell as any).parser
            const tokens = parser.tokenize(segment.trim())
            if (tokens.length > 0 && tokens[0] in (this.shell as any).aliases) {
              const aliasValue = (this.shell as any).aliases[tokens[0]]
              const args = tokens.slice(1)

              // Handle parameter substitution
              const hasPlaceholders = /\$@|\$\d+/.test(aliasValue)

              if (hasPlaceholders) {
                // Replace $@ with all arguments
                expandedSegment = aliasValue.replace(/\$@/g, () => {
                  return args.map((arg: string) => {
                    let cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                      ? arg.slice(1, -1)
                      : arg
                    cleanArg = cleanArg.replace(/\$/g, '\\$')
                    cleanArg = cleanArg.replace(/'/g, '\\\'\'')
                    return cleanArg
                  }).join(' ')
                })

                // Replace $1, $2, etc. with positional arguments
                for (let j = 1; j <= args.length; j++) {
                  const arg = args[j - 1] || ''

                  if (expandedSegment.includes(`"$${j}"`)) {
                    const cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                      ? arg.slice(1, -1)
                      : arg
                    expandedSegment = expandedSegment.replace(`"$${j}"`, `\\"${cleanArg}\\"`)
                  }
                  else if (expandedSegment.includes(`'$${j}'`)) {
                    const cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                      ? arg.slice(1, -1)
                      : arg
                    expandedSegment = expandedSegment.replace(`'$${j}'`, `'${cleanArg}'`)
                  }
                  else if (expandedSegment.includes(`$${j}`)) {
                    expandedSegment = expandedSegment.replace(`$${j}`, arg)
                  }
                }

                expandedSegment = expandedSegment.replace(/\$\d+/g, '')
              }
              else {
                // Handle trailing space expansion or append arguments
                if (aliasValue.endsWith(' ') && args.length > 0) {
                  expandedSegment = `${aliasValue}${args.join(' ')}`
                }
                else if (args.length > 0) {
                  expandedSegment = `${aliasValue} ${args.join(' ')}`
                }
                else {
                  expandedSegment = aliasValue
                }
              }
            }
          }

          // Parse + execute this segment (supports pipes/redirections inside)
          let segParsed: ParsedCommand
          try {
            segParsed = await (this.shell as any).parseCommand(expandedSegment)
          }
          catch (err) {
            const msg = err instanceof Error ? err.message : String(err)
            // Build a caret indicator when feasible (unterminated quotes -> caret at end)
            const caretIdx = expandedSegment.length // best-effort: end of segment for unterminated quotes
            const caretLine = `${expandedSegment}\n${' '.repeat(Math.max(0, caretIdx))}^\n`
            const stderr = `krusty: syntax error: ${msg}\n${caretLine}`
            const segResult = { exitCode: 2, stdout: '', stderr, duration: 0 }
            // Include parse error in aggregation and stop processing further segments
            aggregate = this.aggregateResults(aggregate, segResult)
            lastExit = segResult.exitCode
            break
          }
          if (segParsed.commands.length === 0)
            continue

          const segResult = await (this.shell as any).executeCommandChain(segParsed, options)
          lastExit = segResult.exitCode
          aggregate = this.aggregateResults(aggregate, segResult)
        }

        const result = aggregate || { exitCode: lastExit, stdout: '', stderr: '', duration: performance.now() - start }
        ;(this.shell as any).lastExitCode = result.exitCode
        ;(this.shell as any).lastCommandDurationMs = result.duration || 0
        return result
      }

      // Check for alias expansion before parsing
      if (!options?.bypassAliases) {
        // Parse input to extract command and arguments properly
        const parser = (this.shell as any).parser
        const tokens = parser.tokenize(input.trim())
        if (tokens.length > 0 && tokens[0] in (this.shell as any).aliases) {
          const aliasValue = (this.shell as any).aliases[tokens[0]]
          const args = tokens.slice(1)

          // Handle parameter substitution
          let expandedInput = aliasValue
          const hasPlaceholders = /\$@|\$\d+/.test(aliasValue)

          if (hasPlaceholders) {
            // Replace $@ with all arguments - preserve special characters
            expandedInput = expandedInput.replace(/\$@/g, () => {
              return args.map((arg: string) => {
                // Remove outer quotes if present but preserve the content
                let cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                  ? arg.slice(1, -1)
                  : arg
                // Escape $ characters to prevent shell variable expansion
                cleanArg = cleanArg.replace(/\$/g, '\\$')
                // Escape single quotes to prevent shell parsing issues
                cleanArg = cleanArg.replace(/'/g, '\\\'\'')
                return cleanArg
              }).join(' ')
            })

            // Replace $1, $2, etc. with positional arguments
            for (let i = 1; i <= args.length; i++) {
              const arg = args[i - 1] || ''

              // Handle quoted and unquoted placeholders
              if (expandedInput.includes(`"$${i}"`)) {
                // Quoted placeholder - preserve quotes by using escaped quotes
                const cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                  ? arg.slice(1, -1)
                  : arg
                expandedInput = expandedInput.replace(`"$${i}"`, `\\"${cleanArg}\\"`)
              }
              else if (expandedInput.includes(`'$${i}'`)) {
                const cleanArg = (arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))
                  ? arg.slice(1, -1)
                  : arg
                expandedInput = expandedInput.replace(`'$${i}'`, `'${cleanArg}'`)
              }
              else if (expandedInput.includes(`$${i}`)) {
                // Unquoted placeholder - use arg as-is
                expandedInput = expandedInput.replace(`$${i}`, arg)
              }
            }

            // Remove any remaining unreplaced placeholders
            expandedInput = expandedInput.replace(/\$\d+/g, '')
          }
          else {
            // Handle trailing space expansion or append arguments
            if (aliasValue.endsWith(' ') && args.length > 0) {
              expandedInput = `${aliasValue}${args.join(' ')}`
            }
            else if (args.length > 0) {
              expandedInput = `${aliasValue} ${args.join(' ')}`
            }
          }

          // Execute the expanded command
          return await this.executeCommandChain(expandedInput, {
            ...options,
            aliasDepth: (options?.aliasDepth || 0) + 1,
          })
        }
      }

      // Parse the command (no operator chain)
      let parsed
      try {
        parsed = await (this.shell as any).parseCommand(input)
      }
      catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        // Prefer precise caret index from parser when available
        let caretIdx = input.length
        if (err instanceof ParseError && typeof err.index === 'number') {
          // Parser calculated index relative to trimmed input. Map to original input by offsetting
          const startIdx = input.search(/\S|$/)
          caretIdx = Math.max(0, Math.min(input.length, startIdx + err.index))
        }
        const caretLine = `${input}\n${' '.repeat(Math.max(0, caretIdx))}^\n`
        const stderr = `krusty: syntax error: ${msg}\n${caretLine}`
        const result = { exitCode: 2, stdout: '', stderr, duration: performance.now() - start }
        return result
      }
      if (parsed.commands.length === 0) {
        return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
      }

      // Execute command chain (pipes/redirections)
      const result = await (this.shell as any).executeCommandChain(parsed, options)
      ;(this.shell as any).lastExitCode = result.exitCode
      ;(this.shell as any).lastCommandDurationMs = result.duration || 0

      return result
    }
    catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error'
      const result = {
        exitCode: 1,
        stdout: '',
        stderr: `krusty: ${errorMessage}\n`,
        duration: performance.now() - start,
      }
      ;(this.shell as any).lastExitCode = result.exitCode
      ;(this.shell as any).lastCommandDurationMs = result.duration || 0

      return result
    }
  }
}
