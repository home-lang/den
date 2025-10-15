/* eslint-disable dot-notation */
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { AutoSuggestInput } from '../src/input/auto-suggest'

// Mock shell interface
const mockShell = {
  getCompletions: mock(() => ['bundle', 'build', 'run']),
  config: { completion: { enabled: true } },
  history: ['git status', 'npm install'],
  aliases: { ll: 'ls -la' },
}

// Mock stdout for testing
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

describe('AutoSuggestInput', () => {
  let autoSuggestInput: AutoSuggestInput

  beforeEach(() => {
    autoSuggestInput = new AutoSuggestInput(mockShell as any)
    mockStdout()
  })

  afterEach(() => {
    restoreStdout()
  })

  describe('updateDisplay', () => {
    it('should not create new lines when updating display', () => {
      const prompt = '~/test ❯ '

      // Simulate typing 'b'
      autoSuggestInput['currentInput'] = 'b'
      autoSuggestInput['cursorPosition'] = 1
      autoSuggestInput['updateDisplay'](prompt)

      // Should not contain newline characters
      expect(mockOutput).not.toContain('\n')

      // Should contain the prompt and input
      expect(mockOutput).toContain(prompt)
      expect(mockOutput).toContain('b')
    })

    it('should clear and rewrite line properly', () => {
      const prompt = '~/test ❯ '

      autoSuggestInput['currentInput'] = 'bu'
      autoSuggestInput['cursorPosition'] = 2
      autoSuggestInput['updateDisplay'](prompt)

      // Should start with carriage return and clear sequence
      expect(mockOutput).toStartWith('\r\x1B[2K')

      // Should not create multiple lines
      const lines = mockOutput.split('\n')
      expect(lines.length).toBe(1)
    })

    it('should handle backspace without creating new lines', () => {
      const prompt = '~/test ❯ '

      // Start with 'bu'
      autoSuggestInput['currentInput'] = 'bu'
      autoSuggestInput['cursorPosition'] = 2
      autoSuggestInput['updateDisplay'](prompt)

      const firstOutput = mockOutput
      mockOutput = ''

      // Backspace to 'b'
      autoSuggestInput['currentInput'] = 'b'
      autoSuggestInput['cursorPosition'] = 1
      autoSuggestInput['updateDisplay'](prompt)

      // Neither output should contain newlines
      expect(firstOutput).not.toContain('\n')
      expect(mockOutput).not.toContain('\n')
    })

    it('should position cursor correctly after input', () => {
      const prompt = '~/test ❯ '

      autoSuggestInput['currentInput'] = 'b'
      autoSuggestInput['cursorPosition'] = 1
      autoSuggestInput['currentSuggestion'] = 'undle'
      autoSuggestInput['updateDisplay'](prompt)

      // Should contain cursor positioning escape sequence
      expect(mockOutput).toContain('\x1B[')

      // Should not create new lines
      expect(mockOutput).not.toContain('\n')
    })

    it('suppresses inline suggestion while history browsing is active', () => {
      const prompt = '~/test ❯ '

      // Prepare a visible inline suggestion scenario
      autoSuggestInput['currentInput'] = 'b'
      autoSuggestInput['cursorPosition'] = 1
      autoSuggestInput['currentSuggestion'] = 'undle'
      autoSuggestInput['isShowingSuggestions'] = false
      autoSuggestInput['reverseSearchActive'] = false

      // Mark history browsing active to suppress inline overlay
      autoSuggestInput['historyBrowseActive'] = true

      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)

      // Should not print the inline suggestion suffix when browsing history
      expect(mockOutput).not.toContain('undle')
      // Still should contain prompt and base input
      expect(mockOutput).toContain(prompt)
      expect(mockOutput).toContain('b')
    })

    it('renders suggestions when list is open (no brackets)', () => {
      const prompt = '~/test ❯ '

      // Open suggestions list manually
      autoSuggestInput['currentInput'] = ''
      autoSuggestInput['cursorPosition'] = 0
      autoSuggestInput['suggestions'] = ['bun run', 'bun build']
      autoSuggestInput['selectedIndex'] = 0
      autoSuggestInput['isShowingSuggestions'] = true
      autoSuggestInput['reverseSearchActive'] = false
      autoSuggestInput['historyBrowseActive'] = false

      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)

      // Suggestions list prints selected item without brackets
      expect(mockOutput).toContain('bun run')
      expect(mockOutput).not.toContain('[bun run]')
    })

    it('renders flat suggestions vertically (no space-separated dump)', () => {
      const prompt = '~/test ❯ '

      // Open flat suggestions list manually (non-grouped)
      autoSuggestInput['currentInput'] = 'bun '
      autoSuggestInput['cursorPosition'] = 4
      autoSuggestInput['suggestions'] = ['run', 'build', 'test']
      autoSuggestInput['selectedIndex'] = 1
      autoSuggestInput['isShowingSuggestions'] = true
      autoSuggestInput['reverseSearchActive'] = false
      autoSuggestInput['historyBrowseActive'] = false
      // Ensure grouped mode not active
      autoSuggestInput['groupedActive'] = false

      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)

      // Expect each suggestion on its own line below the prompt, not a single inline row
      // eslint-disable-next-line no-control-regex
      const occurrencesRun = (mockOutput.match(/\n\x1B\[2K.*run/g) || []).length
      // eslint-disable-next-line no-control-regex
      const occurrencesBuild = (mockOutput.match(/\n\x1B\[2K.*build/g) || []).length
      // eslint-disable-next-line no-control-regex
      const occurrencesTest = (mockOutput.match(/\n\x1B\[2K.*test/g) || []).length
      expect(occurrencesRun).toBe(1)
      expect(occurrencesBuild).toBe(1)
      expect(occurrencesTest).toBe(1)

      // Should not contain space-joined dump like "run  build  test"
      expect(mockOutput).not.toContain('run  build  test')
    })
  })

  describe('history navigation integration', () => {
    it('cycles through all matching history items including duplicates (most recent first)', () => {
      const shell = {
        ...mockShell,
        history: ['echo a', 'git status', 'git push', 'git status', 'git commit', 'go build'],
      } as any
      const inp = new AutoSuggestInput(shell)

      // Type prefix 'git ' and place cursor at end
      ;(inp as any).setInputForTesting('git ', undefined)

      // Up cycles: should go most recent matching first
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('git commit')
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('git status')
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('git push')
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('git status')
    })

    it('down moves towards newer entries and exits browsing at newest', () => {
      const shell = {
        ...mockShell,
        history: ['a', 'b', 'c', 'cat x', 'cat y'],
      } as any
      const inp = new AutoSuggestInput(shell)
      ;(inp as any).setInputForTesting('cat ', undefined)

      // Enter browsing and move up twice
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('cat y')
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('cat x')

      // Now move down back towards newer
      ;(inp as any).historyDownForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('cat y')
      // Move down again -> should exit browsing (no newer match)
      ;(inp as any).historyDownForTesting()
      expect((inp as any)['historyBrowseActive']).toBe(false)
    })

    it('typing resets history browsing and suggestions are suppressed during browsing', () => {
      const shell = {
        ...mockShell,
        getCompletions: mock(() => ['cat', 'cargo', 'cp']),
        history: ['cat notes', 'cat file'],
      } as any
      const inp = new AutoSuggestInput(shell)

      // Start with prefix 'c' to get completions and matching history
      ;(inp as any).setInputForTesting('c', undefined)
      ;(inp as any).historyUpForTesting()
      // While browsing, inline suggestion should be cleared and list closed
      expect((inp as any)['currentSuggestion']).toBe('')
      expect((inp as any)['isShowingSuggestions']).toBe(false)

      // Now simulate typing which should reset browsing state
      ;(inp as any).setInputForTesting('ca', undefined)
      expect((inp as any)['historyBrowseActive']).toBe(false)
    })

    it('Up on empty prompt recalls last command; Down clears back to empty', () => {
      const shell = {
        ...mockShell,
        history: ['echo 1', 'ls -la'],
      } as any
      const inp = new AutoSuggestInput(shell)

      // Empty prompt
      ;(inp as any).setInputForTesting('', undefined)
      expect((inp as any).getCurrentInputForTesting()).toBe('')
      expect((inp as any)['historyBrowseActive']).toBe(false)

      // Up should recall most recent command
      ;(inp as any).historyUpForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('ls -la')
      expect((inp as any)['historyBrowseActive']).toBe(true)

      // Down should clear back to empty and exit browsing
      ;(inp as any).historyDownForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('')
      expect((inp as any)['historyBrowseActive']).toBe(false)
    })

    it('Down on empty prompt when not browsing keeps empty and does not open suggestions', () => {
      const shell = {
        ...mockShell,
        getCompletions: mock(() => ['one', 'two']),
        history: ['foo', 'bar'],
      } as any
      const inp = new AutoSuggestInput(shell)

      // Ensure empty input and not browsing
      ;(inp as any).setInputForTesting('', undefined)
      expect((inp as any)['historyBrowseActive']).toBe(false)

      // Trigger a Down navigation (no-op that should keep empty)
      ;(inp as any).historyDownForTesting()
      expect((inp as any).getCurrentInputForTesting()).toBe('')
      // Should not have opened suggestions as a side-effect
      expect((inp as any)['isShowingSuggestions']).toBe(false)
    })
  })

  describe('Ctrl+C behavior', () => {
    it('Ctrl+C aborts the line: resolves empty string and prints a newline', async () => {
      const shell = { ...mockShell } as any
      const inp = new AutoSuggestInput(shell)

      mockStdout()
      const prompt = '~/test ❯ '

      const p = inp.readLine(prompt)
      // Simulate user hitting Ctrl+C
      process.stdin.emit('keypress', '', { ctrl: true, name: 'c' })

      const res = await p
      expect(res).toBe('')
      expect(mockOutput).toContain('\n')
      restoreStdout()
    })
  })

  describe('character input simulation', () => {
    it('should handle multiple character inputs without line breaks', () => {
      const prompt = '~/test ❯ '

      // Simulate typing 'bun' character by character
      const chars = ['b', 'u', 'n']

      for (let i = 0; i < chars.length; i++) {
        mockOutput = '' // Reset for each character

        autoSuggestInput['currentInput'] = chars.slice(0, i + 1).join('')
        autoSuggestInput['cursorPosition'] = i + 1
        autoSuggestInput['updateDisplay'](prompt)

        // Each update should not create new lines
        expect(mockOutput).not.toContain('\n')
        expect(mockOutput).toContain(prompt)
      }
    })
  })

  describe('key helper behaviors', () => {
    it('moveToLineStart and moveToLineEnd adjust cursor correctly', () => {
      autoSuggestInput['currentInput'] = 'echo hello'
      autoSuggestInput['cursorPosition'] = 5
      autoSuggestInput['moveToLineStart']()
      expect(autoSuggestInput['cursorPosition']).toBe(0)
      autoSuggestInput['moveToLineEnd']()
      expect(autoSuggestInput['cursorPosition']).toBe('echo hello'.length)
    })

    it('moveCursorLeft/Right moves within bounds', () => {
      autoSuggestInput['currentInput'] = 'abc'
      autoSuggestInput['cursorPosition'] = 1
      autoSuggestInput['moveCursorLeft']()
      expect(autoSuggestInput['cursorPosition']).toBe(0)
      autoSuggestInput['moveCursorLeft']() // stays at 0
      expect(autoSuggestInput['cursorPosition']).toBe(0)
      autoSuggestInput['moveCursorRight']()
      expect(autoSuggestInput['cursorPosition']).toBe(1)
      autoSuggestInput['moveCursorRight']()
      autoSuggestInput['moveCursorRight']()
      expect(autoSuggestInput['cursorPosition']).toBe(3)
      autoSuggestInput['moveCursorRight']() // stays at end
      expect(autoSuggestInput['cursorPosition']).toBe(3)
    })

    it('moveWordLeft/Right respects word boundaries', () => {
      autoSuggestInput['currentInput'] = 'git   commit --amend'
      autoSuggestInput['cursorPosition'] = 3 // after git
      autoSuggestInput['moveWordRight']()
      // skip spaces to start of 'commit', then over word
      expect(autoSuggestInput['cursorPosition']).toBe('git   commit'.length)

      autoSuggestInput['moveWordRight']()
      // over space to '--amend' and through word characters until end of amend
      expect(autoSuggestInput['cursorPosition']).toBe('git   commit --amend'.length)

      autoSuggestInput['moveWordLeft']()
      // back to start of '--amend' (non-space then word)
      // our word char set treats letters/digits/underscore as words; '-' are separators
      // so we should land right before 'amend'
      expect(autoSuggestInput['currentInput'][autoSuggestInput['cursorPosition']]).toBe('a')
    })

    it('deleteCharUnderCursor removes character at cursor', () => {
      autoSuggestInput['currentInput'] = 'abcd'
      autoSuggestInput['cursorPosition'] = 1 // at 'b'
      autoSuggestInput['deleteCharUnderCursor']()
      expect(autoSuggestInput['currentInput']).toBe('acd')
      expect(autoSuggestInput['cursorPosition']).toBe(1)
    })

    it('killToEnd truncates at cursor', () => {
      autoSuggestInput['currentInput'] = 'abcdef'
      autoSuggestInput['cursorPosition'] = 3
      autoSuggestInput['killToEnd']()
      expect(autoSuggestInput['currentInput']).toBe('abc')
      expect(autoSuggestInput['cursorPosition']).toBe(3)
    })

    it('killToStart removes from start to cursor and moves cursor to 0', () => {
      autoSuggestInput['currentInput'] = 'abcdef'
      autoSuggestInput['cursorPosition'] = 4
      autoSuggestInput['killToStart']()
      expect(autoSuggestInput['currentInput']).toBe('ef')
      expect(autoSuggestInput['cursorPosition']).toBe(0)
    })

    it('deleteWordLeft deletes previous word', () => {
      autoSuggestInput['currentInput'] = 'hello world'
      autoSuggestInput['cursorPosition'] = 11
      autoSuggestInput['deleteWordLeft']()
      expect(autoSuggestInput['currentInput']).toBe('hello ')
      expect(autoSuggestInput['cursorPosition']).toBe(6)
    })

    it('deleteWordRight deletes next word', () => {
      autoSuggestInput['currentInput'] = 'echo   test file'
      autoSuggestInput['cursorPosition'] = 7 // between spaces before 'test'
      autoSuggestInput['deleteWordRight']()
      expect(autoSuggestInput['currentInput']).toBe('echo    file')
      expect(autoSuggestInput['cursorPosition']).toBe(7)
    })
  })

  describe('multi-line navigation', () => {
    it('moveCursorUp/Down preserves column across lines', () => {
      autoSuggestInput['currentInput'] = 'first line\nsecond\nthird line'
      // Place cursor at column 3 (0-based) of second line ("second")
      const idxSecondLineCol3 = autoSuggestInput['lineColToIndex'](1, 3)
      autoSuggestInput['cursorPosition'] = idxSecondLineCol3

      // Move up -> should go to line 0, col 3
      autoSuggestInput['moveCursorUp']()
      let pos = autoSuggestInput['cursorPosition']
      let lc = autoSuggestInput['indexToLineCol'](pos)
      expect(lc.line).toBe(0)
      expect(lc.col).toBe(3)

      // Move down twice -> to line 2, preserving col 3
      autoSuggestInput['moveCursorDown']()
      autoSuggestInput['moveCursorDown']()
      pos = autoSuggestInput['cursorPosition']
      lc = autoSuggestInput['indexToLineCol'](pos)
      expect(lc.line).toBe(2)
      // line 2 is "third line" length 10, col 3 valid
      expect(lc.col).toBe(3)
    })

    it('moveCursorUp/Down clamps to line length when necessary', () => {
      autoSuggestInput['currentInput'] = 'short\na bit longer\nmid'
      // Choose a column beyond length of line 0 and 2, e.g., col 8
      const startIdx = autoSuggestInput['lineColToIndex'](1, 8) // line 1 has enough length
      autoSuggestInput['cursorPosition'] = startIdx

      // Move up -> line 0 length is 5 ("short"), expect col clamped to 5
      autoSuggestInput['moveCursorUp']()
      let lc = autoSuggestInput['indexToLineCol'](autoSuggestInput['cursorPosition'])
      expect(lc.line).toBe(0)
      expect(lc.col).toBe('short'.length)

      // Move down twice -> line 2 is "mid" length 3, expect col clamped to 3
      autoSuggestInput['moveCursorDown']()
      autoSuggestInput['moveCursorDown']()
      lc = autoSuggestInput['indexToLineCol'](autoSuggestInput['cursorPosition'])
      expect(lc.line).toBe(2)
      expect(lc.col).toBe('mid'.length)
    })

    it('Home/End (line-aware) move to start/end of current line', () => {
      autoSuggestInput['currentInput'] = 'alpha beta\ngamma\ndelta'
      // Put cursor on line 1, col 2
      autoSuggestInput['cursorPosition'] = autoSuggestInput['lineColToIndex'](1, 2)

      // Home -> start of line 1
      autoSuggestInput['moveToLineStart']()
      let lc = autoSuggestInput['indexToLineCol'](autoSuggestInput['cursorPosition'])
      expect(lc.line).toBe(1)
      expect(lc.col).toBe(0)

      // End -> end of line 1 ("gamma")
      autoSuggestInput['moveToLineEnd']()
      lc = autoSuggestInput['indexToLineCol'](autoSuggestInput['cursorPosition'])
      expect(lc.line).toBe(1)
      expect(lc.col).toBe('gamma'.length)
    })
  })

  describe('multi-line backspace/delete', () => {
    it('backspace at start of a line joins with previous line and moves cursor to previous line end', () => {
      autoSuggestInput['setInputForTesting']('foo\nbar', undefined)
      // Place cursor at start of second line
      const startSecond = autoSuggestInput['lineColToIndex'](1, 0)
      autoSuggestInput['setCursorPositionForTesting'](startSecond)

      autoSuggestInput['backspaceOneForTesting']()

      expect(autoSuggestInput['getCurrentInputForTesting']()).toBe('foobar')
      const { line, col } = autoSuggestInput['indexToLineCol'](autoSuggestInput['getCursorPositionForTesting']())
      expect(line).toBe(0)
      expect(col).toBe('foo'.length)
    })

    it('delete at end of a line joins with next line and keeps cursor at join point', () => {
      autoSuggestInput['setInputForTesting']('abc\ndef', undefined)
      // Cursor at end of first line
      const endFirst = autoSuggestInput['lineColToIndex'](0, 'abc'.length)
      autoSuggestInput['setCursorPositionForTesting'](endFirst)

      autoSuggestInput['deleteOneForTesting']()

      expect(autoSuggestInput['getCurrentInputForTesting']()).toBe('abcdef')
      const { line, col } = autoSuggestInput['indexToLineCol'](autoSuggestInput['getCursorPositionForTesting']())
      expect(line).toBe(0)
      expect(col).toBe('abc'.length)
    })

    it('backspace/delete inside a line behaves normally', () => {
      autoSuggestInput['setInputForTesting']('hello\nworld', undefined)
      // Inside first line: remove the second character 'e'
      const pos = autoSuggestInput['lineColToIndex'](0, 1)
      autoSuggestInput['setCursorPositionForTesting'](pos + 1) // place after 'e'
      autoSuggestInput['backspaceOneForTesting']()
      expect(autoSuggestInput['getCurrentInputForTesting']()).toBe('hllo\nworld')

      // Now delete the 'l' under cursor
      autoSuggestInput['deleteOneForTesting']()
      expect(autoSuggestInput['getCurrentInputForTesting']()).toBe('hlo\nworld')
    })
  })

  describe('syntax highlighting', () => {
    const prompt = '~/test ❯ '

    it('highlights command at line start (cyan)', () => {
      autoSuggestInput['currentInput'] = 'echo hello'
      autoSuggestInput['cursorPosition'] = 'echo hello'.length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain('\x1B[36mecho\x1B[0m')
    })

    it('highlights subcommand for common tools (bright blue)', () => {
      autoSuggestInput['currentInput'] = 'git commit -m "msg"'
      autoSuggestInput['cursorPosition'] = autoSuggestInput['currentInput'].length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain('\x1B[36mgit\x1B[0m \x1B[94mcommit\x1B[0m')
    })

    it('highlights flags (yellow) and operators (gray)', () => {
      autoSuggestInput['currentInput'] = 'ls -la && echo done'
      autoSuggestInput['cursorPosition'] = autoSuggestInput['currentInput'].length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain(' \x1B[33m-la\x1B[0m')
      expect(mockOutput).toContain('\x1B[90m&&\x1B[0m')
    })

    it('highlights variables (gray) and numbers (magenta)', () => {
      autoSuggestInput['currentInput'] = 'echo $HOME 42'
      autoSuggestInput['cursorPosition'] = autoSuggestInput['currentInput'].length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain('\x1B[90m$HOME\x1B[0m')
      expect(mockOutput).toContain('\x1B[35m42\x1B[0m')
    })

    it('highlights paths (green)', () => {
      autoSuggestInput['currentInput'] = 'cat ~/notes.txt'
      autoSuggestInput['cursorPosition'] = autoSuggestInput['currentInput'].length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain('\x1B[32m~/notes.txt\x1B[0m')
    })

    it('highlights comments (gray) from # to end', () => {
      autoSuggestInput['currentInput'] = 'echo ok # this is a comment'
      autoSuggestInput['cursorPosition'] = autoSuggestInput['currentInput'].length
      mockOutput = ''
      autoSuggestInput['updateDisplay'](prompt)
      expect(mockOutput).toContain('\x1B[90m# this is a comment\x1B[0m')
    })
  })
})

// Standalone tests (no stdout mocking required)
describe('history expansion', () => {
  it('expands !! to last command', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['echo ok', 'git status', 'npm run build'],
    } as any)
    const out = (inp as any)['expandHistory']('!!') as string
    expect(out).toBe('npm run build')
  })

  it('expands !n to nth command (1-based)', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['echo ok', 'git status', 'npm run build'],
    } as any)
    const out = (inp as any)['expandHistory']('!2') as string
    expect(out).toBe('git status')
  })

  it('expands !prefix to most recent matching command', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['git commit -m x', 'echo ok', 'git status'],
    } as any)
    const out = (inp as any)['expandHistory']('!git') as string
    expect(out).toBe('git status')
  })

  it('mixed text preserves surrounding content', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['one', 'two'],
    } as any)
    const out = (inp as any)['expandHistory']('echo !! and !1') as string
    // debug actual value if this fails
    console.warn('[debug expandHistory mixed]', out)
    expect(out).toBe('echo two and one')
  })

  it('unknown prefix leaves it removed but preserves prefix context', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['abc'],
    } as any)
    const out = (inp as any)['expandHistory']('echo !xyz') as string
    expect(out).toBe('echo ')
  })
})

describe('reverse search', () => {
  it('activates and shows top match on update', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['echo ok', 'git status', 'git commit -m x', 'ls'],
    } as any)
    ;(inp as any)['startReverseSearch']()
    ;(inp as any)['updateReverseSearch']('g')
    const status = (inp as any)['reverseSearchStatus']() as string
    expect(status).toContain('(reverse-i-search)')
    expect(status).toContain('\'g\':')
    expect((inp as any)['getCurrentInputForTesting']()).toBe('git commit -m x')
  })

  it('cycles through matches with cycleReverseSearch()', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['echo ok', 'git status', 'git commit -m x', 'git push', 'ls'],
    } as any)
    ;(inp as any)['startReverseSearch']()
    ;(inp as any)['updateReverseSearch']('git')
    const first = (inp as any)['getCurrentInputForTesting']()
    ;(inp as any)['cycleReverseSearch']()
    const second = (inp as any)['getCurrentInputForTesting']()
    expect(second).not.toBe(first)
    ;(inp as any)['cycleReverseSearch']()
    const third = (inp as any)['getCurrentInputForTesting']()
    expect(third).not.toBe(second)
    expect([first, second]).not.toContain(third)
  })

  it('cancel clears status and deactivates', () => {
    const inp = new AutoSuggestInput({
      ...mockShell,
      history: ['a', 'b'],
    } as any)
    ;(inp as any)['startReverseSearch']()
    ;(inp as any)['updateReverseSearch']('a')
    ;(inp as any)['cancelReverseSearch']()
    const status = (inp as any)['reverseSearchStatus']() as string
    expect(status).toBe('')
    ;(inp as any)['cycleReverseSearch']()
    expect((inp as any)['getCurrentInputForTesting']()).toBeDefined()
  })
})
