import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('xtrace flag', () => {
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

  it('toggles xtrace via set -x/+x', async () => {
    expect(shell.xtrace).toBe(false)

    let res = await shell.execute('set -x')
    expect(res.exitCode).toBe(0)
    expect(shell.xtrace).toBe(true)

    res = await shell.execute('set +x')
    expect(res.exitCode).toBe(0)
    expect(shell.xtrace).toBe(false)
  })

  it('prints expanded command to stderr when -x is enabled', async () => {
    // Enable xtrace
    const setRes = await shell.execute('set -x')
    expect(setRes.exitCode).toBe(0)
    expect(shell.xtrace).toBe(true)

    // Use a builtin command; builtins also emit xtrace
    const res1 = await shell.execute('true')
    expect(res1.exitCode).toBe(0)
    expect(shell.lastXtraceLine).toBeDefined()
    expect(shell.lastXtraceLine).toContain('+ true')
  })
})
