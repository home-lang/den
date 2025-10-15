import type { CommandResult, Shell } from '../types'
import { ScriptManager } from '../scripting/script-manager'

export class ScriptExecutor {
  private scriptManager: ScriptManager
  private shell: Shell

  constructor(shell: Shell) {
    this.shell = shell
    this.scriptManager = new ScriptManager(shell)
  }

  isScript(command: string): boolean {
    return this.scriptManager.isScript(command)
  }

  async executeScript(command: string, options?: { isFile?: boolean }): Promise<CommandResult> {
    return this.scriptManager.executeScript(command, options)
  }

  /**
   * Build styled echo for package.json script runs (bun/npm/pnpm/yarn)
   * Expands nested script references recursively with cycle protection.
   */
  async buildPackageRunEcho(command: any, includeNested: boolean = false): Promise<string | null> {
    try {
      const name = (command?.name || '').toLowerCase()
      const args: string[] = Array.isArray(command?.args) ? command.args : []

      // Detect package manager script invocation and extract script name
      let scriptName: string | null = null
      if (name === 'bun' && args[0] === 'run' && args[1]) {
        scriptName = args[1]
      }
      else if (name === 'npm' && (args[0] === 'run' || args[0] === 'run-script') && args[1]) {
        scriptName = args[1]
      }
      else if (name === 'pnpm' && args[0] === 'run' && args[1]) {
        scriptName = args[1]
      }
      else if (name === 'yarn') {
        // yarn <script> OR yarn run <script>
        if (args[0] === 'run' && args[1])
          scriptName = args[1]
        else if (args[0])
          scriptName = args[0]
      }

      if (!scriptName)
        return null

      // Read package.json scripts from current working directory
      const { resolve } = await import('node:path')
      const { existsSync } = await import('node:fs')

      const pkgPath = resolve((this.shell as any).cwd, 'package.json')
      if (!existsSync(pkgPath))
        return null

      let scripts: Record<string, string> | undefined
      try {
        const { readFileSync } = await import('node:fs')
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8')) as { scripts?: Record<string, string> }
        scripts = pkg.scripts || {}
      }
      catch {
        return null
      }
      if (!scripts || !scripts[scriptName])
        return null

      // Styling consistent with bb builtin
      const purple = '\x1B[38;2;199;146;234m'
      const dim = '\x1B[2m'
      const reset = '\x1B[0m'
      const styleEcho = (line: string) => `${purple}$${reset} ${dim}${line}${reset}`

      // First line: echo the invoked command as typed/raw
      const asTyped = (command?.raw && typeof command.raw === 'string')
        ? command.raw
        : [command.name, ...(command.args || [])].join(' ')

      const lines: string[] = [styleEcho(asTyped)]

      // Only include nested expansion when explicitly requested (i.e., when buffering output)
      if (includeNested) {
        const visited = new Set<string>()
        const maxDepth = 5
        const runRegex = /\b(?:bun|npm|pnpm|yarn)\s+(?:run\s+)?([\w:\-]+)/g
        const expand = (scr: string, depth: number) => {
          if (!scripts || !scripts[scr] || visited.has(scr) || depth > maxDepth)
            return
          visited.add(scr)
          const body = scripts[scr]
          lines.push(styleEcho(body))
          // Find nested script references
          let m: RegExpExecArray | null
          runRegex.lastIndex = 0
          // eslint-disable-next-line no-cond-assign
          while ((m = runRegex.exec(body)) !== null) {
            const nextScr = m[1]
            if (nextScr && scripts[nextScr])
              expand(nextScr, depth + 1)
          }
        }
        expand(scriptName, 1)
      }

      return `${lines.join('\n')}\n`
    }
    catch {
      return null
    }
  }
}
