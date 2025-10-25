import { beforeEach, afterEach, describe, expect, it } from 'bun:test'
import { writeFileSync, unlinkSync, mkdirSync, rmSync } from 'node:fs'
import { grep } from '../src/builtins/grep'
import type { Shell } from '../src/types'

describe('grep builtin', () => {
  let mockShell: Shell
  let mockOutput: string[]
  let mockError: string[]
  const testDir = '/tmp/krusty-grep-test'
  const testFile = `${testDir}/test.txt`

  beforeEach(() => {
    mockOutput = []
    mockError = []
    mockShell = {
      output: (text: string) => mockOutput.push(text),
      error: (text: string) => mockError.push(text),
    } as any

    // Create test directory and files
    try {
      mkdirSync(testDir, { recursive: true })
      writeFileSync(testFile, `line 1: hello world
line 2: HELLO WORLD
line 3: goodbye world
line 4: test pattern
line 5: another test
line 6: 123 numbers
line 7: /path/to/file
line 8: final line`)
    } catch (error) {
      // Directory might already exist
    }
  })

  afterEach(() => {
    // Clean up test files
    try {
      rmSync(testDir, { recursive: true, force: true })
    } catch (error) {
      // Ignore cleanup errors
    }
  })

  describe('help and usage', () => {
    it('should show help with --help flag', async () => {
      const result = await grep.execute(mockShell, ['--help'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: grep [options] pattern [files...]')
      expect(mockOutput.join('\n')).toContain('Search for patterns in text files')
      expect(mockOutput.join('\n')).toContain('-i, --ignore-case')
      expect(mockOutput.join('\n')).toContain('-n, --line-number')
    })

    it('should show help with -h flag', async () => {
      const result = await grep.execute(mockShell, ['-h'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: grep [options] pattern [files...]')
    })
  })

  describe('error handling', () => {
    it('should handle missing pattern', async () => {
      const result = await grep.execute(mockShell, [])

      expect(result.success).toBe(false)
      expect(result.exitCode).toBe(2)
      expect(mockError.join('')).toContain('missing pattern')
    })

    it('should handle non-existent file', async () => {
      const result = await grep.execute(mockShell, ['pattern', '/nonexistent/file'])

      expect(result.success).toBe(false)
      expect(result.exitCode).toBe(1)
    })

    it('should handle directory as file', async () => {
      const result = await grep.execute(mockShell, ['pattern', testDir])

      expect(result.success).toBe(false)
      expect(result.exitCode).toBe(1)
      expect(mockError.some(msg => msg.includes('Is a directory'))).toBe(true)
    })
  })

  describe('basic pattern matching', () => {
    it('should find simple pattern', async () => {
      const result = await grep.execute(mockShell, ['hello', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.some(line => line.includes('hello world'))).toBe(true)
      expect(mockOutput.some(line => line.includes('HELLO WORLD'))).toBe(false) // Case sensitive by default
    })

    it('should support case-insensitive search with -i', async () => {
      const result = await grep.execute(mockShell, ['-i', 'hello', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.length).toBeGreaterThanOrEqual(1) // Should find at least one hello line
      expect(mockOutput.some(line => line.includes('hello') || line.includes('HELLO'))).toBe(true)
    })

    it('should support inverted match with -v', async () => {
      const result = await grep.execute(mockShell, ['-v', 'hello', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.some(line => line.includes('hello world'))).toBe(false)
      expect(mockOutput.some(line => line.includes('goodbye world'))).toBe(true)
    })

    it('should return exit code 1 when no matches found', async () => {
      const result = await grep.execute(mockShell, ['nonexistent', testFile])

      expect(result.success).toBe(false)
      expect(result.exitCode).toBe(1)
      expect(mockOutput.length).toBe(0)
    })
  })

  describe('output options', () => {
    it('should show line numbers with -n', async () => {
      const result = await grep.execute(mockShell, ['-n', 'test', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.some(line => line.includes('4:'))).toBe(true) // line 4: test pattern
      expect(mockOutput.some(line => line.includes('5:'))).toBe(true) // line 5: another test
    })

    it('should show only count with -c', async () => {
      const result = await grep.execute(mockShell, ['-c', 'test', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput[0]).toBe('2') // Should find 2 matches
    })

    it('should show only filenames with -l', async () => {
      const result = await grep.execute(mockShell, ['-l', 'hello', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput[0]).toContain('test.txt')
    })
  })

  describe('pattern types', () => {
    it('should support fixed strings with -F', async () => {
      const result = await grep.execute(mockShell, ['-F', 'test.*', testFile])

      expect(result.success).toBe(false) // Should not find regex pattern as literal
      expect(result.exitCode).toBe(1)
    })

    it('should support word regexp with -w', async () => {
      const result = await grep.execute(mockShell, ['-w', 'test', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      // Should match whole words only
    })

    it('should support line regexp with -x', async () => {
      const result = await grep.execute(mockShell, ['-x', 'line 1: hello world', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
    })
  })

  describe('context options', () => {
    it('should show after context with -A', async () => {
      const result = await grep.execute(mockShell, ['-A', '1', 'hello world', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      // Should include the line after the match
    })

    it('should show before context with -B', async () => {
      const result = await grep.execute(mockShell, ['-B', '1', 'goodbye', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      // Should include the line before the match
    })

    it('should show context around match with -C', async () => {
      const result = await grep.execute(mockShell, ['-C', '1', 'test pattern', testFile])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      // Should include lines before and after
    })
  })

  describe('command properties', () => {
    it('should have correct command metadata', () => {
      expect(grep.name).toBe('grep')
      expect(grep.description).toContain('Search text patterns in files')
      expect(grep.usage).toBe('grep [options] pattern [files...]')
    })
  })
})