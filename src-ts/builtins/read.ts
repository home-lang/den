import type { BuiltinCommand, CommandResult, Shell } from './types'
import process from 'node:process'

/**
 * Read command - read a line from input and assign to variables
 * Supports various options for reading input and controlling behavior
 */
export const readCommand: BuiltinCommand = {
  name: 'read',
  description: 'Read a line from standard input',
  usage: 'read [-ers] [-a array] [-d delim] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [name ...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()

    // Default options
    const options = {
      arrayName: '',
      delimiter: '\n',
      escape: false,
      silent: false,
      prompt: '',
      timeout: 0,
      nchars: 0,
      ncharsExact: 0,
    }

    const vars: string[] = []

    // Parse options
    while (args[0]?.startsWith('-')) {
      const arg = args.shift()!
      if (arg === '--')
        break

      if (arg === '-a') {
        // Array option
        options.arrayName = args.shift() || ''
        if (!options.arrayName) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: 'read: -a: option requires an argument\n',
            duration: performance.now() - start,
          }
        }
      }
      else if (arg === '-d') {
        // Delimiter option
        const delim = args.shift()
        if (delim === undefined) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: 'read: -d: option requires an argument\n',
            duration: performance.now() - start,
          }
        }
        options.delimiter = delim
      }
      else if (arg === '-e') {
        // Enable readline
        // Not fully implemented - would use readline if available
      }
      else if (arg === '-i') {
        // Initial text (not in POSIX)
        // Skip the initial text argument
        args.shift()
      }
      else if (arg === '-n') {
        // Read nchars characters
        const n = Number.parseInt(args.shift() || '0', 10)
        if (Number.isNaN(n) || n < 0) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `read: ${n}: invalid number of characters\n`,
            duration: performance.now() - start,
          }
        }
        options.nchars = n
      }
      else if (arg === '-N') {
        // Read exactly nchars characters
        const n = Number.parseInt(args.shift() || '0', 10)
        if (Number.isNaN(n) || n < 0) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `read: ${n}: invalid number of characters\n`,
            duration: performance.now() - start,
          }
        }
        options.ncharsExact = n
      }
      else if (arg === '-p') {
        // Prompt
        options.prompt = args.shift() || ''
      }
      else if (arg === '-r') {
        // Raw mode - don't treat backslashes specially
        options.escape = false
      }
      else if (arg === '-s') {
        // Silent mode - don't echo input
        options.silent = true
      }
      else if (arg === '-t') {
        // Timeout
        const timeout = Number.parseFloat(args.shift() || '0')
        if (Number.isNaN(timeout) || timeout < 0) {
          return {
            exitCode: 1,
            stdout: '',
            stderr: `read: ${timeout}: invalid timeout specification\n`,
            duration: performance.now() - start,
          }
        }
        options.timeout = timeout * 1000 // Convert to milliseconds
      }
      else if (arg === '-u') {
        // Read from file descriptor (not implemented)
        args.shift() // Skip the fd
      }
      else if (!arg.startsWith('-')) {
        // Not an option
        break
      }
      else {
        // Unknown option
        return {
          exitCode: 1,
          stdout: '',
          stderr: `read: ${arg}: invalid option\n`,
          duration: performance.now() - start,
        }
      }
    }

    // Remaining arguments are variable names
    while (args.length > 0) {
      const arg = args.shift()!
      if (arg === '--')
        break
      vars.push(arg)
    }

    if (shell.config.verbose)
      shell.log.debug('[read] options=%o vars=%o', options, vars)

    // In a real implementation, we would read from stdin
    // For now, we'll simulate reading a line
    let input = ''

    try {
      // Show prompt if provided
      if (options.prompt) {
        process.stdout.write(options.prompt)
      }

      // Read input (simplified for this implementation)
      // In a real implementation, this would use readline or similar
      if (options.silent) {
        // Hide input (for passwords, etc.)
        const readline = await import('node:readline')
        const rl = readline.createInterface({
          input: process.stdin,
          output: process.stdout,
        })

        const readLine = () => new Promise<string>((resolve) => {
          const onData = (char: string) => {
            if (char === '\n' || char === '\r' || char === '\u0004') {
              try {
                if (typeof (process.stdin as any).setRawMode === 'function' && (process.stdin as any).isTTY)
                  (process.stdin as any).setRawMode(false)
              }
              catch {}
              process.stdin.off('data', onData)
              rl.close()
              resolve(input)
              return
            }

            // Handle backspace/delete
            if (char === '\b' || char === '\x7F') {
              if (input.length > 0) {
                input = input.slice(0, -1)
              }
              return
            }

            // Add character to input
            input += char
          }
          try {
            if (typeof (process.stdin as any).setRawMode === 'function' && (process.stdin as any).isTTY)
              (process.stdin as any).setRawMode(true)
          }
          catch {}
          process.stdin.on('data', onData)
        })

        input = await readLine()
      }
      else {
        // Normal input
        const readline = await import('node:readline')
        const rl = readline.createInterface({
          input: process.stdin,
          output: process.stdout,
        })

        input = await new Promise<string>((resolve) => {
          rl.question(options.prompt, (answer) => {
            rl.close()
            resolve(answer)
          })
        })
      }

      // Process input based on options
      if (options.nchars > 0 && input.length > options.nchars) {
        input = input.slice(0, options.nchars)
      }
      else if (options.ncharsExact > 0) {
        input = input.padEnd(options.ncharsExact, '\0').slice(0, options.ncharsExact)
      }

      // Split input into fields based on IFS
      const IFS = shell.environment.IFS || ' \t\n'
      // Split the input into fields
      const fields: string[] = []
      let currentField = ''
      let inQuotes = false
      let escapeNext = false

      for (let i = 0; i < input.length; i++) {
        const char = input[i]

        if (escapeNext) {
          currentField += char
          escapeNext = false
          continue
        }

        if (options.escape && char === '\\') {
          escapeNext = true
          continue
        }

        if (char === '"' || char === '\'') {
          inQuotes = !inQuotes
          continue
        }

        if (!inQuotes && IFS.includes(char)) {
          if (currentField !== '' || !fields.length) {
            fields.push(currentField)
            currentField = ''
          }
          continue
        }

        currentField += char
      }

      // Add the last field if not empty or if we had no fields yet
      if (currentField !== '' || !fields.length) {
        fields.push(currentField)
      }

      if (shell.config.verbose)
        shell.log.debug('[read] input_length=%d', input.length)

      // Assign to variables
      if (options.arrayName) {
        // Assign to array
        shell.environment[options.arrayName] = fields.join(' ')
      }
      else if (vars.length > 0) {
        // Assign to named variables
        for (let i = 0; i < vars.length; i++) {
          const varName = vars[i]
          if (i < fields.length) {
            shell.environment[varName] = fields[i]
          }
          else if (i === fields.length) {
            // Last variable gets all remaining fields
            shell.environment[varName] = fields.slice(i).join(' ')
            break
          }
          else {
            // No more fields, set to empty string
            shell.environment[varName] = ''
          }
        }
      }
      else {
        // Default to REPLY variable
        shell.environment.REPLY = fields.join(' ')
      }

      if (shell.config.verbose)
        shell.log.debug('[read] fields=%d -> assigned vars=%o', fields.length, vars.length ? vars : ['REPLY'])

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
        stderr: `read: ${(error as Error).message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}
