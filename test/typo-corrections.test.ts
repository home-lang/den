/* eslint-disable no-console */
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'

describe('Typo Corrections Test', () => {
  let mockOutput = ''
  let _writeCallCount = 0
  let keypressHandlers: Array<(str: string, key: any) => void> = []
  const originalWrite = process.stdout.write
  const originalOn = process.stdin.on
  const originalSetRawMode = process.stdin.setRawMode

  beforeEach(() => {
    mockOutput = ''
    _writeCallCount = 0
    keypressHandlers = []

    process.stdout.write = mock((chunk: any) => {
      _writeCallCount++
      const str = chunk.toString()
      mockOutput += str
      return true
    })

    process.stdin.on = mock((event: string, handler: any) => {
      if (event === 'keypress') {
        keypressHandlers.push(handler)
      }
      return process.stdin
    })

    process.stdin.setRawMode = mock(() => process.stdin)
    process.stdin.removeAllListeners = mock(() => process.stdin)
  })

  afterEach(() => {
    process.stdout.write = originalWrite
    process.stdin.on = originalOn
    process.stdin.setRawMode = originalSetRawMode
  })

  it('should provide typo corrections for common git typos', async () => {
    const { AutoSuggestInput } = await import('../src/input/auto-suggest')

    // Create a mock shell with the sophisticated auto-suggest plugin
    const mockShell = {
      getCompletions: (input: string, cursor: number) => {
        // Simulate the sophisticated auto-suggest plugin behavior
        const corrections: Record<string, string> = {
          gti: 'git',
          got: 'git',
          gut: 'git',
          gir: 'git',
          gits: 'git status',
          gitst: 'git status',
          gist: 'git status',
        }

        const partial = input.slice(0, cursor).trim()
        const suggestions: string[] = []

        // Check for typo corrections
        if (corrections[partial]) {
          suggestions.push(corrections[partial])
        }

        // Add some history-based suggestions
        if (partial.startsWith('g')) {
          suggestions.push('git status', 'git add', 'git commit')
        }

        return suggestions.slice(0, 5)
      },
      config: { completion: { enabled: true } },
      history: ['git status', 'git add .', 'git commit -m "test"'],
      aliases: {},
    }

    const autoSuggestInput = new AutoSuggestInput(mockShell as any)
    const prompt = '❯ '

    console.log('=== Testing typo correction: gti ===')

    // Start readLine
    const readLinePromise = autoSuggestInput.readLine(prompt)

    // Debug: Check how many keypress handlers were registered
    console.log(`DEBUG: ${keypressHandlers.length} keypress handlers registered`)

    const keypressHandler = keypressHandlers[keypressHandlers.length - 1] // Use the last one

    // Type 'g'
    keypressHandler('g', { name: 'g', sequence: 'g', ctrl: false, meta: false, shift: false })

    // Type 't'
    keypressHandler('t', { name: 't', sequence: 't', ctrl: false, meta: false, shift: false })

    // Type 'i' - should trigger 'git' suggestion
    keypressHandler('i', { name: 'i', sequence: 'i', ctrl: false, meta: false, shift: false })

    console.log(`After typing 'gti': ${JSON.stringify(mockOutput)}`)

    // Check if 'git' appears as a suggestion (in gray)
    expect(mockOutput).toContain('gti')
    expect(mockOutput).toContain('\x1B[90m') // Gray color for suggestions

    // Clean up
    keypressHandler('', { name: 'return' })
    await readLinePromise
  })

  it('should provide history-based completions', async () => {
    const { AutoSuggestInput } = await import('../src/input/auto-suggest')

    const mockShell = {
      getCompletions: (input: string, cursor: number) => {
        const partial = input.slice(0, cursor).trim()
        const history = ['build', 'bundle', 'test']

        return history
          .filter(cmd => cmd.startsWith(partial) && cmd !== partial)
          .slice(0, 3)
      },
      config: { completion: { enabled: true } },
      history: ['build', 'bundle', 'test'],
      aliases: {},
    }

    const autoSuggestInput = new AutoSuggestInput(mockShell as any)
    const prompt = '❯ '

    console.log('=== Testing history completion: b ===')

    // Start readLine
    const readLinePromise = autoSuggestInput.readLine(prompt)

    // Debug: Check how many keypress handlers were registered
    console.log(`DEBUG: ${keypressHandlers.length} keypress handlers registered`)

    const keypressHandler = keypressHandlers[keypressHandlers.length - 1] // Use the last one

    // Type 'b' - should show 'build' or 'bundle' suggestion
    keypressHandler('b', { name: 'b', sequence: 'b', ctrl: false, meta: false, shift: false })

    console.log(`After typing 'b': ${JSON.stringify(mockOutput)}`)

    // Should show suggestion
    expect(mockOutput).toContain('b')
    expect(mockOutput).toContain('\x1B[90m') // Gray color for suggestions

    // Clean up
    keypressHandler('', { name: 'return' })
    await readLinePromise
  })
})
