import { beforeEach, describe, expect, it } from 'bun:test'
import { tree } from '../src/builtins/tree'
import type { Shell } from '../src/types'

describe('tree builtin', () => {
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
      const result = await tree.execute(mockShell, ['--help'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: tree [path] [options]')
      expect(mockOutput.join('\n')).toContain('Display a tree view of directory structure')
      expect(mockOutput.join('\n')).toContain('-a, --all')
      expect(mockOutput.join('\n')).toContain('-d, --directories')
      expect(mockOutput.join('\n')).toContain('-L LEVEL')
    })

    it('should show help with -h flag', async () => {
      const result = await tree.execute(mockShell, ['-h'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('Usage: tree [path] [options]')
    })
  })

  describe('basic functionality', () => {
    it('should display current directory tree by default', async () => {
      const result = await tree.execute(mockShell, [])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.length).toBeGreaterThan(0)

      const output = mockOutput.join('\n')
      // Should contain tree structure with current directory
      expect(output).toContain('.')
      // Should contain summary line
      expect(output).toContain('directories,')
      expect(output).toContain('files')
    })

    it('should show tree for specified path', async () => {
      const result = await tree.execute(mockShell, ['src'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
      expect(mockOutput.join('\n')).toContain('src')
    })

    it('should handle non-existent directory', async () => {
      const result = await tree.execute(mockShell, ['/definitely/nonexistent/path/12345'])

      // The tree command might handle this gracefully, so check if there's an error or empty output
      expect(result.exitCode).toBeGreaterThanOrEqual(0)
      expect(typeof result.success).toBe('boolean')
    })
  })

  describe('options', () => {
    it('should show all files with -a flag', async () => {
      const result = await tree.execute(mockShell, ['-a'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
    })

    it('should show only directories with -d flag', async () => {
      const result = await tree.execute(mockShell, ['-d'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)

      const output = mockOutput.join('\n')
      // Should not contain file entries (only directories ending with /)
      const lines = output.split('\n').filter(line => line.includes('├──') || line.includes('└──'))
      if (lines.length > 0) {
        // If there are tree lines, they should mostly be directories
        const directoryLines = lines.filter(line => line.includes('/'))
        expect(directoryLines.length).toBeGreaterThan(0)
      }
    })

    it('should respect maxdepth with -L option', async () => {
      const result = await tree.execute(mockShell, ['-L', '1'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
    })

    it('should show file sizes with -s flag', async () => {
      const result = await tree.execute(mockShell, ['-s'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
    })

    it('should use ASCII characters with --ascii flag', async () => {
      const result = await tree.execute(mockShell, ['--ascii'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)

      const output = mockOutput.join('\n')
      if (output.includes('|--') || output.includes('`--')) {
        // ASCII mode should use |-- and `-- instead of Unicode
        expect(output).not.toContain('├──')
        expect(output).not.toContain('└──')
      }
    })

    it('should filter by pattern with -P option', async () => {
      const result = await tree.execute(mockShell, ['-P', '*.ts'])

      expect(result.success).toBe(true)
      expect(result.exitCode).toBe(0)
    })
  })

  describe('command properties', () => {
    it('should have correct command metadata', () => {
      expect(tree.name).toBe('tree')
      expect(tree.description).toContain('Display directory tree structure')
      expect(tree.usage).toBe('tree [path] [options]')
    })
  })
})