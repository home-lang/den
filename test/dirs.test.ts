import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('dirs builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_dirs_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('prints current directory and stack', async () => {
    const res = await shell.execute('dirs')
    expect(res.exitCode).toBe(0)
    expect(res.stdout.endsWith('\n')).toBe(true)
    const first = res.stdout.trim().split(' ')[0]
    expect(first).toBe(shell.cwd)
  })
})
