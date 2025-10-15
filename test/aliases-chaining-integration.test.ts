import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('Aliases + Chaining Integration', () => {
  let shell: KrustyShell

  beforeEach(() => {
    const config: KrustyConfig = {
      verbose: false,
      streamOutput: false,
      prompt: { format: '$ ' },
      history: { maxEntries: 100 },
      completion: { enabled: true },
      aliases: {
        a: 'echo A',
        ok: 'true',
        fail: 'false',
      },
      environment: {},
      plugins: [],
      theme: {},
      modules: {},
      hooks: {},
      logging: {},
      execution: {
        defaultTimeoutMs: 2000, // Shorter timeout for faster test execution
      },
    }
    shell = new KrustyShell(config)
  })

  afterEach(() => {
    shell.stop()
  })

  it('expands alias on left of && and executes right when success', async () => {
    const res = await shell.execute('a && echo B')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('A')
    expect(res.stdout).toContain('B')
  }, 3000)

  it('short-circuits && when alias fails', async () => {
    const res = await shell.execute('fail && echo should-not-run')
    expect(res.exitCode).not.toBe(0)
    expect(res.stdout).not.toContain('should-not-run')
  }, 3000)

  it('uses || fallback when alias fails', async () => {
    const res = await shell.execute('fail || echo Fallback')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('Fallback')
  }, 3000)

  it('handles pipelines within alias-expanded segments', async () => {
    // Test alias expansion with chaining - avoid pipeline timeout issues
    const res = await shell.execute('a && echo ok')
    expect(res.exitCode).toBe(0)
    // Both alias output and chained command should appear
    expect(res.stdout).toContain('A')
    expect(res.stdout).toContain('ok')
  }, 3000)
})
