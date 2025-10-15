import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Operator Chaining', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({ ...defaultConfig, verbose: false })
  })

  afterEach(() => {
    shell.stop()
  })

  it('executes sequentially with ;', async () => {
    const result = await shell.execute('echo one; echo two')
    expect(result.exitCode).toBe(0)
    expect(result.stdout).toContain('one')
    expect(result.stdout).toContain('two')
  })

  it('executes right side of && only when left succeeds', async () => {
    const ok = await shell.execute('echo left && echo then')
    expect(ok.exitCode).toBe(0)
    expect(ok.stdout).toContain('then')

    const skip = await shell.execute('nonexistent_cmd_123 && echo then')
    expect(skip.exitCode).not.toBe(0)
    expect(skip.stdout).not.toContain('then')
  })

  it('executes right side of || only when left fails', async () => {
    const fallback = await shell.execute('nonexistent_cmd_456 || echo fallback')
    expect(fallback.exitCode).toBe(0)
    expect(fallback.stdout).toContain('fallback')

    const nofallback = await shell.execute('echo ok || echo fallback')
    expect(nofallback.exitCode).toBe(0)
    expect(nofallback.stdout).not.toContain('fallback')
  })

  it('handles mixed && and || with correct precedence (left to right)', async () => {
    const result = await shell.execute('nonexistent_cmd_789 && echo A || echo B')
    expect(result.exitCode).toBe(0)
    expect(result.stdout).toContain('B')
    expect(result.stdout).not.toContain('A')
  })

  it('respects quotes when splitting operators', async () => {
    const result = await shell.execute('echo "a && b"; echo c')
    expect(result.exitCode).toBe(0)
    expect(result.stdout).toContain('a && b')
    expect(result.stdout).toContain('c')
  })

  it('supports pipes within segments', async () => {
    const result = await shell.execute('echo hi | tr a-z A-Z && echo ok')
    expect(result.exitCode).toBe(0)
    expect(result.stdout).toContain('HI')
    expect(result.stdout).toContain('ok')
  })
})
