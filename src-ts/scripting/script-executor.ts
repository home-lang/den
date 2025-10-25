import type { CommandResult, Shell } from '../types'
import type { ParsedScript, ScriptBlock, ScriptStatement } from './script-parser'
import { CommandParser } from '../parser'

export interface ScriptContext {
  variables: Map<string, string>
  functions: Map<string, ScriptBlock>
  exitOnError: boolean
  returnValue?: number
  breakLevel?: number
  continueLevel?: number
  shell: Shell
}

export class ScriptExecutor {
  private contexts: ScriptContext[] = []
  private commandParser = new CommandParser()

  async executeScript(script: ParsedScript, shell: Shell, options: { exitOnError?: boolean } = {}): Promise<CommandResult> {
    const context: ScriptContext = {
      variables: new Map(),
      functions: new Map(script.functions),
      exitOnError: options.exitOnError ?? false,
      shell,
    }

    this.contexts.push(context)

    try {
      let accStdout = ''
      let accStderr = ''
      let lastResult: CommandResult = { success: true, exitCode: 0, stdout: '', stderr: '' }

      for (const statement of script.statements) {
        const result = await this.executeStatement(statement, context)
        accStdout += result.stdout || ''
        accStderr += result.stderr || ''
        lastResult = { ...result, stdout: accStdout, stderr: accStderr }

        // Handle error propagation
        if (!result.success && context.exitOnError) {
          return lastResult
        }

        // Handle return/break/continue
        if (context.returnValue !== undefined) {
          return { ...lastResult, exitCode: context.returnValue }
        }

        if (context.breakLevel !== undefined || context.continueLevel !== undefined) {
          break
        }
      }

      return lastResult
    }
    finally {
      this.contexts.pop()
    }
  }

  private async executeStatement(statement: ScriptStatement, context: ScriptContext): Promise<CommandResult> {
    if (statement.type === 'command') {
      return await this.executeCommand(statement, context)
    }
    else if (statement.type === 'block') {
      return await this.executeBlock(statement.block!, context)
    }

    return { success: true, exitCode: 0, stdout: '', stderr: '' }
  }

  private async executeCommand(statement: ScriptStatement, context: ScriptContext): Promise<CommandResult> {
    if (!statement.command) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    const command = statement.command

    // Handle inline chaining inside a script line: e.g., "myfn && echo Y" or "cmd1; cmd2".
    // We use the raw line to detect operators and execute segments within the same script context
    // so that script-defined functions and variables are visible.
    if (statement.raw && (statement.raw.includes('&&') || statement.raw.includes('||') || statement.raw.includes(';'))) {
      const chain = this.commandParser.splitByOperatorsDetailed(statement.raw)
      let aggregate: CommandResult | null = null
      let lastExit = 0
      for (let i = 0; i < chain.length; i++) {
        const { segment } = chain[i]
        if (i > 0) {
          const prevOp = chain[i - 1].op
          if (prevOp === '&&' && lastExit !== 0)
            continue
          if (prevOp === '||' && lastExit === 0)
            continue
        }
        // Parse the segment into a single command (no pipes handled here)
        const parsed = await this.commandParser.parse(segment, context.shell)
        if (parsed.commands.length === 0)
          continue
        const segStmt: ScriptStatement = {
          type: 'command',
          command: parsed.commands[0],
          raw: segment,
        }
        const segRes = await this.executeCommand(segStmt, context)
        lastExit = segRes.exitCode
        aggregate = aggregate
          ? { ...segRes, stdout: (aggregate.stdout || '') + (segRes.stdout || ''), stderr: (aggregate.stderr || '') + (segRes.stderr || '') }
          : { ...segRes }
      }
      return aggregate || { success: true, exitCode: lastExit, stdout: '', stderr: '' }
    }

    // Handle built-in script commands
    switch (command.name) {
      case 'return':
        context.returnValue = command.args.length > 0 ? Number.parseInt(command.args[0]) || 0 : 0
        return { success: true, exitCode: context.returnValue, stdout: '', stderr: '' }

      case 'break':
        context.breakLevel = command.args.length > 0 ? Number.parseInt(command.args[0]) || 1 : 1
        return { success: true, exitCode: 0, stdout: '', stderr: '' }

      case 'continue':
        context.continueLevel = command.args.length > 0 ? Number.parseInt(command.args[0]) || 1 : 1
        return { success: true, exitCode: 0, stdout: '', stderr: '' }

      case 'local':
        // Handle local variable declarations
        for (const arg of command.args) {
          if (arg.includes('=')) {
            const [name, value] = arg.split('=', 2)
            context.variables.set(name, value || '')
          }
        }
        return { success: true, exitCode: 0, stdout: '', stderr: '' }

      case 'set':
        // Handle set options
        if (command.args.includes('-e')) {
          context.exitOnError = true
        }
        if (command.args.includes('+e')) {
          context.exitOnError = false
        }
        return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    // Check if it's a function call
    if (context.functions.has(command.name)) {
      return await this.executeFunction(command.name, command.args, context)
    }

    // Execute regular command through shell
    try {
      // Expand variables in arguments (e.g., echo "num: $i") prior to delegating to shell
      const expandedArgs: string[] = []
      for (const arg of command.args) {
        expandedArgs.push(await this.expandString(arg, context))
      }
      const result = await context.shell.executeCommand(command.name, expandedArgs)
      return result
    }
    catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      return {
        success: false,
        exitCode: 1,
        stdout: '',
        stderr: errorMsg,
      }
    }
  }

  private async executeBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    switch (block.type) {
      case 'if':
        return await this.executeIfBlock(block, context)
      case 'for':
        return await this.executeForBlock(block, context)
      case 'while':
        return await this.executeWhileBlock(block, context)
      case 'until':
        return await this.executeUntilBlock(block, context)
      case 'case':
        return await this.executeCaseBlock(block, context)
      case 'function':
        // Function definitions are handled during parsing
        return { success: true, exitCode: 0, stdout: '', stderr: '' }
      default:
        return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }
  }

  private async executeIfBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    if (!block.condition) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    const conditionResult = await this.evaluateCondition(block.condition, context)

    if (conditionResult) {
      const res = await this.executeStatements(block.body, context)
      return { ...res, exitCode: 0, success: true }
    }
    else if (block.elseBody) {
      const res = await this.executeStatements(block.elseBody, context)
      // Condition was false => make overall if-statement exit non-zero to allow `||` chains
      return { ...res, exitCode: 1, success: false }
    }

    // No body executed; return non-zero to reflect false condition
    return { success: false, exitCode: 1, stdout: '', stderr: '' }
  }

  private async executeForBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    if (!block.variable || !block.values) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    let accStdout = ''
    let accStderr = ''
    let lastResult: CommandResult = { success: true, exitCode: 0, stdout: '', stderr: '' }

    for (const value of block.values) {
      // Set loop variable
      const oldValue = context.shell.environment[block.variable]
      context.shell.environment[block.variable] = value

      try {
        const iterResult = await this.executeStatements(block.body, context)
        accStdout += iterResult.stdout || ''
        accStderr += iterResult.stderr || ''
        lastResult = { ...iterResult, stdout: accStdout, stderr: accStderr }

        // Handle break/continue
        if (context.breakLevel !== undefined) {
          if (context.breakLevel > 1) {
            context.breakLevel--
          }
          else {
            context.breakLevel = undefined
          }
          break
        }

        if (context.continueLevel !== undefined) {
          if (context.continueLevel > 1) {
            context.continueLevel--
            break
          }
          else {
            context.continueLevel = undefined
            continue
          }
        }

        // Handle error propagation
        if (!iterResult.success && context.exitOnError) {
          break
        }
      }
      finally {
        // Restore old value
        if (oldValue !== undefined) {
          context.shell.environment[block.variable] = oldValue
        }
        else {
          delete context.shell.environment[block.variable]
        }
      }
    }

    return lastResult
  }

  private async executeWhileBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    if (!block.condition) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    let accStdout = ''
    let accStderr = ''
    let lastResult: CommandResult = { success: true, exitCode: 0, stdout: '', stderr: '' }

    while (await this.evaluateCondition(block.condition, context)) {
      const iterResult = await this.executeStatements(block.body, context)
      accStdout += iterResult.stdout || ''
      accStderr += iterResult.stderr || ''
      lastResult = { ...iterResult, stdout: accStdout, stderr: accStderr }

      // Handle break/continue
      if (context.breakLevel !== undefined) {
        if (context.breakLevel > 1) {
          context.breakLevel--
        }
        else {
          context.breakLevel = undefined
        }
        break
      }

      if (context.continueLevel !== undefined) {
        if (context.continueLevel > 1) {
          context.continueLevel--
          break
        }
        else {
          context.continueLevel = undefined
          continue
        }
      }

      // Handle error propagation
      if (!iterResult.success && context.exitOnError) {
        break
      }
    }

    return lastResult
  }

  private async executeUntilBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    if (!block.condition) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    let accStdout = ''
    let accStderr = ''
    let lastResult: CommandResult = { success: true, exitCode: 0, stdout: '', stderr: '' }

    while (!(await this.evaluateCondition(block.condition, context))) {
      const iterResult = await this.executeStatements(block.body, context)
      accStdout += iterResult.stdout || ''
      accStderr += iterResult.stderr || ''
      lastResult = { ...iterResult, stdout: accStdout, stderr: accStderr }

      // Handle break/continue
      if (context.breakLevel !== undefined) {
        if (context.breakLevel > 1) {
          context.breakLevel--
        }
        else {
          context.breakLevel = undefined
        }
        break
      }

      if (context.continueLevel !== undefined) {
        if (context.continueLevel > 1) {
          context.continueLevel--
          break
        }
        else {
          context.continueLevel = undefined
          continue
        }
      }

      // Handle error propagation
      if (!lastResult.success && context.exitOnError) {
        break
      }
    }

    return lastResult
  }

  private async executeCaseBlock(block: ScriptBlock, context: ScriptContext): Promise<CommandResult> {
    if (!block.variable || !block.cases) {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    }

    const value = await this.expandVariable(block.variable, context)

    for (const casePattern of block.cases) {
      if (this.matchPattern(value, casePattern.pattern)) {
        return await this.executeStatements(casePattern.body, context)
      }
    }

    return { success: true, exitCode: 0, stdout: '', stderr: '' }
  }

  private async executeFunction(name: string, args: string[], context: ScriptContext): Promise<CommandResult> {
    const func = context.functions.get(name)
    if (!func) {
      return {
        success: false,
        exitCode: 127,
        stdout: '',
        stderr: `Function '${name}' not found`,
      }
    }

    // Create new context for function execution
    const funcContext: ScriptContext = {
      variables: new Map(context.variables),
      functions: context.functions,
      exitOnError: context.exitOnError,
      shell: context.shell,
    }

    // Set positional parameters
    funcContext.shell.environment['0'] = name
    for (let i = 0; i < args.length; i++) {
      funcContext.shell.environment[`${i + 1}`] = args[i]
    }
    funcContext.shell.environment['#'] = args.length.toString()

    this.contexts.push(funcContext)

    try {
      const result = await this.executeStatements(func.body, funcContext)

      if (funcContext.returnValue !== undefined) {
        return { ...result, exitCode: funcContext.returnValue }
      }

      return result
    }
    finally {
      this.contexts.pop()

      // Clean up positional parameters
      delete funcContext.shell.environment['0']
      for (let i = 1; i <= args.length; i++) {
        delete funcContext.shell.environment[`${i}`]
      }
      delete funcContext.shell.environment['#']
    }
  }

  private async executeStatements(statements: ScriptStatement[], context: ScriptContext): Promise<CommandResult> {
    let accStdout = ''
    let accStderr = ''
    let lastResult: CommandResult = { success: true, exitCode: 0, stdout: '', stderr: '' }

    for (const statement of statements) {
      const result = await this.executeStatement(statement, context)
      accStdout += result.stdout || ''
      accStderr += result.stderr || ''
      lastResult = { ...result, stdout: accStdout, stderr: accStderr }

      // Handle control flow
      if (context.returnValue !== undefined
        || context.breakLevel !== undefined
        || context.continueLevel !== undefined) {
        break
      }

      // Handle error propagation
      if (!result.success && context.exitOnError) {
        break
      }
    }

    return lastResult
  }

  private async evaluateCondition(condition: string, context: ScriptContext): Promise<boolean> {
    try {
      // Handle test expressions
      if (condition.startsWith('[') && condition.endsWith(']')) {
        const testExpr = condition.slice(1, -1).trim()
        return await this.evaluateTestExpression(testExpr, context)
      }

      // Handle [[ ]] expressions
      if (condition.startsWith('[[') && condition.endsWith(']]')) {
        const testExpr = condition.slice(2, -2).trim()
        return await this.evaluateTestExpression(testExpr, context)
      }

      // Execute as command and check exit code - avoid recursion by parsing and executing directly
      const parsed = await context.shell.parseCommand(condition)
      if (parsed.commands.length === 0) {
        return false
      }
      const result = await (context.shell as any).executeCommandChain(parsed)
      return (result.success ?? result.exitCode === 0) && result.exitCode === 0
    }
    catch {
      return false
    }
  }

  private async evaluateTestExpression(expr: string, context: ScriptContext): Promise<boolean> {
    const tokens = expr.split(/\s+/)

    if (tokens.length === 1) {
      // Single argument - test if non-empty
      const value = await this.expandVariable(tokens[0], context)
      return value.length > 0
    }

    if (tokens.length === 2 && tokens[0].startsWith('-')) {
      // Unary test operators
      const operator = tokens[0]
      const operand = await this.expandVariable(tokens[1], context)

      switch (operator) {
        case '-z': return operand.length === 0
        case '-n': return operand.length > 0
        case '-f': return await this.fileExists(operand) && await this.isFile(operand)
        case '-d': return await this.fileExists(operand) && await this.isDirectory(operand)
        case '-e': return await this.fileExists(operand)
        case '-r': return await this.isReadable(operand)
        case '-w': return await this.isWritable(operand)
        case '-x': return await this.isExecutable(operand)
        default: return false
      }
    }

    if (tokens.length === 3) {
      // Binary test operators
      const left = await this.expandVariable(tokens[0], context)
      const operator = tokens[1]
      const right = await this.expandVariable(tokens[2], context)

      switch (operator) {
        case '=':
        case '==': return left === right
        case '!=': return left !== right
        case '-eq': return Number.parseInt(left) === Number.parseInt(right)
        case '-ne': return Number.parseInt(left) !== Number.parseInt(right)
        case '-lt': return Number.parseInt(left) < Number.parseInt(right)
        case '-le': return Number.parseInt(left) <= Number.parseInt(right)
        case '-gt': return Number.parseInt(left) > Number.parseInt(right)
        case '-ge': return Number.parseInt(left) >= Number.parseInt(right)
        default: return false
      }
    }

    return false
  }

  private async expandVariable(variable: string, context: ScriptContext): Promise<string> {
    if (variable.startsWith('$')) {
      const varName = variable.slice(1)
      return context.shell.environment[varName] || context.variables.get(varName) || ''
    }
    return variable
  }

  // Expand variables within a string, supporting $VAR, ${VAR}, and positional $1..$9
  private async expandString(input: string, context: ScriptContext): Promise<string> {
    if (!input || (!input.includes('$')))
      return input

    return input.replace(/\$(\{[^}]+\}|[A-Z_]\w*|\d)/gi, (match, p1) => {
      let key = p1 as string
      if (!key)
        return ''
      if (key.startsWith('{') && key.endsWith('}')) {
        key = key.slice(1, -1)
      }
      const val = context.shell.environment[key] ?? context.variables.get(key)
      return val !== undefined ? String(val) : ''
    })
  }

  private matchPattern(value: string, pattern: string): boolean {
    // Convert shell pattern to regex
    const regexPattern = pattern
      .replace(/\*/g, '.*')
      .replace(/\?/g, '.')
      .replace(/\[([^\]]+)\]/g, '[$1]')

    const regex = new RegExp(`^${regexPattern}$`)
    return regex.test(value)
  }

  private async fileExists(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      await fs.access(path)
      return true
    }
    catch {
      return false
    }
  }

  private async isFile(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      const stats = await fs.stat(path)
      return stats.isFile()
    }
    catch {
      return false
    }
  }

  private async isDirectory(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      const stats = await fs.stat(path)
      return stats.isDirectory()
    }
    catch {
      return false
    }
  }

  private async isReadable(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      await fs.access(path, (await import('node:fs')).constants.R_OK)
      return true
    }
    catch {
      return false
    }
  }

  private async isWritable(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      await fs.access(path, (await import('node:fs')).constants.W_OK)
      return true
    }
    catch {
      return false
    }
  }

  private async isExecutable(path: string): Promise<boolean> {
    try {
      const fs = await import('node:fs/promises')
      await fs.access(path, (await import('node:fs')).constants.X_OK)
      return true
    }
    catch {
      return false
    }
  }
}
