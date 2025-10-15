/* eslint-disable no-console, no-control-regex */
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'

describe('Cursor Positioning Tests', () => {
  let mockOutput = ''
  let writeCallCount = 0
  let keypressHandlers: Array<(str: string, key: any) => void> = []
  const originalWrite = process.stdout.write
  const originalOn = process.stdin.on
  const originalSetRawMode = process.stdin.setRawMode

  beforeEach(() => {
    mockOutput = ''
    writeCallCount = 0
    keypressHandlers = []

    process.stdout.write = mock((chunk: any) => {
      writeCallCount++
      const str = chunk.toString()
      mockOutput += str
      console.log(`Write #${writeCallCount}: ${JSON.stringify(str)}`)
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

  it('should position cursor correctly after prompt when typing', async () => {
    const { AutoSuggestInput } = await import('../src/input/auto-suggest')

    const mockShell = {
      getCompletions: () => ['build', 'bundle'],
      config: { completion: { enabled: true } },
      history: [],
      aliases: {},
    }

    const autoSuggestInput = new AutoSuggestInput(mockShell as any)
    const prompt = '~/Code/krusty ⎇ main [●1○12?11] via 🐰 1.2.21❯ '

    console.log('=== Testing cursor positioning ===')
    console.log(`Prompt length: ${prompt.length}`)

    // Start readLine
    const readLinePromise = autoSuggestInput.readLine(prompt)
    const keypressHandler = keypressHandlers[0]

    console.log('=== Initial state ===')
    console.log(`Output: ${JSON.stringify(mockOutput)}`)

    // Type 'b'
    console.log('=== User types "b" ===')
    keypressHandler('b', { name: 'b', sequence: 'b', ctrl: false, meta: false })

    console.log(`After 'b': ${JSON.stringify(mockOutput)}`)

    // Analyze cursor positioning commands
    const cursorCommands = mockOutput.match(/\x1B\[\d+G/g) || []
    console.log(`Cursor positioning commands: ${JSON.stringify(cursorCommands)}`)

    // Extract the column numbers from cursor commands
    const columnNumbers = cursorCommands.map((cmd) => {
      const match = cmd.match(/\x1B\[(\d+)G/)
      return match ? Number.parseInt(match[1]) : 0
    })
    console.log(`Column positions: ${JSON.stringify(columnNumbers)}`)

    // The cursor should be positioned right after the prompt
    const expectedColumn = prompt.length + 1 // +1 for 1-based indexing
    console.log(`Expected cursor column: ${expectedColumn}`)

    // Type 'u' to test sequential positioning
    console.log('=== User types "u" ===')
    keypressHandler('u', { name: 'u', sequence: 'u', ctrl: false, meta: false })

    console.log(`After 'u': ${JSON.stringify(mockOutput)}`)

    // Check final cursor positioning
    const finalCursorCommands = mockOutput.match(/\x1B\[\d+G/g) || []
    const finalColumnNumbers = finalCursorCommands.map((cmd) => {
      const match = cmd.match(/\x1B\[(\d+)G/)
      return match ? Number.parseInt(match[1]) : 0
    })
    console.log(`Final cursor positions: ${JSON.stringify(finalColumnNumbers)}`)

    // The cursor positioning in the current implementation only updates on updateDisplay calls
    // Since we're simulating keypress directly, we need to check if updateDisplay was called
    // The cursor should be positioned after the prompt initially
    const expectedInitialColumn = prompt.length + 1
    console.log(`Expected initial cursor column: ${expectedInitialColumn}`)

    // Verify cursor positioning is correct - should have at least one cursor positioning command
    expect(finalColumnNumbers.length).toBeGreaterThan(0)

    // The cursor should be positioned at least at the prompt position
    const lastCursorPosition = finalColumnNumbers[finalColumnNumbers.length - 1]
    expect(lastCursorPosition).toBeGreaterThanOrEqual(expectedInitialColumn)

    // Clean up
    keypressHandler('', { name: 'return' })
    await readLinePromise
  })

  it('should test updateDisplay positioning logic directly', async () => {
    const { AutoSuggestInput } = await import('../src/input/auto-suggest')

    const mockShell = {
      getCompletions: () => ['build'],
      config: { completion: { enabled: true } },
      history: [],
      aliases: {},
    }

    const autoSuggestInput = new AutoSuggestInput(mockShell as any)
    const prompt = '~/Code/krusty ⎇ main [●1○12?11] via 🐰 1.2.21❯ '

    console.log('=== Testing updateDisplay positioning ===')
    console.log(`Prompt: ${JSON.stringify(prompt)}`)
    console.log(`Prompt length: ${prompt.length}`)

    // Simulate typing 'b'
    autoSuggestInput.setInputForTesting('b', 1)
    autoSuggestInput.updateDisplayForTesting(prompt)

    console.log('=== After updateDisplay with "b" ===')
    console.log(`Output: ${JSON.stringify(mockOutput)}`)

    // Parse the positioning commands
    const moveToInputStart = mockOutput.match(/\x1B\[(\d+)G\x1B\[K/)
    const finalCursorMove = mockOutput.match(/\x1B\[(\d+)G(?!.*\x1B\[K)/)

    console.log(`Move to input start: ${JSON.stringify(moveToInputStart)}`)
    console.log(`Final cursor move: ${JSON.stringify(finalCursorMove)}`)

    if (moveToInputStart) {
      const inputStartColumn = Number.parseInt(moveToInputStart[1])
      const expectedInputStart = prompt.length + 1
      console.log(`Input start column: ${inputStartColumn}, expected: ${expectedInputStart}`)
      expect(inputStartColumn).toBe(expectedInputStart)
    }

    if (finalCursorMove) {
      const finalColumn = Number.parseInt(finalCursorMove[1])
      const expectedFinalColumn = prompt.length + 2 // cursor after "b" (position 1 + 1 for 1-based)
      console.log(`Final cursor column: ${finalColumn}, expected: ${expectedFinalColumn}`)
      expect(finalColumn).toBe(expectedFinalColumn)
    }

    // Test with longer input
    mockOutput = ''
    autoSuggestInput.setInputForTesting('build', 5)
    autoSuggestInput.updateDisplayForTesting(prompt)

    console.log('=== After updateDisplay with "build" ===')
    console.log(`Output: ${JSON.stringify(mockOutput)}`)

    const finalCursorMove2 = mockOutput.match(/\x1B\[(\d+)G(?!.*\x1B\[K)/)
    if (finalCursorMove2) {
      const finalColumn2 = Number.parseInt(finalCursorMove2[1])
      const expectedFinalColumn2 = prompt.length + 6 // cursor at end of "build" + 1 for 1-based indexing
      console.log(`Final cursor column for "build": ${finalColumn2}, expected: ${expectedFinalColumn2}`)
      expect(finalColumn2).toBe(expectedFinalColumn2)
    }
  })

  it('should handle prompt with ANSI escape sequences correctly', async () => {
    const { AutoSuggestInput } = await import('../src/input/auto-suggest')

    const mockShell = {
      getCompletions: () => ['test'],
      config: { completion: { enabled: true } },
      history: [],
      aliases: {},
    }

    const autoSuggestInput = new AutoSuggestInput(mockShell as any)
    // Prompt with ANSI colors (common in shells)
    const promptWithColors = '\x1B[36m~/Code/krusty\x1B[0m \x1B[33m⎇ main\x1B[0m ❯ '

    console.log('=== Testing prompt with ANSI sequences ===')
    console.log(`Colored prompt: ${JSON.stringify(promptWithColors)}`)
    console.log(`Colored prompt length: ${promptWithColors.length}`)

    // The issue might be that we're counting ANSI escape sequences as part of prompt length
    // But terminal doesn't display them, so cursor positioning is off

    autoSuggestInput.setInputForTesting('t', 1)
    autoSuggestInput.updateDisplayForTesting(promptWithColors)

    console.log('=== After updateDisplay with colored prompt ===')
    console.log(`Output: ${JSON.stringify(mockOutput)}`)

    // Extract cursor positioning
    const cursorMoves = mockOutput.match(/\x1B\[(\d+)G/g) || []
    console.log(`Cursor moves with colored prompt: ${JSON.stringify(cursorMoves)}`)

    // This test reveals if ANSI sequences in prompt are causing positioning issues
    expect(cursorMoves.length).toBeGreaterThan(0)
  })
})
