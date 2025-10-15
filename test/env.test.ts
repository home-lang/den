import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('env builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      environment: { ...(defaultConfig as any).environment, ZZZ_TEST: '1', AAA_TEST: '2' },
      history: { ...defaultConfig.history, file: `/tmp/test_history_env_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('prints sorted KEY=VALUE lines (includes PWD by default)', async () => {
    const res = await shell.execute('env')
    expect(res.exitCode).toBe(0)
    const lines = res.stdout.trim().split('\n').filter(Boolean)
    const keys = lines.map(l => l.split('=')[0])
    const sorted = [...keys].sort((a, b) => a.localeCompare(b))
    expect(keys).toEqual(sorted)
    expect(res.stdout).toMatch(/\n?PWD=|^PWD=/)
  })

  it('supports -i to ignore the current environment', async () => {
    const res = await shell.execute('env -i')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toBe('')
  })

  it('applies NAME=VALUE assignment when printing', async () => {
    const res = await shell.execute('env FOO=bar')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('FOO=bar')
  })

  it('runs a command with temporary overrides (per-process env)', async () => {
    const res = await shell.execute('env -i FOO=bar env | grep ^FOO=')
    expect(res.exitCode).toBe(0)
    const out = res.stdout.trim()
    expect(out).toBe('FOO=bar')
  })

  it('allows filtering with pipes while keeping env output sorted', async () => {
    const res = await shell.execute('env | grep TEST')
    expect(res.exitCode).toBe(0)
    const lines = res.stdout.trim().split('\n').filter(Boolean)
    for (const line of lines)
      expect(line).toMatch(/TEST/)
    const keys = lines.map(l => l.split('=')[0])
    const sorted = [...keys].sort((a, b) => a.localeCompare(b))
    expect(keys).toEqual(sorted)
  })

  it('does not mutate the shell environment after running with overrides', async () => {
    const before = await shell.execute('env | grep ^FOO=')
    expect(before.stdout).toBe('')
    const run = await shell.execute('env FOO=bar env | grep ^FOO=')
    expect(run.stdout.trim()).toBe('FOO=bar')
    const after = await shell.execute('env | grep ^FOO=')
    expect(after.stdout).toBe('')
  })
})
