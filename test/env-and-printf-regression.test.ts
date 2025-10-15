import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('env and printf regression', () => {
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

  it('env prints KEY=VALUE lines sorted and includes config env vars', async () => {
    const res = await shell.execute('env')
    expect(res.exitCode).toBe(0)
    const lines = res.stdout.trim().split('\n').filter(Boolean)
    // all lines should be in KEY=VALUE format
    for (const line of lines) {
      expect(line).toMatch(/^[A-Z_]\w*=/i)
    }
    // sorted ascending
    const keys = lines.map(l => l.split('=')[0])
    const sorted = [...keys].sort((a, b) => a.localeCompare(b))
    expect(keys).toEqual(sorted)
    // includes provided env vars
    expect(res.stdout).toContain('AAA_TEST=2')
    expect(res.stdout).toContain('ZZZ_TEST=1')
    // includes PWD
    expect(res.stdout).toMatch(/\n?PWD=|^PWD=/)
  })

  it('printf ignores extra args beyond format specifiers', async () => {
    const res = await shell.execute('printf "%s" a b c')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toBe('a')
  })
})
