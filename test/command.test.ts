import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('command builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: {
        ...defaultConfig.history,
        file: `/tmp/test_history_command_${Math.random().toString(36).slice(2)}`,
      },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('errors when no arguments are provided', async () => {
    const res = await shell.execute('command')
    expect(res.exitCode).toBe(2)
    expect(res.stderr).toContain('command: name required')
  })

  it('bypasses aliases/functions: command ll does NOT expand alias', async () => {
    // Given an alias ll -> echo hi
    shell.aliases.ll = 'echo hi'

    // Using command ll should bypass alias expansion and attempt to run external `ll`
    const res = await shell.execute('command ll')
    expect(res.exitCode).not.toBe(0)
    expect(res.stderr).toMatch(/krusty: ll: command not found|exec: ll: command not found|\/bin\/sh: ll: command not found/)
  })
})
