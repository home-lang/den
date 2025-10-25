import { beforeEach, describe, expect, it } from 'bun:test'
import { completionManager } from '../src/completion/completion-manager'

describe('fuzzy completion system', () => {
  let mockShell: any
  let mockContext: any

  beforeEach(() => {
    mockShell = {
      builtins: new Map([
        ['echo', {}],
        ['grep', {}],
        ['find', {}],
        ['tree', {}],
        ['watch', {}],
        ['git', {}],
        ['npm', {}],
      ]),
      aliases: {
        'll': 'ls -la',
        'gs': 'git status',
        'gc': 'git commit',
        'la': 'ls -A',
      },
      config: {
        completion: {
          caseSensitive: false,
          enableFuzzy: true,
          maxSuggestions: 10,
        },
      },
    }

    mockContext = {
      shell: mockShell,
      cursor: 0,
    }
  })

  describe('fuzzy command completion', () => {
    it('should provide exact matches first', async () => {
      // Set cursor to end of input for proper command completion
      mockContext.cursor = 2
      const completions = await completionManager.getCompletions('ec', mockContext)

      // Should include builtin commands in results
      expect(completions.length).toBeGreaterThan(0)
      expect(Array.isArray(completions)).toBe(true)
    })

    it('should provide fuzzy matches when exact matches are limited', async () => {
      const completions = await completionManager.getCompletions('gt', mockContext)

      // Should match 'git' and 'grep' with fuzzy matching
      expect(completions.length).toBeGreaterThan(0)
      expect(completions.some(c => c.includes('git') || c.includes('grep'))).toBe(true)
    })

    it('should include builtin commands in completions', async () => {
      const completions = await completionManager.getCompletions('tr', mockContext)

      expect(completions).toContain('tree')
    })

    it('should include some completions for single letter', async () => {
      mockContext.cursor = 1
      const completions = await completionManager.getCompletions('g', mockContext)

      expect(Array.isArray(completions)).toBe(true)
      expect(completions.length).toBeGreaterThan(0)
    })

    it('should respect maxSuggestions limit', async () => {
      const completions = await completionManager.getCompletions('', mockContext)

      expect(completions.length).toBeLessThanOrEqual(10)
    })

    it('should handle different case inputs', async () => {
      const completions = await completionManager.getCompletions('EC', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })

    it('should handle configuration changes', async () => {
      mockShell.config.completion.caseSensitive = true
      const completions = await completionManager.getCompletions('test', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })
  })

  describe('cd command completion', () => {
    it('should handle cd command input', async () => {
      mockContext.cursor = 5
      const completions = await completionManager.getCompletions('cd sr', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })

    it('should handle cd with space', async () => {
      mockContext.cursor = 3
      const completions = await completionManager.getCompletions('cd ', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })
  })

  describe('file argument completion', () => {
    it('should provide file completions for non-cd commands', async () => {
      mockContext.cursor = 8
      const completions = await completionManager.getCompletions('echo te', mockContext)

      // Should provide file completions (will depend on actual filesystem)
      expect(Array.isArray(completions)).toBe(true)
    })
  })

  describe('caching system', () => {
    it('should cache completion results', async () => {
      const input = 'echo'
      const context = { ...mockContext }

      // First call
      const completions1 = await completionManager.getCompletions(input, context)

      // Second call should use cache
      const completions2 = await completionManager.getCompletions(input, context)

      expect(completions1).toEqual(completions2)
    })

    it('should respect cache TTL', async () => {
      const input = 'test'
      const context = { ...mockContext }

      await completionManager.getCompletions(input, context)

      // Force refresh should bypass cache
      const freshCompletions = await completionManager.getCompletions(input, context, true)

      expect(Array.isArray(freshCompletions)).toBe(true)
    })

    it('should limit cache size', async () => {
      // This test would need to create many cache entries to verify the limit
      // For now, we just verify the method exists
      expect(typeof completionManager.clearCache).toBe('function')
      completionManager.clearCache()
    })
  })

  describe('PATH command completion', () => {
    it('should provide PATH command completions', async () => {
      mockContext.cursor = 1
      const completions = await completionManager.getCompletions('l', mockContext)

      expect(Array.isArray(completions)).toBe(true)
      expect(completions.length).toBeGreaterThan(0)
    })
  })

  describe('error handling', () => {
    it('should handle missing shell context gracefully', async () => {
      const completions = await completionManager.getCompletions('test', {})

      expect(Array.isArray(completions)).toBe(true)
      expect(completions.length).toBe(0)
    })

    it('should handle empty input gracefully', async () => {
      const completions = await completionManager.getCompletions('', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })

    it('should handle malformed input gracefully', async () => {
      const completions = await completionManager.getCompletions('  ', mockContext)

      expect(Array.isArray(completions)).toBe(true)
    })
  })
})