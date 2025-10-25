import type { Shell } from '../types/shell'
import { spawn } from 'node:child_process'
import * as process from 'node:process'

export interface ExpansionContext {
  shell: Shell
  cwd: string
  environment: Record<string, string>
  /**
   * Controls command substitution security.
   * - 'sandbox' (default): only a small allowlist of commands permitted in $(...) and backticks.
   * - 'full': execute via system shell without restrictions.
   */
  substitutionMode?: 'sandbox' | 'full'
  /** Optional override allowlist for sandbox mode */
  sandboxAllow?: string[]
}

/**
 * Handles all forms of shell expansion including:
 * - Variable expansion: $VAR, ${VAR}, ${VAR:-default}, ${VAR:+alt}, ${VAR:?error}
 * - Command substitution: $(command), `command`
 * - Arithmetic expansion: $((expression))
 * - Brace expansion: {a,b,c}, {1..10}, {a..z}
 * - Process substitution: <(command), >(command)
 */
export class ExpansionEngine {
  constructor(private context: ExpansionContext) {}

  /**
   * Performs all expansions on the input string
   */
  async expand(input: string): Promise<string> {
    // Short-circuit if there is nothing to expand
    if (!ExpansionUtils.hasExpansion(input))
      return input

    let result = input

    // Order matters: do variable expansion first, then arithmetic, then brace, then command substitution
    result = await this.expandVariables(result)
    result = await this.expandArithmetic(result)
    result = this.expandBraces(result)
    result = await this.expandCommandSubstitution(result)
    result = await this.expandProcessSubstitution(result)

    return result
  }

  /**
   * Expands variables: $VAR, ${VAR}, ${VAR:-default}, etc.
   */
  private async expandVariables(input: string): Promise<string> {
    // Quick short-circuit: only proceed if we see ${...} or $NAME patterns
    if (!/\$\{[^}]+\}|\$[A-Z_]\w*/i.test(input))
      return input
    // Handle escaped variables by temporarily replacing them
    const escapedVars: string[] = []
    let result = input.replace(/\\\$/g, (_match) => {
      const placeholder = `__ESCAPED_VAR_${escapedVars.length}__`
      escapedVars.push('\\$')
      return placeholder
    })

    // Handle ${VAR} syntax with parameter expansion
    const parameterRegex = /\$\{([^}]+)\}/g
    result = result.replace(parameterRegex, (match, content) => {
      return this.expandParameter(content)
    })

    // Handle simple $VAR syntax (only uppercase variables and underscores)
    const simpleRegex = /\$([A-Z_][A-Z0-9_]*)/g
    result = result.replace(simpleRegex, (_match, varName) => {
      // Use shell environment first, then system environment
      if (varName in this.context.environment) {
        return this.context.environment[varName]
      }
      const sys = process.env[varName]
      if (sys !== undefined)
        return sys
      // Enforce nounset: error on unset variables for simple $VAR
      if (this.context.shell?.nounset) {
        throw new Error(`${varName}: unbound variable`)
      }
      return ''
    })

    // Restore escaped variables
    for (let i = 0; i < escapedVars.length; i++) {
      result = result.replace(`__ESCAPED_VAR_${i}__`, escapedVars[i])
    }

    return result
  }

  /**
   * Handles parameter expansion: ${VAR:-default}, ${VAR:+alt}, ${VAR:?error}
   */
  private expandParameter(content: string): string {
    // Length form: ${#VAR}
    if (content.startsWith('#')) {
      const varName = content.slice(1)
      const value = (varName in this.context.environment) ? this.context.environment[varName] : process.env[varName]
      const len = (value ?? '').length
      return String(len)
    }
    // Handle ${VAR:-default} - use default if unset or empty
    if (content.includes(':-')) {
      const [varName, defaultValue] = content.split(':-', 2)
      const value = (varName in this.context.environment) ? this.context.environment[varName] : process.env[varName]
      return value || defaultValue
    }

    // Handle ${VAR:+alt} - use alt if set and non-empty
    if (content.includes(':+')) {
      const [varName, altValue] = content.split(':+', 2)
      const value = (varName in this.context.environment) ? this.context.environment[varName] : process.env[varName]
      return value ? altValue : ''
    }

    // Handle ${VAR:?error} - error if unset or empty
    if (content.includes(':?')) {
      const [varName, errorMsg] = content.split(':?', 2)
      const value = (varName in this.context.environment) ? this.context.environment[varName] : process.env[varName]
      if (!value) {
        throw new Error(`${varName}: ${errorMsg || 'parameter null or not set'}`)
      }
      return value
    }

    // Handle ${VAR=default} - set and use default if unset
    if (content.includes('=')) {
      const [varName, defaultValue] = content.split('=', 2)
      let value = (varName in this.context.environment) ? this.context.environment[varName] : process.env[varName]
      if (!value) {
        value = defaultValue
        this.context.environment[varName] = value
      }
      return value
    }

    // Simple variable expansion
    if (content in this.context.environment) {
      return this.context.environment[content]
    }
    const sys = process.env[content]
    if (sys !== undefined)
      return sys
    // Enforce nounset for ${VAR} when no operator used
    if (this.context.shell?.nounset) {
      throw new Error(`${content}: unbound variable`)
    }
    return ''
  }

  /**
   * Expands command substitution: $(command) and `command`
   */
  private async expandCommandSubstitution(input: string): Promise<string> {
    // Quick short-circuit
    if (!(/\$\([^)]*\)/.test(input) || /`[^`]+`/.test(input)))
      return input
    let result = input

    // Handle nested $(...) by scanning for balanced parentheses
    const expandDollarParen = async (str: string): Promise<string> => {
      let i = 0
      while (i < str.length) {
        if (str[i] === '$' && str[i + 1] === '(') {
          // find matching ) with nesting
          let depth = 0
          let j = i + 2
          for (; j < str.length; j++) {
            const ch = str[j]
            const prev = str[j - 1]
            if (ch === '(' && prev !== '\\') {
              depth += 1
            }
            else if (ch === ')' && prev !== '\\') {
              if (depth === 0)
                break
              depth -= 1
            }
          }
          if (j >= str.length)
            break // unmatched; leave as-is
          const inner = str.slice(i + 2, j)
          const expandedInner = await expandDollarParen(inner)
          const output = await this.executeCommand(expandedInner)
          const before = str.slice(0, i)
          const after = str.slice(j + 1)
          str = `${before}${output.trim()}${after}`
          // restart scan from beginning of replaced segment
          i = before.length
          continue
        }
        i += 1
      }
      return str
    }

    result = await expandDollarParen(result)

    // Handle `command` syntax (no nesting support required here)
    const backtickRegex = /`([^`]+)`/g
    const backtickMatches = Array.from(result.matchAll(backtickRegex))
    for (const match of backtickMatches) {
      const command = match[1]
      const output = await this.executeCommand(command)
      result = result.replace(match[0], output.trim())
    }

    return result
  }

  /**
   * Expands arithmetic expressions: $((expression))
   */
  private async expandArithmetic(input: string): Promise<string> {
    // Quick short-circuit
    if (!/\$\(\(/.test(input))
      return input
    const arithmeticRegex = /\$\(\(([^)]+)\)\)/g
    return input.replace(arithmeticRegex, (match, expression) => {
      try {
        // Simple arithmetic evaluation - expand variables first
        let expr = expression
        // Replace $VAR explicitly
        expr = expr.replace(/\$([A-Z_]\w*)/gi, (_m: string, varName: string) => {
          const value = this.context.environment[varName]
          if (typeof value === 'string' && value.length > 0)
            return value
          return '0'
        })
        // Replace bare VAR identifiers not preceded by hex/octal digits or 'x'
        expr = expr.replace(/(?<![\da-fx_])([A-Z_]\w*)\b/gi, (_m: string, varName: string) => {
          const value = this.context.environment[varName]
          if (typeof value === 'string' && value.length > 0)
            return value
          return '0'
        })

        // Evaluate the expression safely with base prefixes
        const result = this.evaluateArithmetic(expr)
        return result.toString()
      }
      catch {
        return '0'
      }
    })
  }

  /**
   * Safe arithmetic evaluation
   */
  private evaluateArithmetic(expression: string): number {
    // Normalize whitespace
    const cleaned = expression.replace(/\s+/g, '')
    // Validate allowed tokens: numbers (with 0x... hex or leading-0 octal), operators and parens
    if (!/^[\da-fA-Fx+\-*/%()]+$/.test(cleaned)) {
      throw new Error('Invalid arithmetic expression')
    }

    // Tokenize numbers and operators; convert hex and octal to decimal explicitly
    const tokens: string[] = []
    let buf = ''
    for (let i = 0; i < cleaned.length; i++) {
      const ch = cleaned[i]
      if (/[0-9a-fA-Fx]/.test(ch)) {
        buf += ch
      }
      else {
        if (buf) {
          tokens.push(buf)
          buf = ''
        }
        tokens.push(ch)
      }
    }
    if (buf)
      tokens.push(buf)

    const toDec = (numTok: string): string => {
      if (/^0x[\da-fA-F]+$/.test(numTok))
        return String(Number.parseInt(numTok.slice(2), 16))
      // Leading zero implies octal (but a single 0 is zero)
      if (/^0[0-7]+$/.test(numTok))
        return String(Number.parseInt(numTok, 8))
      if (/^\d+$/.test(numTok))
        return numTok
      // Anything else is invalid
      throw new Error('Invalid arithmetic literal')
    }

    const normalized = tokens.map((t) => {
      if (/^[\da-fA-Fx]+$/.test(t))
        return toDec(t)
      if (/^[+\-*/%()]$/.test(t))
        return t
      // Unexpected token
      throw new Error('Invalid arithmetic token')
    }).join('')

    // Arithmetic cache lookup
    const cached = ExpansionUtils.getArithmeticCached(normalized)
    if (cached !== undefined)
      return cached

    try {
      // eslint-disable-next-line no-new-func
      const value = new Function(`return (${normalized})`)()
      ExpansionUtils.setArithmeticCached(normalized, value)
      return value
    }
    catch {
      return 0
    }
  }

  /**
   * Expands brace expansion: {a,b,c}, {1..10}, {a..z}
   */
  private expandBraces(input: string): string {
    // Quick short-circuit
    if (!/\{[^{}]+\}/.test(input))
      return input
    let result = input

    // Handle brace expansion with prefix/suffix support
    const braceRegex = /([^{}\s,]*)\{([^{}]+)\}([^{}\s,]*)/g
    result = result.replace(braceRegex, (match, prefix, content, suffix) => {
      // Handle range expansion {1..10}, {a..z}
      if (content.includes('..')) {
        const [start, end] = content.split('..', 2)
        const expansion = this.expandRange(start.trim(), end.trim())
        return expansion.map(item => `${prefix}${item}${suffix}`).join(' ')
      }

      // Handle comma expansion {a,b,c}
      if (content.includes(',')) {
        const items = content.split(',').map((item: string) => item.trim())
        return items.map((item: string) => `${prefix}${item}${suffix}`).join(' ')
      }

      return match
    })

    return result
  }

  /**
   * Expands ranges like {1..10} or {a..z}
   */
  private expandRange(start: string, end: string): string[] {
    const startNum = Number.parseInt(start, 10)
    const endNum = Number.parseInt(end, 10)

    // Numeric range
    if (!Number.isNaN(startNum) && !Number.isNaN(endNum)) {
      const result: string[] = []
      const step = startNum <= endNum ? 1 : -1
      // Zero-padding width if either endpoint has leading zeros and same width
      const width = (start.startsWith('0') || end.startsWith('0'))
        ? Math.max(start.length, end.length)
        : 0
      for (let i = startNum; step > 0 ? i <= endNum : i >= endNum; i += step) {
        const s = i.toString()
        result.push(width > 0 ? s.padStart(width, '0') : s)
      }
      return result
    }

    // Character range
    if (start.length === 1 && end.length === 1) {
      const startCode = start.charCodeAt(0)
      const endCode = end.charCodeAt(0)
      const result: string[] = []
      const step = startCode <= endCode ? 1 : -1
      for (let i = startCode; step > 0 ? i <= endCode : i >= endCode; i += step) {
        result.push(String.fromCharCode(i))
      }
      return result
    }

    return [start, end]
  }

  /**
   * Handles process substitution: <(command), >(command)
   */
  private async expandProcessSubstitution(input: string): Promise<string> {
    // Quick short-circuit
    if (!(/<\([^)]*\)/.test(input) || />\([^)]*\)/.test(input)))
      return input
    let result = input

    // Handle <(command) - input process substitution
    const inputSubstRegex = /<\(([^)]+)\)/g
    const inputMatches = Array.from(result.matchAll(inputSubstRegex))
    for (const match of inputMatches) {
      const command = match[1]
      const fifo = await this.createInputProcessSubstitution(command)
      result = result.replace(match[0], fifo)
    }

    // Handle >(command) - output process substitution
    const outputSubstRegex = />\(([^)]+)\)/g
    const outputMatches = Array.from(result.matchAll(outputSubstRegex))
    for (const match of outputMatches) {
      const command = match[1]
      const fifo = await this.createOutputProcessSubstitution(command)
      result = result.replace(match[0], fifo)
    }

    return result
  }

  /**
   * Creates a FIFO for input process substitution
   */
  private async createInputProcessSubstitution(command: string): Promise<string> {
    // For now, execute the command and return a temporary file path
    // In a full implementation, this would create a named pipe
    const output = await this.executeCommand(command)
    const tempFile = `/tmp/krusty_proc_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`

    // Write output to temp file (simplified implementation)
    const fs = await import('node:fs/promises')
    await fs.writeFile(tempFile, output)

    return tempFile
  }

  /**
   * Creates a FIFO for output process substitution
   */
  private async createOutputProcessSubstitution(_command: string): Promise<string> {
    // For now, return a temporary file path that the command can write to
    const tempFile = `/tmp/krusty_proc_out_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`

    // In a full implementation, this would set up a named pipe
    // and spawn the command to read from it
    return tempFile
  }

  /**
   * Executes a command and returns its output
   */
  async executeCommand(command: string): Promise<string> {
    const mode = this.context.substitutionMode ?? 'sandbox'
    if (mode === 'sandbox') {
      // Basic, conservative sandbox: allow only simple commands without operators or redirects
      const allow = new Set((this.context.sandboxAllow && this.context.sandboxAllow.length > 0)
        ? this.context.sandboxAllow
        : ['echo', 'printf'])

      const trimmed = command.trim()
      // Disallow obvious shell metacharacters to avoid composition
      if (/[;&|><`$\\]/.test(trimmed))
        throw new Error('Command substitution blocked by sandbox: contains disallowed characters')

      // Extract command name (first token)
      const firstSpace = trimmed.indexOf(' ')
      const cmd = (firstSpace === -1 ? trimmed : trimmed.slice(0, firstSpace)).trim()
      if (!allow.has(cmd))
        throw new Error(`Command substitution blocked by sandbox: '${cmd}' not allowed`)

      // Execute allowed commands internally without invoking a shell
      if (cmd === 'echo') {
        const rest = firstSpace === -1 ? '' : trimmed.slice(firstSpace + 1)
        // A minimal echo that just returns the rest plus newline
        return `${rest}\n`
      }
      if (cmd === 'printf') {
        const rest = firstSpace === -1 ? '' : trimmed.slice(firstSpace + 1)
        // Very minimal printf that returns the rest as-is (no format parsing here)
        return rest
      }

      // For other allowlisted commands, spawn directly without a shell
      const rest = firstSpace === -1 ? '' : trimmed.slice(firstSpace + 1)
      const args = rest.length ? ExpansionUtils.splitArguments(rest) : []
      const resolved = await ExpansionUtils.resolveExecutable(cmd, this.context.environment)
      return await new Promise<string>((resolve, reject) => {
        const child = spawn(resolved ?? cmd, args, {
          cwd: this.context.cwd,
          env: this.context.environment,
          stdio: ['ignore', 'pipe', 'pipe'],
          shell: false,
        })

        let stdout = ''
        let stderr = ''
        child.stdout?.on('data', (d) => {
          stdout += d.toString()
        })
        child.stderr?.on('data', (d) => {
          stderr += d.toString()
        })
        child.on('close', (code) => {
          if (code === 0) {
            resolve(stdout)
          }
          else {
            reject(new Error(`Command failed with exit code ${code}: ${stderr}`))
          }
        })
        child.on('error', reject)
      })

      // Should not reach here because of allowlist check
      throw new Error('Command substitution blocked by sandbox')
    }

    // Full mode: delegate to system shell
    return new Promise((resolve, reject) => {
      const shell = process.platform === 'win32' ? 'cmd' : '/bin/sh'
      const args = process.platform === 'win32' ? ['/c', command] : ['-c', command]

      const child = spawn(shell, args, {
        cwd: this.context.cwd,
        env: this.context.environment,
        stdio: ['pipe', 'pipe', 'pipe'],
      })

      let stdout = ''
      let stderr = ''

      child.stdout?.on('data', (data) => {
        stdout += data.toString()
      })

      child.stderr?.on('data', (data) => {
        stderr += data.toString()
      })

      child.on('close', (code) => {
        if (code === 0) {
          resolve(stdout)
        }
        else {
          reject(new Error(`Command failed with exit code ${code}: ${stderr}`))
        }
      })

      child.on('error', (error) => {
        reject(error)
      })
    })
  }
}

/**
 * Utility functions for expansion
 */
export class ExpansionUtils {
  // Small LRU cache for splitArguments results
  private static argCache = new Map<string, string[]>()
  private static ARG_CACHE_LIMIT = 200
  // Memoized PATH resolution caches
  private static pathCacheKey = ''
  private static pathCache: string[] = []
  private static execCache = new Map<string, string | null>()
  private static EXEC_CACHE_LIMIT = 500
  // Arithmetic evaluation cache (post-normalization)
  private static arithmeticCache = new Map<string, number>()
  private static ARITH_CACHE_LIMIT = 500

  /** Configure cache limits at runtime */
  static setCacheLimits(limits: Partial<{ arg: number, exec: number, arithmetic: number }>): void {
    if (limits.arg && limits.arg > 0)
      this.ARG_CACHE_LIMIT = limits.arg
    if (limits.exec && limits.exec > 0)
      this.EXEC_CACHE_LIMIT = limits.exec
    if (limits.arithmetic && limits.arithmetic > 0)
      this.ARITH_CACHE_LIMIT = limits.arithmetic
  }

  /** Clear all caches (arg, exec, arithmetic). PATH split cache retained until PATH changes. */
  static clearCaches(): void {
    this.argCache.clear()
    this.execCache.clear()
    this.arithmeticCache.clear()
  }

  /**
   * Checks if a string contains expansion patterns
   */
  static hasExpansion(input: string): boolean {
    return /[$`{]/.test(input)
  }

  /**
   * Escapes expansion characters
   */
  static escapeExpansion(input: string): string {
    return input.replace(/[$`{]/g, '\\$&')
  }

  /**
   * Splits a string by whitespace, respecting quotes and expansions
   */
  static splitArguments(input: string): string[] {
    // Cache hit
    const cached = this.argCache.get(input)
    if (cached)
      return cached

    const args: string[] = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false
    let braceDepth = 0

    for (let i = 0; i < input.length; i++) {
      const char = input[i]

      if (escaped) {
        current += char
        escaped = false
        continue
      }

      if (char === '\\') {
        escaped = true
        current += char
        continue
      }

      if (!inQuotes && (char === '"' || char === '\'')) {
        inQuotes = true
        quoteChar = char
        current += char
        continue
      }

      if (inQuotes && char === quoteChar) {
        inQuotes = false
        quoteChar = ''
        current += char
        continue
      }

      if (!inQuotes && char === '{') {
        braceDepth++
        current += char
        continue
      }

      if (!inQuotes && char === '}') {
        braceDepth--
        current += char
        continue
      }

      if (!inQuotes && braceDepth === 0 && /\s/.test(char)) {
        if (current) {
          args.push(current)
          current = ''
        }
        continue
      }

      current += char
    }

    if (current) {
      args.push(current)
    }

    // Insert into LRU cache
    this.argCache.set(input, args)
    if (this.argCache.size > this.ARG_CACHE_LIMIT) {
      // delete oldest
      const firstKey = this.argCache.keys().next().value as string
      this.argCache.delete(firstKey)
    }
    return args
  }

  /**
   * Resolve an executable via PATH with memoization. Returns absolute path or null if not found.
   */
  static async resolveExecutable(cmd: string, env: Record<string, string>): Promise<string | null> {
    // Windows will resolve .exe/.cmd; we still can memoize by name only
    if (this.execCache.has(cmd))
      return this.execCache.get(cmd) ?? null

    const PATH = env.PATH ?? process.env.PATH ?? ''
    if (PATH !== this.pathCacheKey) {
      this.pathCacheKey = PATH
      this.pathCache = PATH.split(process.platform === 'win32' ? ';' : ':').filter(Boolean)
      this.execCache.clear()
    }

    const fs = await import('node:fs/promises')
    const path = await import('node:path')
    const access = async (p: string) => {
      try {
        await fs.access(p)
        return true
      }
      catch {
        return false
      }
    }

    // If cmd includes a path separator, check it directly
    if (cmd.includes('/') || (process.platform === 'win32' && cmd.includes('\\'))) {
      const abs = path.isAbsolute(cmd) ? cmd : path.resolve(cmd)
      const ok = await access(abs)
      this.execCache.set(cmd, ok ? abs : null)
      return ok ? abs : null
    }

    for (const dir of this.pathCache) {
      const candidate = path.join(dir, cmd)
      if (await access(candidate)) {
        this.execCache.set(cmd, candidate)
        if (this.execCache.size > this.EXEC_CACHE_LIMIT) {
          const k = this.execCache.keys().next().value as string
          this.execCache.delete(k)
        }
        return candidate
      }
      // Windows PATHEXT support (basic)
      if (process.platform === 'win32') {
        const pathext = (env.PATHEXT ?? process.env.PATHEXT ?? '.EXE;.CMD;.BAT').split(';')
        for (const ext of pathext) {
          const cand = candidate + ext
          if (await access(cand)) {
            this.execCache.set(cmd, cand)
            if (this.execCache.size > this.EXEC_CACHE_LIMIT) {
              const k = this.execCache.keys().next().value as string
              this.execCache.delete(k)
            }
            return cand
          }
        }
      }
    }
    this.execCache.set(cmd, null)
    if (this.execCache.size > this.EXEC_CACHE_LIMIT) {
      const k = this.execCache.keys().next().value as string
      this.execCache.delete(k)
    }
    return null
  }

  /** Get arithmetic cache entry for normalized expression */
  static getArithmeticCached(norm: string): number | undefined {
    return this.arithmeticCache.get(norm)
  }

  /** Set arithmetic cache entry with LRU eviction */
  static setArithmeticCached(norm: string, value: number): void {
    this.arithmeticCache.set(norm, value)
    if (this.arithmeticCache.size > this.ARITH_CACHE_LIMIT) {
      const k = this.arithmeticCache.keys().next().value as string
      this.arithmeticCache.delete(k)
    }
  }
}
