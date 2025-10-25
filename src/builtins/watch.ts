import { spawn } from 'node:child_process'
import type { BuiltinCommand } from './types'

export const watch: BuiltinCommand = {
  name: 'watch',
  description: 'Execute a command repeatedly and show output',
  usage: 'watch [options] command',
  async execute(shell, args) {
    if (args.includes('--help') || args.includes('-h') || args.length === 0) {
      shell.output(`Usage: watch [options] command

Execute a command repeatedly and display its output.

Options:
  -n SECONDS    Update interval in seconds (default: 2)
  -d           Highlight differences between updates
  -t           Turn off header showing interval, command, and current time
  -b           Beep if command has a non-zero exit
  -e           Exit when command has a non-zero exit
  -c           Interpret ANSI color sequences
  -x           Pass command to shell instead of exec

Examples:
  watch date                    Watch the current time
  watch -n 1 ps aux             Update every second
  watch 'df -h'                 Watch disk usage
  watch -d ls -la               Highlight changes in directory listing

Press Ctrl+C to exit.
`)
      return { success: true, exitCode: 0 }
    }

    const options = parseWatchOptions(args)
    const command = args.slice(options.argOffset).join(' ')

    if (!command) {
      shell.error('watch: no command specified')
      return { success: false, exitCode: 1 }
    }

    return await runWatch(shell, command, options)
  },
}

interface WatchOptions {
  interval: number
  differences: boolean
  noTitle: boolean
  beep: boolean
  exitOnError: boolean
  color: boolean
  exec: boolean
  argOffset: number
}

function parseWatchOptions(args: string[]): WatchOptions {
  const options: WatchOptions = {
    interval: 2,
    differences: false,
    noTitle: false,
    beep: false,
    exitOnError: false,
    color: false,
    exec: false,
    argOffset: 0,
  }

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]

    if (!arg.startsWith('-')) {
      options.argOffset = i
      break
    }

    switch (arg) {
      case '-n':
        options.interval = parseInt(args[++i], 10) || 2
        break
      case '-d':
        options.differences = true
        break
      case '-t':
        options.noTitle = true
        break
      case '-b':
        options.beep = true
        break
      case '-e':
        options.exitOnError = true
        break
      case '-c':
        options.color = true
        break
      case '-x':
        options.exec = true
        break
      default:
        if (arg.startsWith('-n')) {
          // Handle -n2 format
          const interval = parseInt(arg.slice(2), 10)
          if (!isNaN(interval)) {
            options.interval = interval
          }
        } else {
          options.argOffset = i
          break
        }
    }
  }

  return options
}

async function runWatch(shell: any, command: string, options: WatchOptions): Promise<any> {
  let previousOutput = ''
  let iteration = 0

  // Clear screen
  if (!options.noTitle) {
    shell.output('\x1b[2J\x1b[H')
  }

  return new Promise((resolve) => {
    const runCommand = async () => {
      const startTime = new Date()

      try {
        const result = await executeCommand(command, options)

        // Clear screen and show header
        if (!options.noTitle) {
          shell.output('\x1b[2J\x1b[H')
          const timestamp = startTime.toISOString().replace('T', ' ').slice(0, 19)
          shell.output(`Every ${options.interval}s: ${command}    ${timestamp}`)
          shell.output('')
        }

        let output = result.output

        // Highlight differences if requested
        if (options.differences && previousOutput && output !== previousOutput) {
          output = highlightDifferences(previousOutput, output)
        }

        // Handle ANSI colors
        if (!options.color) {
          output = output.replace(/\x1b\[[0-9;]*m/g, '')
        }

        shell.output(output)
        previousOutput = result.output

        // Beep on error
        if (options.beep && result.exitCode !== 0) {
          shell.output('\x07') // Bell character
        }

        // Exit on error if requested
        if (options.exitOnError && result.exitCode !== 0) {
          shell.error(`Command exited with code ${result.exitCode}`)
          resolve({ success: false, exitCode: result.exitCode })
          return
        }

        iteration++
      } catch (error) {
        shell.error(`watch: ${error.message}`)
        if (options.exitOnError) {
          resolve({ success: false, exitCode: 1 })
          return
        }
      }

      // Schedule next execution
      setTimeout(runCommand, options.interval * 1000)
    }

    // Handle Ctrl+C
    const handleInterrupt = () => {
      shell.output('\n\nWatch interrupted.')
      resolve({ success: true, exitCode: 0 })
    }

    process.on('SIGINT', handleInterrupt)

    // Start watching
    runCommand()
  })
}

async function executeCommand(command: string, options: WatchOptions): Promise<{ output: string; exitCode: number }> {
  return new Promise((resolve) => {
    const args = options.exec ? ['-c', command] : command.split(' ')
    const cmd = options.exec ? '/bin/sh' : args[0]
    const cmdArgs = options.exec ? args : args.slice(1)

    const child = spawn(cmd, cmdArgs, {
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''

    child.stdout?.on('data', (data) => {
      stdout += data.toString()
    })

    child.stderr?.on('data', (data) => {
      stderr += data.toString()
    })

    child.on('close', (code) => {
      const output = stdout + (stderr ? `\nSTDERR:\n${stderr}` : '')
      resolve({ output, exitCode: code || 0 })
    })

    child.on('error', (error) => {
      resolve({ output: `Error: ${error.message}`, exitCode: 1 })
    })
  })
}

function highlightDifferences(previous: string, current: string): string {
  const prevLines = previous.split('\n')
  const currLines = current.split('\n')
  const result: string[] = []

  const maxLines = Math.max(prevLines.length, currLines.length)

  for (let i = 0; i < maxLines; i++) {
    const prevLine = prevLines[i] || ''
    const currLine = currLines[i] || ''

    if (prevLine !== currLine) {
      // Highlight the entire line that changed
      result.push(`\x1b[7m${currLine}\x1b[0m`) // Reverse video
    } else {
      result.push(currLine)
    }
  }

  return result.join('\n')
}