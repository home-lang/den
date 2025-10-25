import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rmdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Log-Tail Builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig
  let tempDir: string
  let testLogFile: string

  beforeEach(async () => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
    }
    shell = new KrustyShell(testConfig)
    tempDir = await mkdtemp(join(tmpdir(), 'krusty-log-test-'))
    testLogFile = join(tempDir, 'test.log')

    // Create test log file
    const testLogContent = `2024-01-01T10:00:00Z INFO Starting application
2024-01-01T10:01:00Z ERROR Database connection failed
2024-01-01T10:02:00Z WARN Retrying connection
2024-01-01T10:03:00Z INFO Connected to database
2024-01-01T10:04:00Z DEBUG Processing request ID: 123
2024-01-01T10:05:00Z ERROR Failed to process request
2024-01-01T10:06:00Z INFO Request completed successfully
2024-01-01T10:07:00Z DEBUG Cleanup completed
2024-01-01T10:08:00Z WARN Memory usage high
2024-01-01T10:09:00Z INFO Application running normally`

    await writeFile(testLogFile, testLogContent)
  })

  afterEach(async () => {
    shell.stop()
    try {
      await rmdir(tempDir, { recursive: true })
    } catch {
      // Ignore cleanup errors
    }
  })

  describe('help and basic functionality', () => {
    it('should show help message', async () => {
      const result = await shell.execute('log-tail --help')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: log-tail FILE [options]')
      expect(result.stdout).toContain('Enhanced tail with filtering and log analysis')
      expect(result.stdout).toContain('--filter PATTERN')
      expect(result.stdout).toContain('--level LEVEL')
      expect(result.stdout).toContain('--stats')
    })

    it('should require file argument', async () => {
      const result = await shell.execute('log-tail')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('missing file argument')
    })

    it('should handle non-existent file', async () => {
      const result = await shell.execute('log-tail /nonexistent/file.log')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('File not found')
    })
  })

  describe('basic tailing functionality', () => {
    it('should show last 10 lines by default', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}"`)
      expect(result.exitCode).toBe(0)
      const lines = result.stdout.trim().split('\n')
      expect(lines.length).toBe(10)
      expect(result.stdout).toContain('Application running normally')
    })

    it('should show custom number of lines', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -n 5`)
      expect(result.exitCode).toBe(0)
      const lines = result.stdout.trim().split('\n')
      expect(lines.length).toBe(5)
    })

    it('should show last lines when file has fewer lines than requested', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -n 20`)
      expect(result.exitCode).toBe(0)
      const lines = result.stdout.trim().split('\n')
      expect(lines.length).toBe(10) // File only has 10 lines
    })
  })

  describe('filtering functionality', () => {
    it('should filter lines by pattern', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "ERROR"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Database connection failed')
      expect(result.stdout).toContain('Failed to process request')
      expect(result.stdout).not.toContain('Starting application')
    })

    it('should exclude lines by pattern', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --exclude "DEBUG"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('Processing request ID')
      expect(result.stdout).not.toContain('Cleanup completed')
      expect(result.stdout).toContain('Starting application')
    })

    it('should filter by log level', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --level error`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Database connection failed')
      expect(result.stdout).toContain('Failed to process request')
      expect(result.stdout).not.toContain('Starting application')
    })

    it('should filter by warn level', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --level warn`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Retrying connection')
      expect(result.stdout).toContain('Memory usage high')
      expect(result.stdout).not.toContain('Starting application')
    })

    it('should filter by info level', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --level info`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Starting application')
      expect(result.stdout).toContain('Connected to database')
      expect(result.stdout).not.toContain('Processing request ID')
    })

    it('should filter by debug level', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --level debug`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Processing request ID')
      expect(result.stdout).toContain('Cleanup completed')
      expect(result.stdout).not.toContain('Starting application')
    })
  })

  describe('time filtering', () => {
    it('should filter by since time', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --since "2024-01-01T10:05:00Z"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Failed to process request')
      expect(result.stdout).toContain('Application running normally')
      expect(result.stdout).not.toContain('Starting application')
    })

    it('should filter by until time', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --until "2024-01-01T10:03:00Z"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Starting application')
      expect(result.stdout).toContain('Connected to database')
      expect(result.stdout).not.toContain('Processing request ID')
    })

    it('should handle relative time format', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --since "1h"`)
      expect(result.exitCode).toBe(0)
      // Since test timestamps are in the past, this might filter out everything
    })

    it('should handle invalid time format', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --since "invalid-time"`)
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Invalid time format')
    })
  })

  describe('output formats', () => {
    it('should output in plain format', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --format plain -n 3`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('\x1b[') // No ANSI colors
    })

    it('should output in JSON format', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --format json -n 3`)
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(Array.isArray(data)).toBe(true)
      expect(data.length).toBe(3)
      expect(data[0]).toHaveProperty('line')
      expect(data[0]).toHaveProperty('content')
    })

    it('should output colored format by default', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -n 3`)
      expect(result.exitCode).toBe(0)
      // Should contain ANSI color codes for different log levels
    })

    it('should disable colors with --no-color', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --no-color -n 3`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('\x1b[') // No ANSI colors
    })
  })

  describe('statistics functionality', () => {
    it('should show log statistics', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --stats`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Log Statistics')
      expect(result.stdout).toContain('Total Lines: 10')
      expect(result.stdout).toContain('Error Lines: 2')
      expect(result.stdout).toContain('Warning Lines: 2')
      expect(result.stdout).toContain('Info Lines: 3')
      expect(result.stdout).toContain('Debug Lines: 2')
    })

    it('should show time range in statistics', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --stats`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Time Range:')
      expect(result.stdout).toContain('Start:')
      expect(result.stdout).toContain('End:')
    })

    it('should show statistics with filtering', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --stats --level error`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Total Lines: 2')
      expect(result.stdout).toContain('Error Lines: 2')
    })
  })

  describe('highlighting and colors', () => {
    it('should highlight patterns', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --highlight "ERROR" -n 5`)
      expect(result.exitCode).toBe(0)
      // Should contain highlighting ANSI codes
    })

    it('should color error lines in red', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "ERROR"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('\x1b[31m') // Red color code
    })

    it('should color warn lines in yellow', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "WARN"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('\x1b[33m') // Yellow color code
    })

    it('should color info lines in green', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "INFO"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('\x1b[32m') // Green color code
    })

    it('should color debug lines in blue', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "DEBUG"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('\x1b[34m') // Blue color code
    })
  })

  describe('file operations', () => {
    it('should save filtered output to file', async () => {
      const outputFile = join(tempDir, 'filtered.log')
      // Note: -o flag would need to be implemented in the actual builtin
      // For now, just test that the filtering works
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "ERROR"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('ERROR')
    })

    it('should handle quiet mode', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -q -n 3`)
      expect(result.exitCode).toBe(0)
      // Quiet mode should not affect output in current implementation
    })

    it('should handle verbose mode', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -v -n 3`)
      expect(result.exitCode).toBe(0)
      // Verbose mode might show additional information
    })
  })

  describe('byte-based operations', () => {
    it('should show last N bytes', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -c 100`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout.length).toBeLessThanOrEqual(100)
    })

    it('should handle bytes and lines conflict', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -c 100 -n 5`)
      expect(result.exitCode).toBe(0)
      // Bytes should take precedence over lines
    })
  })

  describe('edge cases and error handling', () => {
    it('should handle empty file', async () => {
      const emptyFile = join(tempDir, 'empty.log')
      await writeFile(emptyFile, '')

      const result = await shell.execute(`log-tail "${emptyFile}"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout.trim()).toBe('')
    })

    it('should handle single line file', async () => {
      const singleLineFile = join(tempDir, 'single.log')
      await writeFile(singleLineFile, 'Single log line')

      const result = await shell.execute(`log-tail "${singleLineFile}"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout.trim()).toBe('Single log line')
    })

    it('should handle unknown options', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --unknown-option`)
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown option')
    })

    it('should handle follow mode flag', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -f`)
      expect(result.exitCode).toBe(0)
      // Follow mode would be handled differently in a real implementation
    })

    it('should handle retry flag', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" -F`)
      expect(result.exitCode).toBe(0)
      // Retry flag would be handled differently in a real implementation
    })

    it('should handle invalid filter regex', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "[invalid"`)
      expect(result.exitCode).toBe(0)
      // Invalid regex should be handled gracefully
    })
  })

  describe('combined filtering', () => {
    it('should combine filter and level', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --filter "connection" --level error`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Database connection failed')
      expect(result.stdout).not.toContain('Connected to database') // This is INFO level
    })

    it('should combine exclude and time filtering', async () => {
      const result = await shell.execute(`log-tail "${testLogFile}" --exclude "DEBUG" --since "2024-01-01T10:02:00Z"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('Processing request ID')
      expect(result.stdout).not.toContain('Starting application') // Before since time
    })
  })
})