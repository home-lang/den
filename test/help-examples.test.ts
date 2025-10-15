import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('help examples', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_help_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('help command shows usage and examples', async () => {
    const res = await shell.execute('help command')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('Usage: command name [args...]')
    expect(res.stdout).toContain('Examples:')
  })

  it('help disown shows usage and examples', async () => {
    const res = await shell.execute('help disown')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('Usage: disown [-h|--help] [job_spec ...]')
    expect(res.stdout).toContain('Examples:')
  })
})
