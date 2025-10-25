import type { BuiltinCommand, Shell } from './types'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { resolve } from 'node:path'

/**
 * CD (Change Directory) command - changes the current working directory
 * Supports tilde expansion, relative paths, and proper error handling
 */
export const cdCommand: BuiltinCommand = {
  name: 'cd',
  description: 'Change the current directory',
  usage: 'cd [directory]',
  async execute(args: string[], shell: Shell): Promise<{ exitCode: number, stdout: string, stderr: string, duration: number }> {
    const start = performance.now()

    // Default to home directory if no argument is provided
    let targetArg = args[0] || '~'

    try {
      // Helper: get directory stack
      const getStack = (): string[] => ((shell as any)._dirStack ?? ((shell as any)._dirStack = [])) as string[]

      // Helper: load bookmarks (shared path with bookmark.ts)
      const loadBookmarks = (): Record<string, string> => {
        try {
          const host = shell as any
          if (host._bookmarks)
            return host._bookmarks as Record<string, string>
          const file = `${homedir()}/.krusty/bookmarks.json`
          if (!existsSync(file))
            return {}
          const raw = readFileSync(file, 'utf8')
          const data = JSON.parse(raw)
          host._bookmarks = (data && typeof data === 'object') ? (data as Record<string, string>) : {}
          return host._bookmarks
        }
        catch {
          return {}
        }
      }

      // Handle `cd -` to jump to previous directory
      if (targetArg === '-') {
        const prev = (shell as any)._prevDir as string | undefined
        if (!prev) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: 'cd: OLDPWD not set\n',
            duration: performance.now() - start,
          }
        }
        const ok = shell.changeDirectory(prev)
        if (!ok) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `cd: ${prev}: No such file or directory\n`,
            duration: performance.now() - start,
          }
        }
        // POSIX shells echo new directory on cd -
        return { exitCode: 0, stdout: `${shell.cwd}\n`, stderr: '', duration: performance.now() - start }
      }

      // Handle `cd -N` to jump to Nth entry in directory stack (Zsh-like)
      if (/^-\d+$/.test(targetArg)) {
        const n = Number.parseInt(targetArg.slice(1), 10)
        if (n <= 0)
          return { exitCode: 2, stdout: '', stderr: `cd: invalid stack index: ${targetArg}\n`, duration: performance.now() - start }
        const stack = getStack()
        const idx = n - 1
        const target = stack[idx]
        if (!target)
          return { exitCode: 1, stdout: '', stderr: `cd: ${targetArg}: no such entry in dir stack\n`, duration: performance.now() - start }
        const prev = shell.cwd
        const ok = shell.changeDirectory(target)
        if (!ok)
          return { exitCode: 1, stdout: '', stderr: `cd: ${target}: No such file or directory\n`, duration: performance.now() - start }
        // Move selected target out of stack and push previous cwd to front
        stack.splice(idx, 1)
        stack.unshift(prev)
        return { exitCode: 0, stdout: '', stderr: '', duration: performance.now() - start }
      }

      // Handle bookmark navigation: cd :name
      if (targetArg.startsWith(':') && targetArg.length > 1) {
        const name = targetArg.slice(1)
        const bookmarks = loadBookmarks()
        const dir = bookmarks[name]
        if (!dir) {
          return { exitCode: 1, stdout: '', stderr: `cd: bookmark :${name} not found\n`, duration: performance.now() - start }
        }
        targetArg = dir
      }

      // Handle tilde expansion for home directory
      let targetDir = targetArg.startsWith('~')
        ? targetArg.replace('~', homedir())
        : targetArg

      // Resolve relative paths against current working directory
      if (!targetDir.startsWith('/')) {
        targetDir = resolve(shell.cwd, targetDir)
      }
      else {
        // For absolute paths, resolve to handle any '..' or '.'
        targetDir = resolve(targetDir)
      }

      // Check if target exists
      if (!existsSync(targetDir)) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `cd: ${targetArg}: No such file or directory\n`,
          duration: performance.now() - start,
        }
      }

      // Verify it's actually a directory
      const stat = statSync(targetDir)
      if (!stat.isDirectory()) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `cd: ${targetArg}: Not a directory\n`,
          duration: performance.now() - start,
        }
      }

      // Attempt to change directory using shell's method
      const success = shell.changeDirectory(targetDir)

      if (!success) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `cd: ${targetArg}: Permission denied\n`,
          duration: performance.now() - start,
        }
      }

      return {
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `cd: ${error instanceof Error ? error.message : 'Failed to change directory'}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
