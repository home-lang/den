import type { CommandResult, Shell } from '../types'
import { ScriptExecutor } from './script-executor'
import { ScriptParser } from './script-parser'

export class ScriptManager {
  private parser = new ScriptParser()
  private executor = new ScriptExecutor()
  private shell: Shell

  constructor(shell: Shell) {
    this.shell = shell
  }

  async executeScript(input: string, options: {
    exitOnError?: boolean
    isFile?: boolean
  } = {}): Promise<CommandResult> {
    try {
      // Check if this looks like a script (contains control flow keywords)
      if (!this.isScript(input) && !options.isFile) {
        // Not a script, parse and execute directly without going through shell.execute to avoid recursion
        const parsed = await this.shell.parseCommand(input)
        if (parsed.commands.length === 0) {
          return { exitCode: 0, stdout: '', stderr: '', success: true }
        }
        // Execute the command chain directly
        return await (this.shell as any).executeCommandChain(parsed)
      }

      const script = await this.parser.parseScript(input, this.shell)
      return await this.executor.executeScript(script, this.shell, {
        exitOnError: options.exitOnError,
      })
    }
    catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      return {
        success: false,
        exitCode: 1,
        stdout: '',
        stderr: `Script execution error: ${errorMsg}`,
      }
    }
  }

  async executeScriptFile(filePath: string, options: { exitOnError?: boolean } = {}): Promise<CommandResult> {
    try {
      const fs = await import('node:fs/promises')
      const content = await fs.readFile(filePath, 'utf-8')
      return await this.executeScript(content, { ...options, isFile: true })
    }
    catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error)
      return {
        success: false,
        exitCode: 1,
        stdout: '',
        stderr: `Failed to read script file: ${errorMsg}`,
      }
    }
  }

  isScript(input: string): boolean {
    // Quick checks for clear starters
    const starters = [/^\s*if\b/, /^\s*for\b/, /^\s*while\b/, /^\s*until\b/, /^\s*case\b/, /^\s*function\b/, /\b\w+\s*\(\)\s*\{/]
    if (starters.some(r => r.test(input)))
      return true

    // Token-aware checks per line to avoid matching substrings like 'fi' in 'printf'
    const lines = input.split('\n')
    for (const raw of lines) {
      const line = raw.trim()
      if (!line)
        continue
      // Normalize separators as tokens
      const tokens = line.split(/\s+|;/).filter(Boolean)
      const has = (w: string) => tokens.includes(w)

      // if/then/elif/else/fi constructs
      if (has('then') || has('elif') || has('else') || has('fi'))
        return true

      // loop/do/done (require standalone tokens)
      if ((has('do') && (has('for') || has('while') || has('until'))) || has('done'))
        return true

      // case/esac constructs; 'in' is only meaningful with case/for, don't match standalone 'in'
      if (has('case') || has('esac'))
        return true

      // function { ... } style on same line
      if (/\bfunction\b/.test(line) || /\b\w+\s*\(\)\s*\{/.test(line))
        return true
    }

    return false
  }

  isScriptKeyword(word: string): boolean {
    const keywords = new Set([
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
      'return',
      'break',
      'continue',
      'local',
      'set',
    ])
    return keywords.has(word)
  }
}
