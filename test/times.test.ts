import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('times builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_times_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('prints two lines with user/system times and newline', async () => {
    const res = await shell.execute('times')
    expect(res.exitCode).toBe(0)
    const lines = res.stdout.trim().split('\n')
    expect(lines.length).toBe(2)
    expect(res.stdout.endsWith('\n')).toBe(true)
  })
})
