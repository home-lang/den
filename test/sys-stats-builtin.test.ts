import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Sys-Stats Builtin', () => {
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
      const result = await shell.execute('sys-stats --help')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: sys-stats [options]')
      expect(result.stdout).toContain('Display system resource usage and statistics')
      expect(result.stdout).toContain('-c, --cpu')
      expect(result.stdout).toContain('-m, --memory')
      expect(result.stdout).toContain('-j, --json')
    })

    it('should show all stats by default', async () => {
      const result = await shell.execute('sys-stats')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('System Statistics')
      expect(result.stdout).toContain('System Information')
      expect(result.stdout).toContain('CPU Usage')
      expect(result.stdout).toContain('Memory Usage')
    })
  })

  describe('individual stat sections', () => {
    it('should show only CPU stats', async () => {
      const result = await shell.execute('sys-stats -c')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('CPU Usage')
      expect(result.stdout).toContain('User Time:')
      expect(result.stdout).toContain('System Time:')
      expect(result.stdout).not.toContain('Memory Usage')
    })

    it('should show only memory stats', async () => {
      const result = await shell.execute('sys-stats -m')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Memory Usage')
      expect(result.stdout).toContain('RSS')
      expect(result.stdout).toContain('Heap Used')
      expect(result.stdout).toContain('Heap Total')
      expect(result.stdout).not.toContain('CPU Usage')
    })

    it('should show only disk stats', async () => {
      const result = await shell.execute('sys-stats -d')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Disk Information')
      expect(result.stdout).toContain('Current Directory')
      expect(result.stdout).not.toContain('Memory Usage')
    })

    it('should show only network stats', async () => {
      const result = await shell.execute('sys-stats -n')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Network Information')
      expect(result.stdout).not.toContain('Memory Usage')
    })

    it('should show only system info', async () => {
      const result = await shell.execute('sys-stats -s')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('System Information')
      expect(result.stdout).toContain('Platform:')
      expect(result.stdout).toContain('Architecture:')
      expect(result.stdout).toContain('Uptime:')
      expect(result.stdout).not.toContain('Memory Usage')
    })
  })

  describe('combined options', () => {
    it('should show CPU and memory stats together', async () => {
      const result = await shell.execute('sys-stats -c -m')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('CPU Usage')
      expect(result.stdout).toContain('Memory Usage')
      expect(result.stdout).not.toContain('System Information')
    })

    it('should show all stats with --all flag', async () => {
      const result = await shell.execute('sys-stats --all')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('System Information')
      expect(result.stdout).toContain('CPU Usage')
      expect(result.stdout).toContain('Memory Usage')
      expect(result.stdout).toContain('Disk Information')
      expect(result.stdout).toContain('Network Information')
    })
  })

  describe('output formats', () => {
    it('should output JSON format', async () => {
      const result = await shell.execute('sys-stats -j')
      expect(result.exitCode).toBe(0)

      // Should be valid JSON
      expect(() => JSON.parse(result.stdout)).not.toThrow()

      const data = JSON.parse(result.stdout)
      expect(data).toHaveProperty('system')
      expect(data).toHaveProperty('cpu')
      expect(data).toHaveProperty('memory')
      expect(data).toHaveProperty('timestamp')
    })

    it('should output JSON for specific sections', async () => {
      const result = await shell.execute('sys-stats -m -j')
      expect(result.exitCode).toBe(0)

      const data = JSON.parse(result.stdout)
      expect(data).toHaveProperty('memory')
      expect(data).not.toHaveProperty('system')
      expect(data.memory).toHaveProperty('rss')
      expect(data.memory).toHaveProperty('heapUsed')
    })

    it('should disable colors with --no-color', async () => {
      const result = await shell.execute('sys-stats -m --no-color')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).not.toContain('\x1b[') // ANSI color codes
    })
  })

  describe('memory stats validation', () => {
    it('should show formatted memory sizes', async () => {
      const result = await shell.execute('sys-stats -m')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toMatch(/RSS.*MB/)
      expect(result.stdout).toMatch(/Heap.*MB|KB/)
      expect(result.stdout).toMatch(/\d+\.\d+%/) // Percentage
    })

    it('should include all memory fields', async () => {
      const result = await shell.execute('sys-stats -m -j')
      expect(result.exitCode).toBe(0)

      const data = JSON.parse(result.stdout)
      expect(data.memory).toHaveProperty('rss')
      expect(data.memory).toHaveProperty('heapTotal')
      expect(data.memory).toHaveProperty('heapUsed')
      expect(data.memory).toHaveProperty('external')
      expect(data.memory).toHaveProperty('arrayBuffers')
      expect(data.memory).toHaveProperty('heapUsagePercent')
    })
  })

  describe('system info validation', () => {
    it('should show platform and architecture', async () => {
      const result = await shell.execute('sys-stats -s')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Platform:')
      expect(result.stdout).toContain('Architecture:')
      expect(result.stdout).toMatch(/Platform: (darwin|linux|win32)/)
      expect(result.stdout).toMatch(/Architecture: (x64|arm64|ia32)/)
    })

    it('should show uptime in readable format', async () => {
      const result = await shell.execute('sys-stats -s')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toMatch(/Uptime: \d+/)
    })

    it('should include runtime version', async () => {
      const result = await shell.execute('sys-stats -s')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Runtime:')
      expect(result.stdout).toMatch(/Runtime: v\d+\.\d+\.\d+/)
    })
  })

  describe('CPU stats validation', () => {
    it('should show CPU time information', async () => {
      const result = await shell.execute('sys-stats -c')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('User Time:')
      expect(result.stdout).toContain('System Time:')
      expect(result.stdout).toContain('Total Time:')
      expect(result.stdout).toMatch(/\d+.*μs/) // Microseconds
    })

    it('should include limitation notice', async () => {
      const result = await shell.execute('sys-stats -c')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('N/A (limited access)')
    })
  })

  describe('timestamp and formatting', () => {
    it('should include timestamp', async () => {
      const result = await shell.execute('sys-stats')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Last updated:')
      expect(result.stdout).toMatch(/\d{1,2}\/\d{1,2}\/\d{4}/)
    })

    it('should have proper section headers', async () => {
      const result = await shell.execute('sys-stats')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('📊 System Information')
      expect(result.stdout).toContain('🖥️  CPU Usage')
      expect(result.stdout).toContain('💾 Memory Usage')
      expect(result.stdout).toContain('💿 Disk Information')
      expect(result.stdout).toContain('🌐 Network Information')
    })
  })

  describe('error handling', () => {
    it('should handle unknown options', async () => {
      const result = await shell.execute('sys-stats --unknown-option')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown option')
    })

    it('should handle invalid watch seconds', async () => {
      const result = await shell.execute('sys-stats -w invalid')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown option')
    })
  })
})