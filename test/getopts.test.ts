import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('getopts builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_getopts_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('errors on missing parameters', async () => {
    const res = await shell.execute('getopts')
    expect(res.exitCode).toBe(2)
    expect(res.stderr).toContain('getopts: usage: getopts optstring name [args]')
  })

  it('parses flags and advances OPTIND', async () => {
    // Reset OPTIND
    shell.environment.OPTIND = '1'

    // First call: -a recognized, no arg
    const r1 = await shell.execute('getopts "ab:" opt -a -b val')
    expect(r1.exitCode).toBe(0)
    expect(shell.environment.opt).toBe('a')
    expect(shell.environment.OPTARG).toBe('')
    expect(shell.environment.OPTIND).toBe('2')

    // Second call: -b expects arg, captures 'val'
    const r2 = await shell.execute('getopts "ab:" opt -a -b val')
    expect(r2.exitCode).toBe(0)
    expect(shell.environment.opt).toBe('b')
    expect(shell.environment.OPTARG).toBe('val')
    expect(shell.environment.OPTIND).toBe('4')

    // Third call: end of options
    const r3 = await shell.execute('getopts "ab:" opt -a -b val')
    expect(r3.exitCode).toBe(1)
    expect(shell.environment.opt).toBe('?')
  })
})
