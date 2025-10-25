import type { CommandParser } from '../parser'

export class AliasManager {
  private aliases: Record<string, string>
  private parser: CommandParser
  private cwd: string
  private environment: Record<string, string>

  constructor(aliases: Record<string, string>, parser: CommandParser, cwd: string, environment: Record<string, string>) {
    this.aliases = { ...aliases }
    this.parser = parser
    this.cwd = cwd
    this.environment = environment
  }

  updateCwd(cwd: string): void {
    this.cwd = cwd
  }

  updateEnvironment(environment: Record<string, string>): void {
    this.environment = environment
  }

  getAliases(): Record<string, string> {
    return { ...this.aliases }
  }

  setAlias(name: string, value: string): void {
    this.aliases[name] = value
  }

  removeAlias(name: string): void {
    delete this.aliases[name]
  }

  /**
   * Expands aliases with cycle detection to prevent infinite recursion
   */
  async expandAliasWithCycleDetection(command: any, visited: Set<string> = new Set()): Promise<any> {
    if (!command?.name)
      return command

    // Check for cycles
    if (visited.has(command.name)) {
      console.error(`Alias cycle detected: ${Array.from(visited).join(' -> ')} -> ${command.name}`)
      return command
    }

    const expanded = await this.expandAlias(command)

    // If the command wasn't an alias, we're done
    if (expanded === command) {
      return command
    }

    // Continue expanding aliases in the expanded command
    visited.add(command.name)
    return this.expandAliasWithCycleDetection(expanded, visited)
  }

  /**
   * Expands a command if it matches a defined alias
   */
  async expandAlias(command: any): Promise<any> {
    if (!command?.name) {
      return command
    }

    const aliasValue = this.aliases[command.name]
    if (aliasValue === undefined) {
      return command
    }

    // Handle empty alias
    if (aliasValue === '') {
      if (command.args.length > 0) {
        return {
          ...command,
          name: command.args[0],
          args: command.args.slice(1),
        }
      }
      return { ...command, name: 'true', args: [] }
    }

    // If the alias contains a pipe, we need to parse it as a command chain
    if (aliasValue.includes('|') && !aliasValue.includes('\"') && !aliasValue.includes('\'')) {
      try {
        // Parse the alias value as a command chain
        const parsed = await this.parser.parse(aliasValue, { cwd: this.cwd, env: this.environment } as any)

        // If we have a command chain, return it directly
        if (parsed?.commands?.length > 0) {
          // Preserve the original command's arguments if needed
          if (command.args.length > 0) {
            // Append the original command's arguments to the last command in the pipeline
            const lastCmd = parsed.commands[parsed.commands.length - 1]
            lastCmd.args = [...(lastCmd.args || []), ...command.args]
          }
          return parsed
        }
      }
      catch (e) {
        // If parsing fails, fall through to the regular alias expansion
        console.error('Failed to parse alias with pipe:', e)
      }
    }

    // Process the alias value
    let processedValue = aliasValue.trim()

    // Simple command substitution for current working directory
    processedValue = processedValue
      .replace(/`pwd`/g, this.cwd)
      .replace(/\$\(pwd\)/g, this.cwd)

    // Handle quoted numeric placeholders like "$1"
    const QUOTED_MARKER_PREFIX = '__krusty_QARG_'
    processedValue = processedValue.replace(/"\$(\d+)"/g, (_m, num) => `${QUOTED_MARKER_PREFIX}${num}__`)

    const hadQuotedPlaceholders = /"\$\d+"/.test(aliasValue)
    const argsToUse = (command as any).originalArgs || command.args
    const dequote = (s: string) => this.processAliasArgument(s)
    const hasArgs = argsToUse.length > 0
    const endsWithSpace = aliasValue.endsWith(' ')
    const hasPlaceholders = /\$@|\$\d+/.test(aliasValue)

    // Handle environment variables
    processedValue = processedValue.replace(/\$([A-Z_][A-Z0-9_]*)(?=\W|$)/g, (match, varName) => {
      return this.environment[varName] !== undefined ? this.environment[varName] : match
    })

    // Apply brace expansion
    if (processedValue.includes('{') && processedValue.includes('}')) {
      const braceRegex = /([^{}\s]*)\{([^{}]+)\}([^{}\s]*)/g
      processedValue = processedValue.replace(braceRegex, (match, prefix, content, suffix) => {
        if (content.includes(',')) {
          const items = content.split(',').map((item: string) => item.trim())
          return items.map((item: string) => `${prefix}${item}${suffix}`).join(' ')
        }
        if (content.includes('..')) {
          const [start, end] = content.split('..', 2)
          const startNum = Number.parseInt(start.trim(), 10)
          const endNum = Number.parseInt(end.trim(), 10)
          if (!Number.isNaN(startNum) && !Number.isNaN(endNum)) {
            const range = []
            if (startNum <= endNum) {
              for (let i = startNum; i <= endNum; i++) range.push(i)
            }
            else {
              for (let i = startNum; i >= endNum; i--) range.push(i)
            }
            return range.map(num => `${prefix}${num}${suffix}`).join(' ')
          }
        }
        return match
      })
    }

    // Handle argument substitution
    if (hasArgs) {
      // Replace $@ with all arguments
      processedValue = processedValue.replace(/\$@/g, () => {
        return argsToUse.map((arg: string) => {
          // Preserve original quotes if they exist, otherwise add quotes for spaces
          if ((arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))) {
            return arg
          }
          return /\s/.test(arg) ? `"${arg}"` : arg
        }).join(' ')
      })

      // Replace numbered placeholders like $1, $2, etc.
      processedValue = processedValue.replace(/\$(\d+)/g, (_, num) => {
        const index = Number.parseInt(num, 10) - 1
        if (argsToUse[index] === undefined)
          return ''
        const arg = argsToUse[index]
        // Preserve original quotes if they exist
        if ((arg.startsWith('"') && arg.endsWith('"')) || (arg.startsWith('\'') && arg.endsWith('\''))) {
          return arg
        }
        return dequote(arg)
      })

      // If alias ends with space OR it doesn't contain placeholders, append remaining args
      if (command.args.length > 0 && (endsWithSpace || !hasPlaceholders)) {
        const quoted = command.args.map((arg: string) => (/\s/.test(arg) ? `"${arg}"` : arg))
        if (endsWithSpace) {
          // For trailing space, append directly without extra space
          processedValue += quoted.join(' ')
        }
        else {
          processedValue += ` ${quoted.join(' ')}`
        }
      }
    }
    else {
      // If no args but alias expects them, replace with empty string
      processedValue = processedValue.replace(/\$@|\$\d+/g, '')
    }

    // Handle multiple commands separated by ;, &&, ||
    const segments = this.parseCommandSegments(processedValue)

    if (segments.length === 0) {
      return command
    }

    // Process each command in the sequence
    const processedCommands: any[] = []
    for (let i = 0; i < segments.length; i++) {
      const cmd = this.processCommand(segments[i].cmd, i === 0, command, argsToUse, dequote, hadQuotedPlaceholders)
      if (cmd)
        processedCommands.push({ node: cmd, op: segments[i].op })
    }

    if (processedCommands.length === 0) {
      return command
    }

    // If there's only one command, return it directly
    if (processedCommands.length === 1) {
      return processedCommands[0].node
    }

    // For multiple commands, chain them together
    const result = { ...processedCommands[0].node }
    let current: any = result
    for (let i = 1; i < processedCommands.length; i++) {
      current.next = {
        type: (processedCommands[i - 1].op || ';'),
        command: processedCommands[i].node,
      }
      current = current.next.command
    }

    return result
  }

  private parseCommandSegments(processedValue: string): Array<{ cmd: string, op?: ';' | '&&' | '||' }> {
    const segments: Array<{ cmd: string, op?: ';' | '&&' | '||' }> = []
    let buf = ''
    let inQuotes = false
    let q = ''
    let i = 0

    const pushSeg = (op?: ';' | '&&' | '||') => {
      const t = buf.trim()
      if (t)
        segments.push({ cmd: t, op })
      buf = ''
    }

    while (i < processedValue.length) {
      const ch = processedValue[i]
      const next = processedValue[i + 1]

      if (!inQuotes && (ch === '"' || ch === '\'')) {
        inQuotes = true
        q = ch
        buf += ch
        i++
        continue
      }
      if (inQuotes && ch === q) {
        inQuotes = false
        q = ''
        buf += ch
        i++
        continue
      }
      if (!inQuotes) {
        if (ch === ';') {
          pushSeg(';')
          i++
          continue
        }
        if (ch === '\n') {
          pushSeg(';')
          i++
          continue
        }
        if (ch === '&' && next === '&') {
          pushSeg('&&')
          i += 2
          continue
        }
        if (ch === '|' && next === '|') {
          pushSeg('||')
          i += 2
          continue
        }
      }
      buf += ch
      i++
    }
    pushSeg()

    return segments
  }

  private processCommand(cmdStr: string, isFirst: boolean, command: any, argsToUse: string[], dequote: (s: string) => string, hadQuotedPlaceholders: boolean) {
    // Extract simple stdin redirection: < file
    let stdinFile: string | undefined
    const stdinMatch = cmdStr.match(/<\s*([^\s|;&]+)/)
    if (stdinMatch) {
      stdinFile = stdinMatch[1]
      cmdStr = cmdStr.replace(/<\s*[^\s|;&]+/, '').trim()
    }

    // Handle pipes in the command
    const parts = this.splitByPipes(cmdStr)

    if (parts.length > 1) {
      const pipeCommands = parts.map((part) => {
        const tokens = this.parser.tokenize(part)
        return {
          name: tokens[0] || '',
          args: tokens.slice(1),
        }
      })

      return {
        ...pipeCommands[0],
        stdinFile,
        pipe: true,
        pipeCommands: pipeCommands.slice(1),
      }
    }

    // No pipes, just a simple command
    const tokens = this.parser.tokenize(cmdStr)
    if (tokens.length === 0) {
      return null
    }

    const baseCommand = isFirst ? { ...command } : {}
    let finalArgs = tokens.slice(1)

    // Post-process quoted numeric placeholders
    finalArgs = finalArgs.map((arg) => {
      const m = arg.match(/^__krusty_QARG_(\d+)__$/)
      if (m) {
        const idx = Number.parseInt(m[1], 10) - 1
        const val = argsToUse[idx] !== undefined ? dequote(argsToUse[idx]) : ''
        return /\s/.test(val) ? `"${val}"` : val
      }
      return arg
    })

    return {
      ...baseCommand,
      name: tokens[0],
      args: finalArgs.filter(arg => arg !== ''),
      stdinFile,
      preserveQuotedArgs: hadQuotedPlaceholders,
    }
  }

  private splitByPipes(cmdStr: string): string[] {
    let inQuotes = false
    let q = ''
    const parts: string[] = []
    let buf = ''

    for (let i = 0; i < cmdStr.length; i++) {
      const ch = cmdStr[i]

      if (!inQuotes && (ch === '"' || ch === '\'')) {
        inQuotes = true
        q = ch
        buf += ch
        continue
      }
      if (inQuotes && ch === q) {
        inQuotes = false
        q = ''
        buf += ch
        continue
      }
      if (!inQuotes && ch === '|') {
        parts.push(buf.trim())
        buf = ''
        continue
      }
      buf += ch
    }

    if (buf.trim())
      parts.push(buf.trim())

    return parts
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
}
