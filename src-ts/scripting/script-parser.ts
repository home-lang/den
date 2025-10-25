import type { Command } from '../types'
import { CommandParser } from '../parser'

export interface ScriptBlock {
  type: 'if' | 'for' | 'while' | 'until' | 'case' | 'function' | 'command'
  condition?: string
  body: ScriptStatement[]
  elseBody?: ScriptStatement[]
  variable?: string // for loops
  values?: string[] // for loops
  cases?: CasePattern[] // for case statements
  functionName?: string // for functions
  parameters?: string[] // for functions
}

export interface CasePattern {
  pattern: string
  body: ScriptStatement[]
}

export interface ScriptStatement {
  type: 'block' | 'command'
  block?: ScriptBlock
  command?: Command
  raw: string
}

export interface ParsedScript {
  statements: ScriptStatement[]
  functions: Map<string, ScriptBlock>
}

export class ScriptParser {
  private commandParser = new CommandParser()
  private keywords = new Set([
    'if',
    'then',
    'else',
    'elif',
    'fi',
    'for',
    'while',
    'until',
    'do',
    'done',
    'case',
    'in',
    'esac',
    'function',
    '{',
    '}',
  ])

  async parseScript(input: string, shell?: any): Promise<ParsedScript> {
    const lines = this.preprocessScript(input)
    const statements: ScriptStatement[] = []
    const functions = new Map<string, ScriptBlock>()

    let i = 0
    while (i < lines.length) {
      const result = await this.parseStatement(lines, i, shell)
      if (result.statement) {
        if (result.statement.block?.type === 'function' && result.statement.block.functionName) {
          functions.set(result.statement.block.functionName, result.statement.block)
        }
        else {
          statements.push(result.statement)
        }
      }
      i = result.nextIndex
    }

    return { statements, functions }
  }

  private preprocessScript(input: string): string[] {
    // Split into lines and handle line continuations
    const rawLines = input.split('\n')
    const lines: string[] = []

    for (let i = 0; i < rawLines.length; i++) {
      let line = rawLines[i].trim()

      // Skip empty lines and comments
      if (!line || line.startsWith('#'))
        continue

      // Handle line continuations
      while (line.endsWith('\\') && i + 1 < rawLines.length) {
        line = `${line.slice(0, -1)} ${rawLines[++i].trim()}`
      }

      // If this is a single-line function definition, keep it intact even if it contains semicolons
      const isSingleLineFunc = /^\s*[A-Z_]\w*\s*\(\)\s*\{[\s\S]*\}\s*$/i.test(line) || /^\s*function\b[^{]*\{[\s\S]*\}\s*$/.test(line)
      if (!isSingleLineFunc && line.includes(';')) {
        const parts = this.splitBySemicolon(line)
        lines.push(...parts)
      }
      else {
        lines.push(line)
      }
    }

    return lines
  }

  private splitBySemicolon(line: string): string[] {
    const parts: string[] = []
    let current = ''
    let inQuotes = false
    let quoteChar = ''
    let escaped = false

    for (let i = 0; i < line.length; i++) {
      const char = line[i]

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

      if (!inQuotes && char === ';') {
        if (current.trim()) {
          parts.push(current.trim())
          current = ''
        }
        continue
      }

      current += char
    }

    if (current.trim()) {
      parts.push(current.trim())
    }

    return parts
  }

  private async parseStatement(lines: string[], startIndex: number, shell?: any): Promise<{
    statement: ScriptStatement | null
    nextIndex: number
  }> {
    const line = lines[startIndex]
    // Detect inline short function definitions like: name() { echo X; }
    const inlineFuncMatch = line.match(/^\s*([A-Z_]\w*)\s*\(\)\s*\{([\s\S]*)\}\s*$/i)
    if (inlineFuncMatch) {
      const name = inlineFuncMatch[1]
      const bodyRaw = inlineFuncMatch[2].trim()
      const bodyStmts: ScriptStatement[] = []
      if (bodyRaw.length > 0) {
        const parts = this.splitBySemicolon(bodyRaw)
        for (const part of parts) {
          const res = await this.parseCommandStatement(part, shell, startIndex)
          bodyStmts.push(res.statement)
        }
      }

      const block: ScriptBlock = {
        type: 'function',
        functionName: name,
        parameters: [],
        body: bodyStmts,
      }

      return {
        statement: {
          type: 'block',
          block,
          raw: line,
        },
        nextIndex: startIndex + 1,
      }
    }
    const tokens = this.commandParser.tokenize(line)

    if (tokens.length === 0) {
      return { statement: null, nextIndex: startIndex + 1 }
    }

    const firstToken = tokens[0]

    // Handle control flow constructs
    switch (firstToken) {
      case 'if':
        return await this.parseIfStatement(lines, startIndex, shell)
      case 'for':
        return await this.parseForStatement(lines, startIndex, shell)
      case 'while':
      case 'until':
        return await this.parseWhileUntilStatement(lines, startIndex, shell)
      case 'case':
        return await this.parseCaseStatement(lines, startIndex, shell)
      case 'function':
        return await this.parseFunctionStatement(lines, startIndex, shell)
      default:
        // Check if it's a function definition without 'function' keyword
        if (tokens.length >= 2 && tokens[1] === '()') {
          return await this.parseFunctionStatement(lines, startIndex, shell, true)
        }
        // Regular command
        return await this.parseCommandStatement(line, shell, startIndex)
    }
  }

  private async parseIfStatement(lines: string[], startIndex: number, shell?: any): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const ifLine = lines[startIndex]
    const condition = this.extractCondition(ifLine, 'if')

    const body: ScriptStatement[] = []
    const elseBody: ScriptStatement[] = []
    let i = startIndex + 1
    let inElse = false

    while (i < lines.length) {
      const line = lines[i].trim()
      const tokens = this.commandParser.tokenize(line)

      if (tokens[0] === 'then') {
        // Support inline command on the same line as 'then'
        const after = line.slice(line.indexOf('then') + 4).trim()
        if (after) {
          const res = await this.parseCommandStatement(after, shell, i)
          body.push(res.statement)
        }
        i++
        continue
      }

      if (tokens[0] === 'else') {
        // Support inline command on the same line as 'else'
        const after = line.slice(line.indexOf('else') + 4).trim()
        inElse = true
        if (after) {
          const res = await this.parseCommandStatement(after, shell, i)
          elseBody.push(res.statement)
        }
        i++
        continue
      }

      if (tokens[0] === 'elif') {
        // Handle elif as nested if-else
        const elifCondition = this.extractCondition(line, 'elif')
        const nestedIf: ScriptBlock = {
          type: 'if',
          condition: elifCondition,
          body: [],
          elseBody: [],
        }

        const nestedStatement: ScriptStatement = {
          type: 'block',
          block: nestedIf,
          raw: line,
        }

        if (inElse) {
          elseBody.push(nestedStatement)
        }
        else {
          body.push(nestedStatement)
        }

        i++
        continue
      }

      if (tokens[0] === 'fi') {
        i++
        break
      }

      const result = await this.parseStatement(lines, i, shell)
      if (result.statement) {
        if (inElse) {
          elseBody.push(result.statement)
        }
        else {
          body.push(result.statement)
        }
      }
      i = result.nextIndex
    }

    const block: ScriptBlock = {
      type: 'if',
      condition,
      body,
      elseBody: elseBody.length > 0 ? elseBody : undefined,
    }

    return {
      statement: {
        type: 'block',
        block,
        raw: ifLine,
      },
      nextIndex: i,
    }
  }

  private async parseForStatement(lines: string[], startIndex: number, shell?: any): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const forLine = lines[startIndex]
    const { variable, values } = this.parseForLoop(forLine)

    const body: ScriptStatement[] = []
    let i = startIndex + 1

    while (i < lines.length) {
      const line = lines[i].trim()
      const tokens = this.commandParser.tokenize(line)

      if (tokens[0] === 'do') {
        i++
        continue
      }

      if (tokens[0] === 'done') {
        i++
        break
      }

      const result = await this.parseStatement(lines, i, shell)
      if (result.statement) {
        body.push(result.statement)
      }
      i = result.nextIndex
    }

    const block: ScriptBlock = {
      type: 'for',
      variable,
      values,
      body,
    }

    return {
      statement: {
        type: 'block',
        block,
        raw: forLine,
      },
      nextIndex: i,
    }
  }

  private async parseWhileUntilStatement(lines: string[], startIndex: number, shell?: any): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const loopLine = lines[startIndex]
    const tokens = this.commandParser.tokenize(loopLine)
    const type = tokens[0] as 'while' | 'until'
    const condition = this.extractCondition(loopLine, type)

    const body: ScriptStatement[] = []
    let i = startIndex + 1

    while (i < lines.length) {
      const line = lines[i].trim()
      const lineTokens = this.commandParser.tokenize(line)

      if (lineTokens[0] === 'do') {
        i++
        continue
      }

      if (lineTokens[0] === 'done') {
        i++
        break
      }

      const result = await this.parseStatement(lines, i, shell)
      if (result.statement) {
        body.push(result.statement)
      }
      i = result.nextIndex
    }

    const block: ScriptBlock = {
      type,
      condition,
      body,
    }

    return {
      statement: {
        type: 'block',
        block,
        raw: loopLine,
      },
      nextIndex: i,
    }
  }

  private async parseCaseStatement(lines: string[], startIndex: number, shell?: any): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const caseLine = lines[startIndex]
    const variable = this.extractCaseVariable(caseLine)

    const cases: CasePattern[] = []
    let i = startIndex + 1

    while (i < lines.length) {
      const line = lines[i].trim()
      const tokens = this.commandParser.tokenize(line)

      if (tokens[0] === 'in') {
        i++
        continue
      }

      if (tokens[0] === 'esac') {
        i++
        break
      }

      // Parse case pattern
      if (line.includes(')')) {
        const pattern = line.split(')')[0].trim()
        const caseBody: ScriptStatement[] = []
        i++

        // Parse case body until ;;
        while (i < lines.length) {
          const bodyLine = lines[i].trim()

          if (bodyLine === ';;') {
            i++
            break
          }

          if (bodyLine === 'esac') {
            break
          }

          const result = await this.parseStatement(lines, i, shell)
          if (result.statement) {
            caseBody.push(result.statement)
          }
          i = result.nextIndex
        }

        cases.push({ pattern, body: caseBody })
      }
      else {
        i++
      }
    }

    const block: ScriptBlock = {
      type: 'case',
      variable,
      cases,
      body: [], // Not used for case statements
    }

    return {
      statement: {
        type: 'block',
        block,
        raw: caseLine,
      },
      nextIndex: i,
    }
  }

  private async parseFunctionStatement(lines: string[], startIndex: number, shell?: any, shortSyntax = false): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const funcLine = lines[startIndex]
    const { name, parameters } = this.parseFunctionDefinition(funcLine, shortSyntax)

    const body: ScriptStatement[] = []
    let i = startIndex + 1
    let braceCount = 0
    let foundOpenBrace = false

    while (i < lines.length) {
      const line = lines[i].trim()

      if (line === '{') {
        foundOpenBrace = true
        braceCount++
        i++
        continue
      }

      if (line === '}') {
        braceCount--
        if (braceCount === 0 && foundOpenBrace) {
          i++
          break
        }
        i++
        continue
      }

      if (foundOpenBrace) {
        const result = await this.parseStatement(lines, i, shell)
        if (result.statement) {
          body.push(result.statement)
        }
        i = result.nextIndex
      }
      else {
        i++
      }
    }

    const block: ScriptBlock = {
      type: 'function',
      functionName: name,
      parameters,
      body,
    }

    return {
      statement: {
        type: 'block',
        block,
        raw: funcLine,
      },
      nextIndex: i,
    }
  }

  private async parseCommandStatement(line: string, shell?: any, startIndex?: number): Promise<{
    statement: ScriptStatement
    nextIndex: number
  }> {
    const parsed = await this.commandParser.parse(line, shell)
    const command = parsed.commands[0]

    return {
      statement: {
        type: 'command',
        command,
        raw: line,
      },
      nextIndex: (startIndex ?? 0) + 1,
    }
  }

  private extractCondition(line: string, keyword: string): string {
    const keywordIndex = line.indexOf(keyword)
    const afterKeyword = line.substring(keywordIndex + keyword.length).trim()

    // Remove 'then' if present
    if (afterKeyword.endsWith(' then')) {
      return afterKeyword.substring(0, afterKeyword.length - 5).trim()
    }

    return afterKeyword
  }

  private parseForLoop(line: string): { variable: string, values: string[] } {
    // Parse: for var in value1 value2 value3
    const tokens = this.commandParser.tokenize(line)
    const variable = tokens[1]

    const inIndex = tokens.indexOf('in')
    if (inIndex === -1) {
      return { variable, values: [] }
    }

    const values = tokens.slice(inIndex + 1).filter(token => token !== 'do')
    return { variable, values }
  }

  private extractCaseVariable(line: string): string {
    // Parse: case $var in
    const tokens = this.commandParser.tokenize(line)
    return tokens[1] || ''
  }

  private parseFunctionDefinition(line: string, shortSyntax: boolean): { name: string, parameters: string[] } {
    if (shortSyntax) {
      // Parse: funcname() { ... }
      const name = line.split('()')[0].trim()
      return { name, parameters: [] }
    }
    else {
      // Parse: function funcname { ... } or function funcname() { ... }
      const tokens = this.commandParser.tokenize(line)
      const name = tokens[1]
      // TODO: Parse parameters if needed
      return { name, parameters: [] }
    }
  }
}
