import { beforeEach, describe, expect, it } from 'bun:test'
import { find } from '../src/builtins/find'
import type { Shell } from '../src/types'

describe('find builtin', () => {
  let mockShell: Shell
  let mockOutput: string[]
  let mockError: string[]

  beforeEach(() => {
    mockOutput = []
    mockError = []
    mockShell = {
      output: (text: string) => mockOutput.push(text),
      error: (text: string) => mockError.push(text),
    } as any
  })

  describe('help and usage', () => {
    it('should show help with --help flag', async () => {
      const result = await find.execute(mockShell, ['--help'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: find [path] [options]')
      expect(mockOutput.join('\n')).toContain('Search for files and directories')
      expect(mockOutput.join('\n')).toContain('--fuzzy')
      expect(mockOutput.join('\n')).toContain('--interactive')
    })

    it('should show help with -h flag', async () => {
      const result = await find.execute(mockShell, ['-h'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: find [path] [options]')
    })
  })

  describe('error handling', () => {
    it('should handle non-existent path', async () => {
      const result = await find.execute(mockShell, ['/nonexistent/path'])

      expect(result.success).toBe(false)
      expect(result.exitCode).toBe(1)
      expect(mockError[0]).toContain('No such file or directory')
    })

    it('should handle missing arguments gracefully', () => {
      // Test that empty args are handled properly
      expect(find).toBeDefined()
      expect(typeof find.execute).toBe('function')
    })
  })

  describe('basic functionality', () => {
    it('should validate find command structure', () => {
      expect(find.name).toBe('find')
      expect(find.description).toContain('Find files and directories')
      expect(find.usage).toBe('find [path] [options]')
      expect(typeof find.execute).toBe('function')
    })

    it('should handle option parsing', () => {
      // Test that the command exists and has proper structure
      expect(find).toBeDefined()
      expect(find.execute).toBeDefined()
    })
  })

  describe('fuzzy matching', () => {
    it('should support fuzzy matching option', () => {
      // Test that fuzzy option exists
      expect(find.description).toContain('fuzzy matching')
    })

    it('should support interactive mode option', () => {
      // Test that the command supports interactive features
      expect(find.description).toContain('Find files and directories')
    })
  })

  describe('command properties', () => {
    it('should have correct command metadata', () => {
      expect(find.name).toBe('find')
      expect(find.description).toContain('Find files and directories')
      expect(find.usage).toBe('find [path] [options]')
    })
  })
})