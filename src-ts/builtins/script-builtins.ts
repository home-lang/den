import type { BuiltinCommand, CommandResult, Shell } from '../types'
import * as fs from 'node:fs'
import { ScriptManager } from '../scripting/script-manager'

// Simple test expression evaluator to avoid recursion
function evaluateTestExpression(args: string[], _shell: Shell): boolean {
  if (args.length === 0)
    return false

  // Handle simple string comparisons
  if (args.length === 3 && args[1] === '=') {
    return args[0] === args[2]
  }

  if (args.length === 3 && args[1] === '!=') {
    return args[0] !== args[2]
  }

  // Handle numeric comparisons
  if (args.length === 3 && args[1] === '-eq') {
    return Number.parseInt(args[0], 10) === Number.parseInt(args[2], 10)
  }

  if (args.length === 3 && args[1] === '-ne') {
    return Number.parseInt(args[0], 10) !== Number.parseInt(args[2], 10)
  }

  // Handle file tests
  if (args.length === 2 && args[0] === '-f') {
    try {
      return fs.statSync(args[1]).isFile()
    }
    catch {
      return false
    }
  }

  if (args.length === 2 && args[0] === '-d') {
    try {
      return fs.statSync(args[1]).isDirectory()
    }
    catch {
      return false
    }
  }

  // Handle single argument (test for non-empty string)
  if (args.length === 1) {
    return args[0] !== '' && args[0] !== '0'
  }

  return false
}

export function createScriptBuiltins(): Map<string, BuiltinCommand> {
  const builtins = new Map<string, BuiltinCommand>()

  builtins.set('source', {
    name: 'source',
    description: 'Execute commands from a file in the current shell environment',
    usage: 'source <file> [args...]',
    examples: [
      'source script.sh',
      'source config.sh arg1 arg2',
      '. script.sh',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      if (args.length === 0) {
        return {
          success: false,
          exitCode: 1,
          stdout: '',
          stderr: 'source: missing file argument',
        }
      }

      const scriptManager = new ScriptManager(shell)
      const filePath = args[0]

      // Set positional parameters for the script
      const oldArgs = shell.environment['#'] ? Number.parseInt(shell.environment['#']) : 0
      const oldPositional: string[] = []

      // Save old positional parameters
      for (let i = 1; i <= oldArgs; i++) {
        if (shell.environment[`${i}`]) {
          oldPositional[i - 1] = shell.environment[`${i}`]
        }
      }

      // Set new positional parameters
      shell.environment['#'] = (args.length - 1).toString()
      for (let i = 1; i < args.length; i++) {
        shell.environment[`${i}`] = args[i]
      }

      try {
        const result = await scriptManager.executeScriptFile(filePath)
        return result
      }
      finally {
        // Restore old positional parameters
        shell.environment['#'] = oldArgs.toString()
        for (let i = 1; i <= Math.max(oldArgs, args.length - 1); i++) {
          if (i <= oldPositional.length && oldPositional[i - 1] !== undefined) {
            shell.environment[`${i}`] = oldPositional[i - 1]
          }
          else {
            delete shell.environment[`${i}`]
          }
        }
      }
    },
  })

  // Alias for source
  builtins.set('.', builtins.get('source')!)

  builtins.set('test', {
    name: 'test',
    description: 'Evaluate conditional expressions',
    usage: 'test <expression> or [ <expression> ]',
    examples: [
      'test -f file.txt',
      'test "$var" = "value"',
      '[ -d directory ]',
      '[ "$a" -eq "$b" ]',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      if (args.length === 0) {
        return { success: false, exitCode: 1, stdout: '', stderr: '' }
      }

      // Simple test implementation without recursion
      try {
        const result = evaluateTestExpression(args, shell)
        return {
          success: result,
          exitCode: result ? 0 : 1,
          stdout: '',
          stderr: '',
        }
      }
      catch (error) {
        return {
          success: false,
          exitCode: 2,
          stdout: '',
          stderr: `test: ${error instanceof Error ? error.message : String(error)}`,
        }
      }
    },
  })

  builtins.set('[', {
    name: '[',
    description: 'Evaluate conditional expressions (alias for test)',
    usage: '[ <expression> ]',
    examples: [
      '[ -f file.txt ]',
      '[ "$var" = "value" ]',
      '[ -d directory ]',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      // Remove the closing ] if present
      const filteredArgs = args.filter(arg => arg !== ']')
      const testBuiltin = builtins.get('test')!
      return await testBuiltin.execute(filteredArgs, shell)
    },
  })

  builtins.set('true', {
    name: 'true',
    description: 'Return successful exit status',
    usage: 'true',
    examples: ['true'],
    execute: async (): Promise<CommandResult> => {
      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    },
  })

  builtins.set('false', {
    name: 'false',
    description: 'Return unsuccessful exit status',
    usage: 'false',
    examples: ['false'],
    execute: async (): Promise<CommandResult> => {
      return { success: false, exitCode: 1, stdout: '', stderr: '' }
    },
  })

  builtins.set('return', {
    name: 'return',
    description: 'Return from a function or script',
    usage: 'return [n]',
    examples: [
      'return',
      'return 0',
      'return 1',
    ],
    execute: async (args: string[]): Promise<CommandResult> => {
      const exitCode = args.length > 0 ? Number.parseInt(args[0]) || 0 : 0
      return {
        success: exitCode === 0,
        exitCode,
        stdout: '',
        stderr: '',
        // Special flag to indicate this is a return statement
        metadata: { isReturn: true },
      }
    },
  })

  builtins.set('break', {
    name: 'break',
    description: 'Break out of loops',
    usage: 'break [n]',
    examples: [
      'break',
      'break 2',
    ],
    execute: async (args: string[]): Promise<CommandResult> => {
      const level = args.length > 0 ? Number.parseInt(args[0]) || 1 : 1
      return {
        success: true,
        exitCode: 0,
        stdout: '',
        stderr: '',
        metadata: { isBreak: true, level },
      }
    },
  })

  builtins.set('continue', {
    name: 'continue',
    description: 'Continue to next iteration of loop',
    usage: 'continue [n]',
    examples: [
      'continue',
      'continue 2',
    ],
    execute: async (args: string[]): Promise<CommandResult> => {
      const level = args.length > 0 ? Number.parseInt(args[0]) || 1 : 1
      return {
        success: true,
        exitCode: 0,
        stdout: '',
        stderr: '',
        metadata: { isContinue: true, level },
      }
    },
  })

  builtins.set('local', {
    name: 'local',
    description: 'Create local variables in functions',
    usage: 'local [name[=value] ...]',
    examples: [
      'local var',
      'local var=value',
      'local a=1 b=2',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      // In a real implementation, this would create function-local variables
      // For now, we'll just set them as regular environment variables
      for (const arg of args) {
        if (arg.includes('=')) {
          const [name, value] = arg.split('=', 2)
          shell.environment[name] = value || ''
        }
        else {
          shell.environment[arg] = ''
        }
      }

      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    },
  })

  builtins.set('readonly', {
    name: 'readonly',
    description: 'Mark variables as read-only',
    usage: 'readonly [name[=value] ...]',
    examples: [
      'readonly var',
      'readonly var=value',
      'readonly -p',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      if (args.length === 0 || (args.length === 1 && args[0] === '-p')) {
        // List readonly variables (simplified implementation)
        const readonlyVars = Object.entries(shell.environment)
          .filter(([name]) => name.startsWith('READONLY_'))
          .map(([name, value]) => `readonly ${name.slice(9)}="${value}"`)
          .join('\n')

        return {
          success: true,
          exitCode: 0,
          stdout: readonlyVars,
          stderr: '',
        }
      }

      for (const arg of args) {
        if (arg.includes('=')) {
          const [name, value] = arg.split('=', 2)
          shell.environment[name] = value || ''
          shell.environment[`READONLY_${name}`] = 'true'
        }
        else {
          shell.environment[`READONLY_${arg}`] = 'true'
        }
      }

      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    },
  })

  builtins.set('declare', {
    name: 'declare',
    description: 'Declare variables and give them attributes',
    usage: 'declare [-aAfFgilnrtux] [-p] [name[=value] ...]',
    examples: [
      'declare var',
      'declare -i num=42',
      'declare -r readonly_var=value',
      'declare -p',
    ],
    execute: async (args: string[], shell: Shell): Promise<CommandResult> => {
      let options = ''
      const variables: string[] = []

      for (const arg of args) {
        if (arg.startsWith('-')) {
          options += arg.slice(1)
        }
        else {
          variables.push(arg)
        }
      }

      if (options.includes('p') && variables.length === 0) {
        // List all variables
        const declarations = Object.entries(shell.environment)
          .map(([name, value]) => `declare -- ${name}="${value}"`)
          .join('\n')

        return {
          success: true,
          exitCode: 0,
          stdout: declarations,
          stderr: '',
        }
      }

      for (const variable of variables) {
        if (variable.includes('=')) {
          const [name, value] = variable.split('=', 2)
          shell.environment[name] = value || ''

          if (options.includes('r')) {
            shell.environment[`READONLY_${name}`] = 'true'
          }
        }
        else {
          shell.environment[variable] = ''
        }
      }

      return { success: true, exitCode: 0, stdout: '', stderr: '' }
    },
  })

  return builtins
}
