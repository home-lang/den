import type { BuiltinCommand, CommandResult, Shell } from './types'
import { access, constants } from 'node:fs/promises'
import { delimiter, join } from 'node:path'
import { config } from '../config'

/**
 * Which command - shows the full path of commands
 * Searches through PATH to find the executable
 */
export const whichCommand: BuiltinCommand = {
  name: 'which',
  description: 'Show the full path of commands',
  usage: 'which [command...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'which: missing command name\n',
        duration: performance.now() - start,
      }
    }

    const pathDirs = (shell.environment.PATH || '').split(delimiter)
    // Merge aliases from config and runtime shell; runtime takes precedence
    const mergedAliases: Record<string, string> = {
      ...(config.aliases || {}),
      ...(shell.aliases || {}),
    }
    const results: string[] = []
    const notFound: string[] = []

    for (const cmd of args) {
      // Skip empty arguments
      if (!cmd.trim())
        continue

      // Check if it's a builtin command
      if (shell.builtins.has(cmd)) {
        // Friendly alias-like descriptions for select builtins
        const builtinAliases: Record<string, string> = {
          b: 'bun run build',
          bb: 'bun run build',
          bd: 'bun run dev',
          bi: 'bun install',
          bl: 'bun run lint',
          br: 'bun run <script>',
          // bf intentionally left generic due to multiple fallbacks
        }

        if (builtinAliases[cmd]) {
          results.push(`${cmd}: aliased to ${builtinAliases[cmd]}`)
        }
        else if (cmd === 'bf') {
          results.push(`${cmd}: aliased to format (pkg script | pickier . --fix)`) // informative
        }
        else {
          results.push(`${cmd}: shell built-in command`)
        }
        continue
      }

      // Check if it's an alias (from runtime or config)
      if (mergedAliases[cmd]) {
        results.push(`${cmd}: aliased to ${mergedAliases[cmd]}`)
        continue
      }

      // Check if it's an absolute or relative path
      if (cmd.includes('/')) {
        try {
          await access(cmd, constants.X_OK)
          results.push(cmd)
        }
        catch {
          notFound.push(cmd)
        }
        continue
      }

      // Search in PATH
      let found = false
      for (const dir of pathDirs) {
        if (!dir)
          continue // Skip empty PATH entries

        const fullPath = join(dir, cmd)
        try {
          await access(fullPath, constants.X_OK)
          results.push(fullPath)
          found = true
          break
        }
        catch {
          // Command not found in this directory
          continue
        }
      }

      if (!found) {
        notFound.push(cmd)
      }
    }

    // Prepare output
    let stdout = ''
    let stderr = ''

    if (results.length > 0) {
      stdout = `${results.join('\n')}\n`
      // Add a newline between found and not found if both exist
      if (notFound.length > 0) {
        stdout += '\n'
        // Add a newline if there are multiple not found
        if (notFound.length > 1) {
          stderr = `${notFound.map(cmd => `which: no ${cmd} in (${pathDirs.join(':')})`).join('\n')}\n`
          // Add a newline between not found and found if both exist
          if (results.length > 0) {
            stderr = `\n${stderr}`
          }
        }
        else {
          stderr = `which: no ${notFound[0]} in (${pathDirs.join(':')})\n`
        }
      }
    }
    else if (notFound.length > 0) {
      if (notFound.length > 1) {
        stderr = `${notFound.map(cmd => `which: no ${cmd} in (${pathDirs.join(':')})`).join('\n')}\n`
        // Add a newline between not found and found if both exist
        if (results.length > 0) {
          stderr = `\n${stderr}`
        }
      }
      else {
        stderr = `which: no ${notFound[0]} in (${pathDirs.join(':')})\n`
      }
    }

    return {
      exitCode: notFound.length > 0 ? 1 : 0,
      stdout,
      stderr,
      duration: performance.now() - start,
    }
  },
}
