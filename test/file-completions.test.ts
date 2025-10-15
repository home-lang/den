import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('File/path completions edge cases', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      completion: {
        enabled: true,
        caseSensitive: false,
        maxSuggestions: 100,
      },
    })
    // Set the shell's cwd to the project root for consistent test results
    shell.cwd = '/Users/chrisbreuer/Code/krusty'
    // Clear completion cache to ensure clean state
    ;(shell as any).completionProvider?.clearCache?.()
  })

  it('handles single-quoted path fragments', () => {
    // Test that completions work with quoted paths - use a simpler test
    const input = 'cat \'./README'
    const out = shell.getCompletions(input, input.length)
    // Should return some completions for files starting with README
    expect(out.length).toBeGreaterThan(0)
  })

  it('hides dot-directories unless prefix starts with .', () => {
    // Without leading dot prefix, should not show dot-directories
    const noDot = shell.getCompletions('ls ./', 'ls ./'.length)
    // Should not include any dot-directories when not specifically requested
    const hasDotDirs = noDot.some(item => item.startsWith('.') && item !== './' && item !== '../')
    expect(hasDotDirs).toBe(false)

    // With dot prefix, should suggest dot-directories
    const withDot = shell.getCompletions('ls .g', 'ls .g'.length)
    // Should contain at least one dot-directory starting with .g
    expect(withDot.some(item => item.startsWith('.g'))).toBe(true)
  })

  it('suggests directory entries with trailing slash when base ends with /', () => {
    const input = 'ls src/'
    const out = shell.getCompletions(input, input.length)
    // Should contain subdirectories ending with /
    expect(out.some(x => x.endsWith('/'))).toBe(true)
  })
})
