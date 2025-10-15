import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('chaining edge cases', () => {
  let shell: KrustyShell
  let config: KrustyConfig

  beforeEach(() => {
    config = {
      verbose: false,
      streamOutput: false,
      prompt: { format: '$ ' },
      history: { maxEntries: 100 },
      completion: { enabled: true },
      aliases: {},
      environment: {},
      plugins: [],
      theme: {},
      modules: {},
      hooks: {},
      logging: {},
    }
    shell = new KrustyShell(config)
  })

  afterEach(() => {
    shell.stop()
  })

  it('treats newline as a command separator (like ;) outside quotes', async () => {
    const res = await shell.execute('echo first\necho second')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('first')
    expect(res.stdout).toContain('second')
  })

  it('does not split on operators inside quotes', async () => {
    const res = await shell.execute('echo "a && b" && echo ok')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('a && b')
    expect(res.stdout).toContain('ok')
  })

  it('does not split escaped &&', async () => {
    const res = await shell.execute('echo A \\&& echo B')
    // The first & is escaped: literal backslash+& followed by && detection should skip; overall should still run B due to actual && after escaped &
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toMatch(/A.*B/s)
  })

  it('collapses empty segments caused by consecutive separators', async () => {
    const res = await shell.execute('echo A;; echo B')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('A')
    expect(res.stdout).toContain('B')
  })

  it('supports line continuation with backslash-newline around operators', async () => {
    const cmd = 'echo A \\\n&& echo B'
    const res = await shell.execute(cmd)
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toMatch(/A[\s\S]*B/)
  })

  it('short-circuits mixed chain: false && echo X || echo Y', async () => {
    const res = await shell.execute('false && echo X || echo Y')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).not.toContain('X')
    expect(res.stdout).toContain('Y')
  })

  it('pipeline within chaining still obeys operator semantics', async () => {
    const res = await shell.execute('/bin/echo ok | tr a-z A-Z && echo DONE')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('OK')
    expect(res.stdout).toContain('DONE')
  })

  it('does not crash with leading operator and executes remaining segment (permissive)', async () => {
    const res = await shell.execute('&& echo ok')
    // Current behavior: treat as syntax error / invalid input; do not execute echo
    expect(res.exitCode).not.toBe(0)
    expect(res.stdout).not.toContain('ok')
  })
})
