import type { BuiltinCommand, CommandResult, Shell } from './types'
import { access, stat } from 'node:fs/promises'
import process from 'node:process'

/**
 * Test command - evaluate conditional expressions
 * Implements the POSIX test command functionality
 */
export const testCommand: BuiltinCommand = {
  name: 'test',
  description: 'Evaluate conditional expressions',
  usage: 'test [expression]',
  async execute(args: string[], _shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Handle empty arguments
    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }

    // Handle the [ ] syntax (last argument should be ']')
    if (args[0] === '[') {
      if (args[args.length - 1] !== ']') {
        return {
          exitCode: 2,
          stdout: '',
          stderr: 'test: missing `]\'\n',
          duration: performance.now() - start,
        }
      }
      args = args.slice(1, -1) // Remove [ and ]
    }

    // Helper function to evaluate a test expression
    const evaluateTest = async (tokens: string[]): Promise<{ result: boolean, consumed: number }> => {
      if (tokens.length === 0) {
        return { result: false, consumed: 0 }
      }

      let pos = 0

      // Helper to get next token
      const next = () => tokens[pos++]
      const peek = () => tokens[pos]
      const eof = () => pos >= tokens.length

      // Parse a primary expression
      async function parsePrimary(): Promise<boolean> {
        const token = next()

        // Handle unary operators
        if (token === '!') {
          return !(await parsePrimary())
        }

        if (token === '(') {
          const result = await parseOr()
          if (next() !== ')') {
            throw new Error('syntax error: missing `)\'\n')
          }
          return result
        }

        // Handle string tests
        if (token === '-n') {
          return next().length > 0
        }

        if (token === '-z') {
          return next().length === 0
        }

        // Handle file tests
        if (token.startsWith('-')) {
          const arg = next()
          if (arg === undefined) {
            throw new Error(`test: ${token}: argument expected\n`)
          }

          try {
            const stats = await stat(arg)

            switch (token) {
              case '-b': return stats.isBlockDevice()
              case '-c': return stats.isCharacterDevice()
              case '-d': return stats.isDirectory()
              case '-e': return true
              case '-f': return stats.isFile()
              case '-g': return (stats.mode & 0o2000) !== 0 // setgid bit
              case '-G': return stats.gid === process.getgid?.()
              case '-h':
              case '-L': return stats.isSymbolicLink()
              case '-k': return (stats.mode & 0o100) !== 0 // sticky bit
              case '-O': return stats.uid === process.getuid?.()
              case '-p': return stats.isFIFO()
              case '-r': {
                try {
                  await access(arg, 0o400) // Readable by user
                  return true
                }
                catch {
                  return false
                }
              }
              case '-s': return stats.size > 0
              case '-S': return stats.isSocket()
              case '-t': return process.stdin.isTTY
              case '-u': return (stats.mode & 0o4000) !== 0 // setuid bit
              case '-w': {
                try {
                  await access(arg, 0o200) // Writable by user
                  return true
                }
                catch {
                  return false
                }
              }
              case '-x': {
                try {
                  await access(arg, 0o100) // Executable by user
                  return true
                }
                catch {
                  return false
                }
              }
              default:
                throw new Error(`test: ${token}: unary operator expected\n`)
            }
          }
          catch (error: any) {
            if (error.code === 'ENOENT') {
              return false
            }
            throw error
          }
        }

        // Handle string comparisons
        const nextToken = peek()

        if (nextToken === '=') {
          next() // consume '='
          return token === next()
        }

        if (nextToken === '!=') {
          next() // consume '!='
          return token !== next()
        }

        // Handle numeric comparisons
        if (nextToken === '-eq') {
          next() // consume '-eq'
          return Number(token) === Number(next())
        }

        if (nextToken === '-ne') {
          next() // consume '-ne'
          return Number(token) !== Number(next())
        }

        if (nextToken === '-lt') {
          next() // consume '-lt'
          return Number(token) < Number(next())
        }

        if (nextToken === '-le') {
          next() // consume '-le'
          return Number(token) <= Number(next())
        }

        if (nextToken === '-gt') {
          next() // consume '-gt'
          return Number(token) > Number(next())
        }

        if (nextToken === '-ge') {
          next() // consume '-ge'
          return Number(token) >= Number(next())
        }

        // If we get here, it's just a string
        return token.length > 0
      }

      // Parse AND expressions
      async function parseAnd(): Promise<boolean> {
        let result = await parsePrimary()

        while (!eof() && peek() === '-a') {
          next() // consume '-a'
          result = result && (await parsePrimary())
        }

        return result
      }

      // Parse OR expressions
      async function parseOr(): Promise<boolean> {
        let result = await parseAnd()

        while (!eof() && peek() === '-o') {
          next() // consume '-o'
          result = result || (await parseAnd())
        }

        return result
      }

      const result = await parseOr()
      return { result, consumed: pos }
    }

    try {
      const { result, consumed } = await evaluateTest(args)

      // Check if we consumed all tokens
      if (consumed < args.length) {
        return {
          exitCode: 2,
          stdout: '',
          stderr: `test: too many arguments\n`,
          duration: performance.now() - start,
        }
      }

      return {
        exitCode: result ? 0 : 1,
        stdout: '',
        stderr: '',
        duration: performance.now() - start,
      }
    }
    catch (error) {
      return {
        exitCode: 2,
        stdout: '',
        stderr: `test: ${(error as Error).message}`,
        duration: performance.now() - start,
      }
    }
  },
}
