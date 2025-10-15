import type { ChildProcess } from 'node:child_process'
import type { Readable, Writable } from 'node:stream'
import type { Redirection } from '../types'

import { createReadStream, createWriteStream, existsSync } from 'node:fs'

export interface RedirectionConfig {
  stdin?: string | Readable
  stdout?: string | Writable | 'append'
  stderr?: string | Writable | 'append'
  stdoutAppend?: boolean
  stderrAppend?: boolean
  combineStderr?: boolean // For &> operator
  hereDoc?: string
  hereString?: string
}

/**
 * Handles all forms of shell redirection including:
 * - Basic redirection: >, >>, <, 2>, 2>>
 * - Combined redirection: &>, &>>
 * - Here documents: <<EOF, <<-EOF
 * - Here strings: <<<string
 * - File descriptor redirection: 3>, 4<, 2>&1
 */
export class RedirectionHandler {
  /**
   * Remove surrounding single or double quotes from a token, if present
   */
  private static dequote(token: string): string {
    if (!token)
      return token
    if ((token.startsWith('"') && token.endsWith('"')) || (token.startsWith('\'') && token.endsWith('\'')))
      return token.slice(1, -1)
    return token
  }

  /**
   * Parses redirection operators from a command string
   */
  static parseRedirections(command: string): {
    cleanCommand: string
    redirections: Redirection[]
  } {
    const redirections: Redirection[] = []
    let cleanCommand = command

    // Precompute quoted spans to avoid parsing redirection tokens inside quotes
    // We support both single and double quotes; simple escape handling for double quotes (\")
    const quotedSpans: Array<{ start: number, end: number }> = []
    {
      let i = 0
      let inSingle = false
      let inDouble = false
      let spanStart = -1
      while (i < command.length) {
        const ch = command[i]
        if (!inDouble && ch === '\'') {
          if (!inSingle) {
            inSingle = true
            spanStart = i
          }
          else {
            inSingle = false
            quotedSpans.push({ start: spanStart, end: i })
          }
          i += 1
          continue
        }
        if (!inSingle && ch === '"') {
          if (!inDouble) {
            inDouble = true
            spanStart = i
          }
          else {
            inDouble = false
            quotedSpans.push({ start: spanStart, end: i })
          }
          i += 1
          continue
        }
        if (inDouble && ch === '\\' && i + 1 < command.length && command[i + 1] === '"') {
          // skip escaped quote within double quotes
          i += 2
          continue
        }
        i += 1
      }
    }

    const isInQuotedSpan = (index: number): boolean => quotedSpans.some(s => index >= s.start && index <= s.end)

    // Parse in order of precedence to avoid conflicts and choose the stronger match
    // Precedence (high -> low): here-doc, here-string, both, fd-dup, standard
    const patterns = [
      { regex: /\s+<<(-)?\s*([A-Z_]\w*)\s*$/gi, type: 'here-doc' },
      { regex: /\s+<<<\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)\s*$/g, type: 'here-string' },
      { regex: /(?:\s+|^)(&>|&>>)\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/g, type: 'both' },
      { regex: /(?:\s+|^)(\d+)>\s*&(-|\d+)\b/g, type: 'fd-dup' },
      { regex: /(?:\s+|^)(\d*>>|\d*>|<)\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/g, type: 'standard' },
    ] as const

    // Collect matches against the original command with absolute indices
    const collected: Array<{ start: number, end: number, match: RegExpMatchArray, type: string }> = []
    const overlaps = (a: { start: number, end: number }, b: { start: number, end: number }) => !(a.end <= b.start || b.end <= a.start)
    for (const pattern of patterns) {
      const re = new RegExp(pattern.regex)
      for (let m = re.exec(command); m !== null; m = re.exec(command)) {
        const idx = m.index
        if (idx >= 0 && isInQuotedSpan(idx))
          continue
        const candidate = { start: idx, end: idx + m[0].length, match: m as any, type: pattern.type }
        // Skip if this span overlaps any already accepted span (higher precedence)
        if (collected.some(ex => overlaps(ex, candidate)))
          continue
        collected.push(candidate)
      }
    }

    let mutable = cleanCommand
    if (collected.length > 0) {
      // Build redirections in ascending order
      const ascending = collected.slice().sort((a, b) => a.start - b.start)
      for (const item of ascending) {
        const redirection = this.parseRedirectionMatch(item.match as any, item.type)
        if (redirection)
          redirections.push(redirection)
      }
      // Replace spans in descending order with single spaces to avoid index shifts
      const descending = collected.slice().sort((a, b) => b.start - a.start)
      for (const item of descending) {
        const pre = mutable.slice(0, item.start)
        const post = mutable.slice(item.end)
        mutable = `${pre} ${post}`
      }
      cleanCommand = mutable
    }
    else {
      // Fallback: only run naive pass when there are no quotes at all.
      // This prevents operators inside quoted scripts (e.g., sh -c 'cat > f')
      // from being misinterpreted as stage-level redirections.
      const hasAnyQuotes = /['"]/.test(command)
      if (!hasAnyQuotes) {
        for (const pattern of patterns) {
          const matches = Array.from(command.matchAll(pattern.regex))
          for (const match of matches) {
            const redirection = this.parseRedirectionMatch(match, pattern.type)
            if (redirection) {
              redirections.push(redirection)
              cleanCommand = cleanCommand.replace(match[0], ' ')
            }
          }
        }
        cleanCommand = cleanCommand.trim()
      }
    }

    return {
      cleanCommand: cleanCommand.trim(),
      redirections,
    }
  }

  private static parseRedirectionMatch(
    match: RegExpMatchArray,
    patternType: string,
  ): Redirection | null {
    switch (patternType) {
      case 'here-doc':
        return {
          type: 'here-doc',
          direction: 'input',
          // Store delimiter; prefix with '-' if indentation stripping requested so downstream can detect
          target: `${match[1] ? '-' : ''}${match[2]}`,
        }

      case 'here-string':
        return {
          type: 'here-string',
          direction: 'input',
          target: match[1],
        }

      case 'both': {
        const op = match[1]
        // Normalize: &> file -> both, &>> file -> append
        const isAppend = op.includes('>>')
        const target = this.dequote(match[2])
        return {
          type: 'file',
          direction: 'both',
          // For append on both, mark target and interpret later
          target: isAppend ? `APPEND::${target}` : target,
        }
      }

      case 'fd-dup': {
        const fd = Number.parseInt(match[1], 10)
        const target = match[2] === '-' ? '&-' : `&${match[2]}`
        return {
          type: 'fd',
          direction: 'output',
          target,
          fd,
        }
      }

      case 'standard': {
        const op = match[1]
        const file = this.dequote(match[2])

        // Detect file descriptor-specific standard ops like 2>, 2>>
        const fdMatch = op.match(/^(\d*)(>>?|<)$/)
        if (fdMatch) {
          const fdStr = fdMatch[1]
          const sym = fdMatch[2]
          if (sym === '<') {
            return { type: 'file', direction: 'input', target: file }
          }
          if (sym === '>' || sym === '>>') {
            if (fdStr === '2') {
              return { type: 'file', direction: sym === '>>' ? 'error-append' : 'error', target: file }
            }
            // stdout or generic > / >>
            return { type: 'file', direction: sym === '>>' ? 'append' : 'output', target: file }
          }
        }
        break
      }
    }

    return null
  }

  /**
   * Applies redirections to a child process
   */
  static async applyRedirections(
    process: ChildProcess,
    redirections: Redirection[],
    cwd: string,
  ): Promise<void> {
    for (const redirection of redirections) {
      await this.applyRedirection(process, redirection, cwd)
    }
  }

  private static async applyRedirection(
    process: ChildProcess,
    redirection: Redirection,
    cwd: string,
  ): Promise<void> {
    switch (redirection.type) {
      case 'file':
        await this.applyFileRedirection(process, redirection, cwd)
        break

      case 'here-doc':
        await this.applyHereDocRedirection(process, redirection)
        break

      case 'here-string':
        await this.applyHereStringRedirection(process, redirection)
        break

      case 'fd':
        await this.applyFdRedirection(process, redirection)
        break
    }
  }

  private static async applyFileRedirection(
    process: ChildProcess,
    redirection: Redirection,
    cwd: string,
  ): Promise<void> {
    // Normalize APPEND:: marker off the raw target before resolving path
    const rawTarget = redirection.target.startsWith('APPEND::')
      ? redirection.target.replace(/^APPEND::/, '')
      : redirection.target
    const filePath = rawTarget.startsWith('/')
      ? rawTarget
      : `${cwd}/${rawTarget}`

    switch (redirection.direction) {
      case 'input': {
        if (existsSync(filePath)) {
          const stream = createReadStream(filePath)
          if (process.stdin && process.stdin.writable) {
            try {
              stream.on('error', () => {
                try {
                  const sin: any = process.stdin as any
                  if (sin && typeof sin.end === 'function')
                    sin.end()
                }
                catch {}
              })

              // Handle pipe errors gracefully
              ;(process.stdin as any)?.on?.('error', (err: any) => {
                if (err && (err.code === 'EPIPE' || err.code === 'ERR_STREAM_WRITE_AFTER_END')) {
                  // ignore benign pipe errors
                }
              })

              // End stdin after piping to prevent hanging
              stream.on('end', () => {
                try {
                  const sin: any = process.stdin as any
                  if (sin && typeof sin.end === 'function')
                    sin.end()
                }
                catch {}
              })

              stream.pipe(process.stdin as any, { end: false })
            }
            catch {}
          }
          else {
            // No writable stdin; consume stream to avoid hanging file descriptor
            stream.resume()
          }
        }
        else {
          // Mirror POSIX shells: report error and close stdin to avoid hanging
          try {
            const errMsg = `krusty: ${filePath}: No such file or directory\n`
            if ((process as any).stderr && typeof (process as any).stderr.write === 'function') {
              ;(process as any).stderr.write(errMsg)
            }
          }
          catch {}
          try {
            if (process.stdin && typeof (process.stdin as any).end === 'function') {
              ;(process.stdin as any).end()
            }
          }
          catch {}
        }
        break
      }

      case 'output': {
        const outStream = createWriteStream(filePath)
        if (process.stdout) {
          process.stdout.pipe(outStream)
        }
        break
      }

      case 'append': {
        const appendStream = createWriteStream(filePath, { flags: 'a' })
        if (process.stdout) {
          process.stdout.pipe(appendStream)
        }
        break
      }

      case 'error': {
        const errStream = createWriteStream(filePath, { flags: 'w' })
        if (process.stderr) {
          process.stderr.pipe(errStream)
        }
        break
      }

      case 'error-append': {
        const errAppendStream = createWriteStream(filePath, { flags: 'a' })
        if (process.stderr) {
          process.stderr.pipe(errAppendStream)
        }
        break
      }

      case 'both': {
        // Support APPEND:: marker for combined append (&>>)
        const isAppendBoth = redirection.target.startsWith('APPEND::')
        const bothStream = createWriteStream(filePath, { flags: isAppendBoth ? 'a' : 'w' })
        if (process.stdout) {
          process.stdout.pipe(bothStream)
        }
        if (process.stderr) {
          process.stderr.pipe(bothStream)
        }
        break
      }
    }
  }

  private static async applyHereDocRedirection(
    process: ChildProcess,
    redirection: Redirection,
  ): Promise<void> {
    // Here documents need to be handled during parsing stage to provide content.
    // We treat redirection.target as the already-parsed content here.
    const content = redirection.target
    if (process.stdin) {
      process.stdin.write(content)
      process.stdin.end()
    }
  }

  private static async applyHereStringRedirection(
    process: ChildProcess,
    redirection: Redirection,
  ): Promise<void> {
    // Strip surrounding quotes if present for here-strings
    let content = redirection.target
    if ((content.startsWith('"') && content.endsWith('"')) || (content.startsWith('\'') && content.endsWith('\''))) {
      content = content.slice(1, -1)
    }
    if (process.stdin) {
      process.stdin.write(`${content}\n`)
      process.stdin.end()
    }
  }

  private static async applyFdRedirection(
    process: ChildProcess,
    redirection: Redirection,
  ): Promise<void> {
    if (typeof redirection.fd !== 'number')
      return

    const dst = redirection.target // like &1 or &-
    // Close FD: n>&-
    if (dst === '&-') {
      if (redirection.fd === 1 && process.stdout) {
        try {
          const out: any = process.stdout
          if (out && typeof out.end === 'function')
            out.end()
          if (out && typeof out.destroy === 'function')
            out.destroy()
        }
        catch {}
      }
      else if (redirection.fd === 2 && process.stderr) {
        try {
          const err: any = process.stderr
          if (err && typeof err.end === 'function')
            err.end()
          if (err && typeof err.destroy === 'function')
            err.destroy()
        }
        catch {}
      }
      else if (redirection.fd === 0 && process.stdin) {
        try {
          const inn: any = process.stdin
          if (inn && typeof inn.end === 'function')
            inn.end()
          if (inn && typeof inn.destroy === 'function')
            inn.destroy()
        }
        catch {}
      }
      return
    }

    const targetFd = Number.parseInt(dst.replace('&', ''), 10)
    if (Number.isNaN(targetFd))
      return

    // For 2>&1 or 1>&2, set flags so pipeline wiring can merge properly
    if (redirection.fd === 2 && targetFd === 1) {
      ;(process as any).__kr_fd_2_to_1 = true
      return
    }
    if (redirection.fd === 1 && targetFd === 2) {
      ;(process as any).__kr_fd_1_to_2 = true
      return
    }

    // For output FDs (1: stdout, 2: stderr)
    const outMap: Record<number, Readable | Writable | null | undefined> = {
      0: process.stdin as any,
      1: process.stdout as any,
      2: process.stderr as any,
    }
    const from = outMap[redirection.fd]
    const to = outMap[targetFd]
    if (!from || !to)
      return

    // If redirecting stderr to stdout (2>&1), pipe stderr into stdout
    // If redirecting stdout to stderr (1>&2), pipe stdout into stderr
    if ((from as any).pipe && (to as any).write) {
      try {
        (from as any).pipe(to as any, { end: false })
      }
      catch {}
    }
  }

  /**
   * Handles here document parsing from multi-line input
   */
  static parseHereDocument(lines: string[], delimiter: string): {
    content: string
    remainingLines: string[]
  } {
    const stripTabs = delimiter.startsWith('-')
    const delim = stripTabs ? delimiter.slice(1) : delimiter
    const content: string[] = []
    let i = 0

    for (i = 0; i < lines.length; i++) {
      let line = lines[i]
      if (line.trim() === delim) {
        break
      }
      if (stripTabs) {
        // Remove leading tabs only, per <<- spec
        line = line.replace(/^\t+/, '')
      }
      content.push(line)
    }

    return {
      content: content.join('\n'),
      remainingLines: lines.slice(i + 1),
    }
  }

  /**
   * Creates a redirection configuration from parsed redirections
   */
  static createRedirectionConfig(redirections: Redirection[]): RedirectionConfig {
    const config: RedirectionConfig = {}

    for (const redirection of redirections) {
      switch (redirection.direction) {
        case 'input':
          if (redirection.type === 'here-string') {
            config.hereString = redirection.target
          }
          else if (redirection.type === 'here-doc') {
            config.hereDoc = redirection.target
          }
          else {
            config.stdin = redirection.target
          }
          break

        case 'output':
          config.stdout = redirection.target
          break

        case 'append':
          if (redirection.type === 'file' && redirection.target.startsWith('APPEND::')) {
            const path = redirection.target.replace(/^APPEND::/, '')
            config.stdout = path
            config.stderr = path
            config.stdoutAppend = true
            config.stderrAppend = true
            config.combineStderr = true
          }
          else {
            config.stdout = redirection.target
            config.stdoutAppend = true
          }
          break

        case 'error':
          config.stderr = redirection.target
          break

        case 'error-append':
          config.stderr = redirection.target
          config.stderrAppend = true
          break

        case 'both':
          if (redirection.type === 'file' && redirection.target.startsWith('APPEND::')) {
            const path = redirection.target.replace(/^APPEND::/, '')
            config.stdout = path
            config.stderr = path
            config.combineStderr = true
            config.stdoutAppend = true
            config.stderrAppend = true
          }
          else {
            config.stdout = redirection.target
            config.stderr = redirection.target
            config.combineStderr = true
          }
          break
      }
    }

    return config
  }
}
