import { beforeEach, describe, expect, it } from 'bun:test'
import { spawn } from 'bun'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

describe('calc builtin - e2e tests', () => {
  const runKrustyCommand = async (command: string): Promise<{ stdout: string; stderr: string; exitCode: number }> => {
    const testDir = dirname(import.meta.url.replace('file://', ''))
    const cliWrapper = join(testDir, 'cli-wrapper.js')
    const proc = spawn(['bun', cliWrapper, 'exec', command], {
      cwd: join(testDir, '..'),
      stdout: 'pipe',
      stderr: 'pipe',
    })

    const stdout = await new Response(proc.stdout).text()
    const stderr = await new Response(proc.stderr).text()
    const exitCode = await proc.exited

    return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode }
  }

  describe('basic arithmetic', () => {
    it('should handle addition', async () => {
      const result = await runKrustyCommand('calc 2 + 3')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('5')
      expect(result.stderr).toBe('')
    })

    it('should handle subtraction', async () => {
      const result = await runKrustyCommand('calc 10 - 4')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('6')
    })

    it('should handle multiplication', async () => {
      const result = await runKrustyCommand('calc 6 * 7')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('42')
    })

    it('should handle division', async () => {
      const result = await runKrustyCommand('calc 15 / 3')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('5')
    })

    it('should handle complex expressions', async () => {
      const result = await runKrustyCommand('calc "(2 + 3) * 4"')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('20')
    })

    it('should handle order of operations', async () => {
      const result = await runKrustyCommand('calc "2 + 3 * 4"')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('14')
    })
  })

  describe('mathematical functions', () => {
    it('should handle sqrt function', async () => {
      const result = await runKrustyCommand('calc "sqrt(16)"')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('4')
    })

    it('should handle sin function', async () => {
      const result = await runKrustyCommand('calc "sin(0)"')

      expect(result.exitCode).toBe(0)
      expect(parseFloat(result.stdout)).toBeCloseTo(0, 10)
    })

    it('should handle cos function', async () => {
      const result = await runKrustyCommand('calc "cos(0)"')

      expect(result.exitCode).toBe(0)
      expect(parseFloat(result.stdout)).toBeCloseTo(1, 10)
    })

    it('should handle pi constant', async () => {
      const result = await runKrustyCommand('calc "pi"')

      expect(result.exitCode).toBe(0)
      expect(parseFloat(result.stdout)).toBeCloseTo(Math.PI, 10)
    })

    it('should handle trigonometry with pi', async () => {
      const result = await runKrustyCommand('calc "sin(pi/2)"')

      expect(result.exitCode).toBe(0)
      expect(parseFloat(result.stdout)).toBeCloseTo(1, 10)
    })
  })

  describe('exponentiation', () => {
    it('should handle ^ operator', async () => {
      const result = await runKrustyCommand('calc "2^3"')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('8')
    })

    it('should handle ** operator', async () => {
      const result = await runKrustyCommand('calc "2**4"')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toBe('16')
    })
  })

  describe('error handling', () => {
    it('should handle division by zero', async () => {
      const result = await runKrustyCommand('calc "1/0"')

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('not finite')
    })

    it('should handle invalid expressions', async () => {
      const result = await runKrustyCommand('calc "2 +"')

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('calc:')
    })

    it('should reject dangerous expressions', async () => {
      const result = await runKrustyCommand('calc "eval(\\"alert(1)\\")"')

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Invalid or unsafe')
    })

    it('should show help', async () => {
      const result = await runKrustyCommand('calc --help')

      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: calc [expression]')
      expect(result.stdout).toContain('sqrt(), cbrt()')
    })

    it('should show error for missing expression', async () => {
      const result = await runKrustyCommand('calc')

      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('missing expression')
    })
  })
})