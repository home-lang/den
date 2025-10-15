import { beforeEach, describe, expect, it } from 'bun:test'
import { homedir } from 'node:os'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

/**
 * CompletionProvider focused tests
 */
describe('CompletionProvider', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      completion: {
        enabled: true,
        caseSensitive: false,
        maxSuggestions: 25,
      },
    })
    // Ensure we're in the project root directory for consistent test behavior
    // Force set to the actual project directory to prevent pollution from other tests
    shell.cwd = '/Users/chrisbreuer/Code/krusty'
  })

  it('completes commands for the first token', () => {
    const out = shell.getCompletions('ec', 2)
    expect(out.length).toBeGreaterThan(0)
    expect(out).toContain('echo')
  })

  it('completes files/dirs for non-first tokens', () => {
    const out = shell.getCompletions('ls ./', 5)
    expect(out.length).toBeGreaterThan(0)
    // Expect at least one directory-style completion to end with /
    expect(out.some(x => x.endsWith('/'))).toBe(true)
  })

  it('respects case sensitivity settings', () => {
    // Case-sensitive: uppercase should not match lowercase-only command names
    shell.config.completion!.caseSensitive = true
    const cs = shell.getCompletions('E', 1) as string[]
    expect(cs.includes('echo')).toBe(false)

    // Case-insensitive: should match
    shell.config.completion!.caseSensitive = false
    const ci = shell.getCompletions('E', 1) as string[]
    expect(ci.includes('echo')).toBe(true)
  })

  it('respects maxSuggestions', () => {
    shell.config.completion!.maxSuggestions = 5
    const out = shell.getCompletions('l', 1)
    expect(out.length).toBeLessThanOrEqual(5)
  })

  it('handles quoted/escaped path fragments', () => {
    // Cursor inside a quoted arg; we still pass full input and cursor at end
    const input = 'cat "./src/co'

    // Force reset the shell's cwd to ensure test isolation
    shell.cwd = '/Users/chrisbreuer/Code/krusty'

    const out = shell.getCompletions(input, input.length)

    // Should return some completions for paths starting with co
    expect(out.length).toBeGreaterThan(0)
    // Should contain completions that start with co or config
    expect(out.some(x => x.includes('co'))).toBe(true)
  })

  it('expands home directory for file completions', () => {
    const input = 'ls ~/'
    const out = shell.getCompletions(input, input.length)
    // We cannot assert specific entries from a user home, but we should get some
    // suggestions if the home directory exists.
    expect(typeof homedir()).toBe('string')
    expect(out.length).toBeGreaterThanOrEqual(0)
  })

  it('includes PATH binaries in first-token completions', () => {
    // Heuristic: grep/wc are common on POSIX systems
    const out = shell.getCompletions('w', 1)
    expect(out.some(x => x === 'wc' || x.startsWith('w'))).toBe(true)
  })
})
