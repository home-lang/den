/* eslint-disable dot-notation */
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { AutoSuggestInput } from '../src/input/auto-suggest'

let mockOutput = ''
const originalWrite = process.stdout.write
function mockStdout() {
  mockOutput = ''
  process.stdout.write = mock((chunk: any) => {
    mockOutput += chunk.toString()
    return true
  })
}
function restoreStdout() {
  process.stdout.write = originalWrite
}

describe('Flat completions backward-compatibility', () => {
  beforeEach(() => {
    mockStdout()
  })
  afterEach(() => {
    restoreStdout()
  })

  it('renders flat suggestion list and does not use grouped headers', () => {
    const shell = {
      getCompletions: mock(() => ['git', 'grep', 'go']),
      config: { completion: { enabled: true } },
      history: [],
    } as any
    const inp = new AutoSuggestInput(shell, { syntaxHighlight: false })

    ;(inp as any).setInputForTesting('g', undefined)

    // Set up suggestions manually since updateSuggestions isn't called
    ;(inp as any)['suggestions'] = ['git', 'grep', 'go']
    ;(inp as any)['isShowingSuggestions'] = true
    ;(inp as any)['selectedIndex'] = 0

    // Ensure grouped path is not active
    expect((inp as any)['groupedActive']).toBe(false)

    mockOutput = ''
    ;(inp as any).updateDisplayForTesting('~/t ❯ ')

    // Should not contain any header-like text (simple heuristic)
    expect(mockOutput).not.toContain('Commands:')
    // Selected item is no longer bracketed; ensure plain label appears
    expect(mockOutput).toContain('git')
    expect(mockOutput).not.toContain('[git]')
    expect(mockOutput).toContain('grep')
  })

  it('accepts selected flat completion into input with applySelectedCompletion', () => {
    const shell = {
      getCompletions: mock(() => ['git', 'grep']),
      config: { completion: { enabled: true } },
      history: [],
    } as any
    const inp = new AutoSuggestInput(shell)

    ;(inp as any).setInputForTesting('g', undefined)
    ;(inp as any)['suggestions'] = ['git', 'grep']
    ;(inp as any)['isShowingSuggestions'] = true
    ;(inp as any)['selectedIndex'] = 1 // 'grep'

    ;(inp as any)['applySelectedCompletion']()

    expect((inp as any)['getCurrentInputForTesting']()).toBe('grep')
  })

  it('computes inline suffix correctly for flat completions when list is closed', () => {
    const shell = {
      getCompletions: mock(() => ['bundle', 'build', 'run']),
      config: { completion: { enabled: true } },
      history: [],
    } as any
    const inp = new AutoSuggestInput(shell, { syntaxHighlight: false })

    ;(inp as any).setInputForTesting('b', undefined)

    // Set up current suggestion for inline display
    ;(inp as any)['currentSuggestion'] = 'undle'
    ;(inp as any)['isShowingSuggestions'] = false
    ;(inp as any)['selectedIndex'] = 0 // 'bundle'

    mockOutput = ''
    ;(inp as any).updateDisplayForTesting('~/t ❯ ')

    expect(mockOutput).toContain('undle')
  })
})
