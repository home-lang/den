import type { Command, ParsedCommand, Redirection } from './types'
import { ExpansionEngine, ExpansionUtils } from './utils/expansion'
import { RedirectionHandler } from './utils/redirection'

export class ParseError extends Error {
  index?: number
  constructor(message: string, index?: number) {
    super(message)
    this.name = 'ParseError'
    this.index = index
  }
}

export class CommandParser {
  async parse(input: string, shell?: any): Promise<ParsedCommand> {
    const trimmed = input.trim()
    if (!trimmed) {
      return { commands: [] }
    }

    // Basic syntax validation: detect unterminated quotes early
    if (this.hasUnterminatedQuotes(trimmed)) {
      // Caret at end of input for unterminated quotes
      throw new ParseError('unterminated quote', trimmed.length)
    }

    // For parser.parse(), only split pipelines within a single command segment.
    // Higher-level chaining (;, &&, ||) is handled by the shell using
    // splitByOperatorsDetailed() to retain operator semantics.
    const segments = this.splitByPipes(trimmed)
    const commands: Command[] = []
    const redirections: Redirection[] = []

    for (const segment of segments) {
      const { command, segmentRedirections } = await this.parseSegment(segment, shell)
      if (command) {
        commands.push(command)
        if (segmentRedirections) {
          redirections.push(...segmentRedirections)
        }
      }
    }

    // Convert redirections to the expected format
    const redirects = this.convertRedirectionsToFormat(redirections)

    return {
      commands,
      redirections: redirections.length > 0 ? redirections : undefined,
      redirects,
    }
  }

  private convertRedirectionsToFormat(redirections: Redirection[]) {
    if (redirections.length === 0)
      return undefined

    const redirects: { stdin?: string, stdout?: string, stderr?: string } = {}

    for (const redirection of redirections) {
      if (redirection.type === 'file') {
        switch (redirection.direction) {
          case 'input':
            redirects.stdin = redirection.target
            break
          case 'output':
          case 'append':
            redirects.stdout = redirection.target
            break
          case 'error':
          case 'error-append':
            redirects.stderr = redirection.target
            break
          case 'both':
            redirects.stdout = redirection.target
            redirects.stderr = redirection.target
            break
        }
      }
    }

    return Object.keys(redirects).length > 0 ? redirects : undefined
  }

  // Backwards-compatible helper used by older callers; returns just the segments.
  public splitByOperators(input: string): string[] {
    return this.splitByOperatorsDetailed(input).map(s => s.segment)
  }

  // Detailed operator-aware splitter: returns segments with the operator
  // that follows each segment (except the last). Handles quotes, escapes,
  // and basic here-doc detection ("<<DELIM ... DELIM"), avoiding splits inside.
  public splitByOperatorsDetailed(input: string): Array<{ segment: string, op?: ';' | '&&' | '||' }> {
    const out: Array<{ segment: string, op?: ';' | '&&' | '||' }> = []
    let buf = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false
    let i = 0
    // Here-doc lightweight tracking: when encountering <<DELIM, we avoid
    // operator splitting until the end of input (single-line safety). This
    // prevents accidental splits on operators embedded in here-doc content.
    let inHereDoc = false
    // Track simple if...fi blocks to avoid splitting operators inside script constructs.
    // This is token-aware and ignores substrings like 'printf'. Supports basic nesting.
    let ifDepth = 0
    let loopDepth = 0 // do/done
    let inLoopHeader = false // after for/while/until and before matching 'do'
    let caseDepth = 0 // case/esac
    let braceDepth = 0 // { ... }

    const push = (op?: ';' | '&&' | '||') => {
      const t = buf.trim()
      if (t)
        out.push({ segment: t, op })
      buf = ''
    }

    while (i < input.length) {
      const ch = input[i]
      const next = input[i + 1]

      if (escaped) {
        buf += ch
        escaped = false
        i += 1
        continue
      }

      if (ch === '\\') {
        escaped = true
        // Preserve the backslash for downstream tokenization
        buf += ch
        i += 1
        continue
      }

      // Quote handling
      if (!inQuotes && (ch === '"' || ch === '\'')) {
        inQuotes = true
        quoteChar = ch
        buf += ch
        i += 1
        continue
      }
      if (inQuotes && ch === quoteChar) {
        inQuotes = false
        quoteChar = ''
        buf += ch
        i += 1
        continue
      }

      // Here-doc start (only when not quoted)
      if (!inQuotes && !inHereDoc && ch === '<' && next === '<') {
        inHereDoc = true
        buf += '<<'
        i += 2
        // Consume an optional delimiter token (best-effort)
        while (i < input.length && /\s/.test(input[i])) {
          buf += input[i]
          i += 1
        }
        while (i < input.length && /\S/.test(input[i])) {
          buf += input[i]
          i += 1
        }
        continue
      }

      // Detect script tokens when not in quotes or here-doc to manage depths
      if (!inQuotes && !inHereDoc) {
        // Token-aware 'if' start: previous is start or separator, next is separator
        if (ch === 'i' && input.slice(i, i + 2) === 'if') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 2] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep) {
            ifDepth += 1
          }
        }
        // Token-aware 'fi' end
        if (ch === 'f' && input.slice(i, i + 2) === 'fi') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 2] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep && ifDepth > 0) {
            ifDepth -= 1
          }
        }

        // Token-aware loop headers: for/while/until ... do ... done
        if (ch === 'f' && input.slice(i, i + 3) === 'for') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 3] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep)
            inLoopHeader = true
        }
        if (ch === 'w' && input.slice(i, i + 5) === 'while') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 5] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep)
            inLoopHeader = true
        }
        if (ch === 'u' && input.slice(i, i + 5) === 'until') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 5] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep)
            inLoopHeader = true
        }
        if (ch === 'd' && input.slice(i, i + 2) === 'do') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 2] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep) {
            if (inLoopHeader) {
              loopDepth += 1
              inLoopHeader = false
            }
          }
        }
        if (ch === 'd' && input.slice(i, i + 4) === 'done') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 4] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep && loopDepth > 0)
            loopDepth -= 1
        }

        // Token-aware case/esac
        if (ch === 'c' && input.slice(i, i + 4) === 'case') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 4] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep)
            caseDepth += 1
        }
        if (ch === 'e' && input.slice(i, i + 4) === 'esac') {
          const prev = i === 0 ? '' : input[i - 1]
          const nextCh = input[i + 4] || ''
          const prevSep = i === 0 || /[\s;|&(){}]/.test(prev)
          const nextSep = nextCh === '' || /[\s;|&(){}]/.test(nextCh)
          if (prevSep && nextSep && caseDepth > 0)
            caseDepth -= 1
        }

        // Brace tracking for function bodies and blocks
        if (ch === '{')
          braceDepth += 1
        if (ch === '}')
          braceDepth = Math.max(0, braceDepth - 1)

        // Detect operators when not in quotes/here-doc and not inside any script construct
        if (ifDepth === 0 && loopDepth === 0 && caseDepth === 0 && braceDepth === 0 && !inLoopHeader) {
          // &&, || have priority over ;
          if (ch === '&' && next === '&') {
            push('&&')
            i += 2
            continue
          }
          if (ch === '|' && next === '|') {
            push('||')
            i += 2
            continue
          }
          if (ch === ';') {
            push(';')
            i += 1
            continue
          }
          // Treat newline as a command separator similar to ';' when not in quotes or here-doc
          if (ch === '\n') {
            push(';')
            i += 1
            continue
          }
        }
      }

      buf += ch
      i += 1
    }

    if (buf.trim())
      out.push({ segment: buf.trim() })

    return out
  }

  private splitByPipes(input: string): string[] {
    const segments: string[] = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false

    for (let i = 0; i < input.length; i++) {
      const char = input[i]
      const nextChar = input[i + 1]

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

      if (!inQuotes && char === '|' && nextChar !== '|') {
        segments.push(current.trim())
        current = ''
        continue
      }

      current += char
    }

    if (current.trim()) {
      segments.push(current.trim())
    }

    return segments.filter(s => s.length > 0)
  }

  /**
   * Tokenizes a string into an array of arguments, handling quotes and escape sequences
   * @param input The input string to tokenize
   * @returns An array of tokens
   */
  public tokenize(input: string): string[] {
    const tokens: string[] = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false

    for (let i = 0; i < input.length; i++) {
      const char = input[i]

      if (escaped) {
        current += `\\${char}` // Keep the backslash for escaped characters
        escaped = false
        continue
      }

      if (char === '\\') {
        escaped = true
        continue
      }

      if (!inQuotes && (char === '"' || char === '\'')) {
        inQuotes = true
        quoteChar = char
        current += char // Keep the opening quote
        continue
      }

      if (inQuotes && char === quoteChar) {
        inQuotes = false
        current += char // Keep the closing quote
        continue
      }

      if (!inQuotes && /\s/.test(char)) {
        if (current) {
          tokens.push(current)
          current = ''
        }
        continue
      }

      current += char
    }

    // If line ends with a lonely backslash, keep it literal
    if (escaped) {
      current += '\\'
      escaped = false
    }

    if (current) {
      tokens.push(current)
    }

    return tokens
  }

  /**
   * Detects if the input contains unterminated quotes
   */
  private hasUnterminatedQuotes(input: string): boolean {
    let inQuotes = false
    let quoteChar = ''
    let escaped = false

    for (let i = 0; i < input.length; i++) {
      const char = input[i]

      if (escaped) {
        escaped = false
        continue
      }

      if (char === '\\') {
        escaped = true
        continue
      }

      if (!inQuotes && (char === '"' || char === '\'')) {
        inQuotes = true
        quoteChar = char
        continue
      }

      if (inQuotes && char === quoteChar) {
        inQuotes = false
        quoteChar = ''
        continue
      }
    }

    return inQuotes
  }

  private async parseSegment(segment: string, shell?: any): Promise<{
    command: Command | null
    segmentRedirections?: Redirection[]
  }> {
    // Check for background process
    const isBackground = segment.endsWith('&') && !this.isInQuotes(segment, segment.length - 1)
    if (isBackground) {
      segment = segment.slice(0, -1).trim()
    }

    // Extract redirections
    const { cleanCommand, redirections } = RedirectionHandler.parseRedirections(segment)
    let cleanSegment = cleanCommand

    // Apply expansions to the clean command and redirection targets
    if (shell) {
      const expansionEngine = new ExpansionEngine({
        shell,
        cwd: shell.cwd,
        environment: shell.environment,
      })

      if (ExpansionUtils.hasExpansion(cleanSegment)) {
        cleanSegment = await expansionEngine.expand(cleanSegment)
      }

      // Expand variables in redirection targets
      for (const redirection of redirections) {
        if (ExpansionUtils.hasExpansion(redirection.target)) {
          redirection.target = await expansionEngine.expand(redirection.target)
        }
      }
    }

    // Parse command and arguments
    const tokens = this.tokenize(cleanSegment)
    if (tokens.length === 0) {
      return { command: null }
    }

    const [name, ...rawArgs] = tokens
    // For commands with expansions, preserve the structure after expansion
    // For regular commands, process arguments to remove quotes
    const args = rawArgs.map((arg) => {
      // If the original segment had expansions and this arg contains quotes/escapes, preserve them
      if (segment !== cleanSegment && (arg.includes('"') || arg.includes('\'') || arg.includes('\\'))) {
        return arg
      }
      // Special case: if the original segment had escaped variables, preserve them
      if (segment.includes('\\$') && arg.includes('\\')) {
        return arg
      }
      // Special case: preserve quotes for alias command to handle quote preservation correctly
      if (tokens[0] === 'alias') {
        return arg
      }
      return this.processArgument(arg)
    })

    const command: Command = {
      name: this.processArgument(name),
      args,
      raw: segment,
      background: isBackground,
      // Preserve original arguments for alias expansion
      originalArgs: rawArgs,
    }

    return { command, segmentRedirections: redirections.length > 0 ? redirections : undefined }
  }

  /**
   * Processes an argument by removing quotes and handling escape sequences
   * @param arg The argument to process
   * @returns The processed argument
   */
  private processArgument(arg: string): string {
    if (!arg)
      return arg

    // Handle escaped characters first
    const processed = arg.replace(/\\(.)/g, '$1')

    // For quoted strings, only remove quotes if they're not part of the content
    // This preserves quotes that should be part of the output
    if ((processed.startsWith('"') && processed.endsWith('"')) || (processed.startsWith('\'') && processed.endsWith('\''))) {
      // Check if this is a simple quoted string or if quotes should be preserved
      const inner = processed.slice(1, -1)
      // If the inner content doesn't contain the same quote character, remove outer quotes
      const quoteChar = processed[0]
      if (!inner.includes(quoteChar)) {
        return inner
      }
    }

    return processed
  }

  private isInQuotes(input: string, position: number): boolean {
    let inQuotes = false
    let quoteChar = ''
    let escaped = false

    for (let i = 0; i < position; i++) {
      const char = input[i]

      if (escaped) {
        escaped = false
        continue
      }

      if (char === '\\') {
        escaped = true
        continue
      }

      if (!inQuotes && (char === '"' || char === '\'')) {
        inQuotes = true
        quoteChar = char
        continue
      }

      if (inQuotes && char === quoteChar) {
        inQuotes = false
        quoteChar = ''
        continue
      }
    }

    return inQuotes
  }
}
