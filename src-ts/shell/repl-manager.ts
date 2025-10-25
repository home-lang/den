import type { AutoSuggestInput } from '../input/auto-suggest'
import type { Logger } from '../logger'
import type { Shell } from '../types'
import process from 'node:process'

export class ReplManager {
  private shell: Shell
  private autoSuggestInput: AutoSuggestInput
  private log: Logger
  private running = false
  private interactiveSession = false

  constructor(shell: Shell, autoSuggestInput: AutoSuggestInput, log: Logger) {
    this.shell = shell
    this.autoSuggestInput = autoSuggestInput
    this.log = log
  }

  async start(interactive: boolean = true): Promise<void> {
    if (this.running)
      return

    // Skip any interactive/session setup during tests or when explicitly disabled
    if (!interactive || process.env.NODE_ENV === 'test' || process.env.BUN_ENV === 'test') {
      this.running = false
      this.interactiveSession = false
      return
    }

    this.running = true
    this.interactiveSession = true

    try {
      // Main REPL loop
      while (this.running) {
        try {
          const loopIteration = async () => {
            const prompt = await this.shell.renderPrompt()

            // Let readLine handle the prompt display to avoid duplicates
            try {
              if (process.env.KRUSTY_DEBUG) {
                process.stderr.write('[krusty] calling readLine with prompt\n')
              }
            }
            catch {}
            const input = await this.readLine(prompt)

            if (input === null) {
              // EOF (Ctrl+D)
              this.running = false
              return
            }

            if (input.trim()) {
              const result = await this.shell.execute(input)

              // Record completion status for prompt rendering
              try {
                ;(this.shell as any).lastExitCode = typeof result.exitCode === 'number' ? result.exitCode : (this.shell as any).lastExitCode
                ;(this.shell as any).lastCommandDurationMs = typeof result.duration === 'number' ? result.duration : 0
              }
              catch {}

              // A more robust way to print output and errors, ensuring proper newlines.
              if (!result.streamed) {
                // Move to a new line after the user's input.
                process.stdout.write('\n');

                if (result.stdout) {
                  process.stdout.write(result.stdout);
                  if (!result.stdout.endsWith('\n')) {
                    process.stdout.write('\n');
                  }
                }

                if (result.stderr) {
                  const colors = this.shell.getThemeManager().getColors();
                  const errorColor = colors.error || 'red';
                  const colorCode = errorColor === 'red' ? '\u001B[31m' : '\u001B[39m'; // Default to no color
                  const resetCode = '\u001B[0m';

                  const coloredError = `${colorCode}${result.stderr}${resetCode}`;
                  process.stderr.write(coloredError);
                  if (!result.stderr.endsWith('\n')) {
                    process.stderr.write('\n');
                  }
                }
              }
            }
          }

          await loopIteration()
        }
        catch (error) {
          this.log.error('Shell error:', error)
          if (error instanceof Error && error.message.includes('readline was closed')) {
            break
          }
        }
      }
    }
    catch (error) {
      this.log.error('Fatal shell error:', error)
    }
    finally {
      this.interactiveSession = false
      this.stop()
    }
  }

  stop(): void {
    this.running = false
    this.interactiveSession = false
  }

  isRunning(): boolean {
    return this.running
  }

  isInteractiveSession(): boolean {
    return this.interactiveSession
  }

  private async readLine(prompt: string): Promise<string | null> {
    // For tests, bypass AutoSuggestInput entirely to avoid hanging
    if (process.env.NODE_ENV === 'test' || process.env.BUN_ENV === 'test') {
      return ''
    }

    try {
      const result = await this.autoSuggestInput.readLine(prompt)

      // Add to history if not empty
      if (result && result.trim()) {
        this.shell.addToHistory(result.trim())
      }

      return result
    }
    catch (error) {
      console.error('ReadLine error:', error)
      return null
    }
  }
}
