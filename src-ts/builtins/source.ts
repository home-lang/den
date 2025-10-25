import type { BuiltinCommand, CommandResult, Shell } from './types'
import process from 'node:process'

/**
 * Source command - executes commands from a file in the current shell context
 * This is a core shell builtin that allows for script execution
 */
export const sourceCommand: BuiltinCommand = {
  name: 'source',
  description: 'Execute commands from a file in the current shell context',
  usage: 'source file [arguments...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Validate arguments
    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'source: filename argument required\nsource: usage: source filename [arguments]\n',
        duration: performance.now() - start,
      }
    }

    const filePath = args[0]
    const scriptArgs = args.slice(1)
    let fullPath: string | null = null

    // Lazy load dependencies
    const fs = await import('node:fs/promises')
    const path = await import('node:path')

    try {
      // Resolve the file path
      if (path.isAbsolute(filePath) || filePath.startsWith('./') || filePath.startsWith('../')) {
        fullPath = path.resolve(shell.cwd, filePath)
      }
      else {
        // Search in PATH if not a relative/absolute path
        const pathDirs = (shell.environment.PATH || process.env.PATH || '').split(path.delimiter)
        for (const dir of pathDirs) {
          if (!dir)
            continue // Skip empty PATH entries

          const testPath = path.join(dir, filePath)
          try {
            await fs.access(testPath)
            fullPath = testPath
            break
          }
          catch {
            continue
          }
        }
      }

      if (!fullPath) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `source: ${filePath}: file not found in PATH\n`,
          duration: performance.now() - start,
        }
      }

      // Verify the file is not a directory
      const stats = await fs.stat(fullPath)
      if (stats.isDirectory()) {
        return {
          exitCode: 1,
          stdout: '',
          stderr: `source: ${filePath}: is a directory\n`,
          duration: performance.now() - start,
        }
      }

      // Read the file content
      const content = await fs.readFile(fullPath, 'utf8')

      // Save current args and set the script arguments
      const originalArgs = process.argv.slice(2)
      process.argv = [process.argv[0], fullPath, ...scriptArgs]

      try {
        // Execute each non-empty, non-comment line
        const lines = content.split('\n')
        let lastResult: CommandResult = {
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: 0,
        }

        for (const line of lines) {
          const trimmed = line.trim()

          // Skip comments and empty lines
          if (!trimmed || trimmed.startsWith('#')) {
            continue
          }

          // Execute the command
          const result = await shell.execute(trimmed)
          lastResult = {
            ...result,
            // Accumulate output for better error reporting
            stdout: lastResult.stdout + (result.stdout || ''),
            stderr: lastResult.stderr + (result.stderr || ''),
          }

          // Stop on error if we're not in a script
          if (result.exitCode !== 0) {
            break
          }
        }

        return {
          ...lastResult,
          duration: performance.now() - start,
        }
      }
      finally {
        // Restore original args
        process.argv = [process.argv[0], ...originalArgs]
      }
    }
    catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `source: ${error instanceof Error ? error.message : 'Error executing file'}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
