import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Proc-Monitor Builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(async () => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(async () => {
    shell.stop()
  })

  describe('help and basic functionality', () => {
    it('should show help message', async () => {
      const result = await shell.execute('proc-monitor --help')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: proc-monitor [command] [options]')
      expect(result.stdout).toContain('Monitor running processes and system activity')
      expect(result.stdout).toContain('list')
      expect(result.stdout).toContain('top')
      expect(result.stdout).toContain('find PATTERN')
      expect(result.stdout).toContain('tree')
      expect(result.stdout).toContain('current')
    })

    it('should default to current command when no args', async () => {
      const result = await shell.execute('proc-monitor')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Current Process Information')
    })

    it('should handle unknown commands', async () => {
      const result = await shell.execute('proc-monitor unknown-command')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown command: unknown-command')
    })
  })

  describe('current command', () => {
    it('should show current process information', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Current Process Information')
      expect(result.stdout).toContain('PID:')
      expect(result.stdout).toContain('Name: krusty')
      expect(result.stdout).toContain('User:')
      expect(result.stdout).toContain('Status: running')
    })

    it('should show memory usage for current process', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Memory Usage:')
      expect(result.stdout).toContain('RSS:')
      expect(result.stdout).toContain('Heap Used:')
      expect(result.stdout).toContain('Heap Total:')
      expect(result.stdout).toMatch(/\d+\.\d+\s+(B|KB|MB|GB)/)
    })

    it('should show parent PID when available', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      if (process.ppid) {
        expect(result.stdout).toContain('Parent PID:')
      }
    })

    it('should output JSON format', async () => {
      const result = await shell.execute('proc-monitor current -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(data).toHaveProperty('pid')
      expect(data).toHaveProperty('name')
      expect(data).toHaveProperty('user')
      expect(data.name).toBe('krusty')
    })

    it('should disable colors with --no-color', async () => {
      const result = await shell.execute('proc-monitor current --no-color')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('\x1b[') // ANSI color codes
    })
  })

  describe('parent command', () => {
    it('should show parent process information', async () => {
      const result = await shell.execute('proc-monitor parent')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Parent Process Information')

      if (process.ppid) {
        expect(result.stdout).toContain('Parent PID:')
        expect(result.stdout).toContain(process.ppid.toString())
      } else {
        expect(result.stdout).toContain('No parent process information available')
      }
    })

    it('should output JSON format for parent', async () => {
      const result = await shell.execute('proc-monitor parent -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(data).toHaveProperty('ppid')
    })
  })

  describe('list command', () => {
    it('should list processes', async () => {
      const result = await shell.execute('proc-monitor list')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Process List')
      expect(result.stdout).toContain('PID')
      expect(result.stdout).toContain('NAME')
      expect(result.stdout).toContain('USER')
      expect(result.stdout).toContain('STATUS')
      expect(result.stdout).toContain('krusty')
    })

    it('should limit results with -n option', async () => {
      const result = await shell.execute('proc-monitor list -n 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Process List')
    })

    it('should filter by user', async () => {
      const currentUser = process.env.USER || 'unknown'
      const result = await shell.execute(`proc-monitor list -u ${currentUser}`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Process List')
    })

    it('should filter by PID', async () => {
      const result = await shell.execute(`proc-monitor list -p ${process.pid}`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Process List')
      expect(result.stdout).toContain(process.pid.toString())
    })

    it('should output JSON format for list', async () => {
      const result = await shell.execute('proc-monitor list -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(Array.isArray(data)).toBe(true)
      expect(data.length).toBeGreaterThan(0)
      expect(data[0]).toHaveProperty('pid')
      expect(data[0]).toHaveProperty('name')
    })

    it('should sort by different fields', async () => {
      const sortFields = ['pid', 'name', 'cpu', 'memory']
      for (const field of sortFields) {
        const result = await shell.execute(`proc-monitor list -s ${field}`)
        expect(result.exitCode).toBe(0)
      }
    })
  })

  describe('top command', () => {
    it('should show top processes', async () => {
      const result = await shell.execute('proc-monitor top')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Top Processes')
      expect(result.stdout).toContain('CPU%')
      expect(result.stdout).toContain('MEMORY')
      expect(result.stdout).toContain('simulated in this environment')
    })

    it('should limit top results', async () => {
      const result = await shell.execute('proc-monitor top -n 5')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Top Processes')
    })

    it('should output JSON format for top', async () => {
      const result = await shell.execute('proc-monitor top -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(Array.isArray(data)).toBe(true)
      if (data.length > 0) {
        expect(data[0]).toHaveProperty('cpu')
        expect(data[0]).toHaveProperty('memory')
      }
    })
  })

  describe('find command', () => {
    it('should find processes by pattern', async () => {
      const result = await shell.execute('proc-monitor find krusty')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('krusty')
    })

    it('should handle case insensitive search', async () => {
      const result = await shell.execute('proc-monitor find KRUSTY')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('krusty')
    })

    it('should require search pattern', async () => {
      const result = await shell.execute('proc-monitor find')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Search pattern is required')
    })

    it('should output JSON format for find', async () => {
      const result = await shell.execute('proc-monitor find krusty -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(Array.isArray(data)).toBe(true)
    })

    it('should find no matches for non-existent pattern', async () => {
      const result = await shell.execute('proc-monitor find nonexistentprocess12345')
      expect(result.exitCode).toBe(0)
      // Should return empty list or no matches
    })
  })

  describe('tree command', () => {
    it('should show process tree', async () => {
      const result = await shell.execute('proc-monitor tree')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Process Tree')
      expect(result.stdout).toContain('krusty')
      expect(result.stdout).toMatch(/├─/)
      expect(result.stdout).toContain('Limited process tree in this environment')
    })

    it('should output JSON format for tree', async () => {
      const result = await shell.execute('proc-monitor tree -j')
      expect(result.exitCode).toBe(0)

      expect(() => JSON.parse(result.stdout)).not.toThrow()
      const data = JSON.parse(result.stdout)
      expect(Array.isArray(data)).toBe(true)
    })

    it('should show process hierarchy', async () => {
      const result = await shell.execute('proc-monitor tree')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain(`(${process.pid})`)
    })
  })

  describe('options and error handling', () => {
    it('should handle unknown options', async () => {
      const result = await shell.execute('proc-monitor list --unknown-option')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown option')
    })

    it('should handle invalid PID', async () => {
      const result = await shell.execute('proc-monitor list -p invalid')
      expect(result.exitCode).toBe(0) // Invalid PID is handled gracefully
    })

    it('should handle invalid limit', async () => {
      const result = await shell.execute('proc-monitor list -n invalid')
      expect(result.exitCode).toBe(0) // Invalid limit defaults to 20
    })

    it('should handle invalid sort field', async () => {
      const result = await shell.execute('proc-monitor list -s invalid')
      expect(result.exitCode).toBe(0) // Invalid sort field defaults to pid
    })

    it('should handle verbose flag', async () => {
      const result = await shell.execute('proc-monitor current -v')
      expect(result.exitCode).toBe(0)
      // Verbose flag doesn't affect output in current implementation
    })

    it('should handle watch option (though not implemented)', async () => {
      const result = await shell.execute('proc-monitor list -w 1')
      expect(result.exitCode).toBe(0)
    })
  })

  describe('memory formatting', () => {
    it('should format memory sizes correctly', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toMatch(/\d+\.\d+\s+(B|KB|MB|GB)/)
    })

    it('should show memory in top processes', async () => {
      const result = await shell.execute('proc-monitor top')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toMatch(/\d+\.\d+\s+(B|KB|MB|GB)/)
    })
  })

  describe('process information validation', () => {
    it('should show valid PID', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain(`PID: ${process.pid}`)
    })

    it('should show valid user', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      const expectedUser = process.env.USER || 'unknown'
      expect(result.stdout).toContain(`User: ${expectedUser}`)
    })

    it('should show command line when available', async () => {
      const result = await shell.execute('proc-monitor current')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Command:')
    })
  })
})