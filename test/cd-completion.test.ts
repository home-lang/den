import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

/**
 * CD completion tests to ensure only existing directories are suggested
 */
describe('CD Completion Validation', () => {
  let shell: KrustyShell
  let testDir: string
  let originalCwd: string

  beforeEach(() => {
    // Set test environment to prevent shell from starting interactive session
    process.env.NODE_ENV = 'test'
    shell = new KrustyShell({
      ...defaultConfig,
      completion: {
        enabled: true,
        caseSensitive: false,
        maxSuggestions: 25,
      },
    })

    // Store original cwd for restoration
    originalCwd = shell.cwd

    // Create a temporary test directory structure
    testDir = join(process.cwd(), 'test-cd-completion')
    try {
      rmSync(testDir, { recursive: true, force: true })
    }
    catch {}

    mkdirSync(testDir, { recursive: true })
    mkdirSync(join(testDir, 'existing-dir'))
    mkdirSync(join(testDir, 'another-dir'))
    writeFileSync(join(testDir, 'not-a-dir.txt'), 'file content')

    // Change to test directory
    shell.changeDirectory(testDir)
  })

  afterEach(() => {
    // Restore original cwd to prevent test isolation issues
    shell.changeDirectory(originalCwd)

    // Properly stop shell to prevent hanging
    if (shell) {
      shell.stop()
    }
    try {
      rmSync(testDir, { recursive: true, force: true })
    }
    catch {}
  })

  it('should only suggest existing directories for cd command', () => {
    const completions = shell.getCompletions('cd ', 3)
    const completionStrings = Array.isArray(completions) ? completions.map(c => typeof c === 'string' ? c : c.text || '') : []

    // Should include existing directories
    expect(completionStrings.some(c => c.includes('existing-dir'))).toBe(true)
    expect(completionStrings.some(c => c.includes('another-dir'))).toBe(true)

    // Should NOT include files
    expect(completionStrings.some(c => c.includes('not-a-dir.txt'))).toBe(false)

    // Should NOT include non-existent directories like 'benchmark'
    expect(completionStrings.some(c => c.includes('benchmark'))).toBe(false)
  })

  it('should validate directory existence when providing partial matches', () => {
    const completions = shell.getCompletions('cd ex', 5)
    const completionStrings = Array.isArray(completions) ? completions.map(c => typeof c === 'string' ? c : c.text || '') : []

    // Should suggest existing-dir since it matches 'ex' prefix
    expect(completionStrings.some(c => c.includes('existing-dir'))).toBe(true)

    // Should NOT suggest non-existent directories starting with 'ex'
    expect(completionStrings.every(c => !c.includes('example') && !c.includes('external'))).toBe(true)
  })

  it('should include semantic completions (-, ~, ..)', () => {
    // Set OLDPWD to ensure cd - completion works
    const originalOldPwd = process.env.OLDPWD
    process.env.OLDPWD = '/some/old/path'

    try {
      const completions = shell.getCompletions('cd ', 3)
      const completionStrings = Array.isArray(completions) ? completions.map(c => typeof c === 'string' ? c : c.text || '') : []

      // Should include semantic options (they may be prefixed with 'cd ')
      expect(completionStrings.some(c => c.includes('-') || c === 'cd -')).toBe(true)
      expect(completionStrings.some(c => c.includes('~') || c === 'cd ~')).toBe(true)
      expect(completionStrings.some(c => c.includes('..') || c === 'cd ..')).toBe(true)
    }
    finally {
      // Restore original OLDPWD
      if (originalOldPwd !== undefined) {
        process.env.OLDPWD = originalOldPwd
      }
      else {
        delete process.env.OLDPWD
      }
    }
  })

  it('should reproduce the benchmark issue in krusty directory', () => {
    // Change back to actual krusty directory
    shell.changeDirectory('/Users/chrisbreuer/Code/krusty')

    const completions = shell.getCompletions('cd ', 3)
    const completionStrings = Array.isArray(completions) ? completions.map(c => typeof c === 'string' ? c : c.text || '') : []

    // Should only suggest directories that actually exist
    const directorySuggestions = completionStrings.filter(c => typeof c === 'string' && !c.endsWith('-') && !c.endsWith('~') && !c.endsWith('..'))

    for (const suggestion of directorySuggestions) {
      const dirName = suggestion.replace(/\/$/, '')
      // Each suggested directory should actually exist
      expect(existsSync(join('/Users/chrisbreuer/Code/krusty', dirName))).toBe(true)
    }
  })
})
