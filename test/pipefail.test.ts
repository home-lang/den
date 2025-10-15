import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('pipefail option', () => {
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
      execution: {
        defaultTimeoutMs: 2000, // Shorter timeout for faster test execution
      },
    }
    shell = new KrustyShell(config)
  })

  it('defaults to non-pipefail behavior (exit code of last command)', async () => {
    // Test that pipefail is off by default
    expect(shell.pipefail).toBe(false)
    const res = await shell.execute('true')
    expect(res.exitCode).toBe(0)
  }, 3000) // 3 second test timeout

  it('toggles pipefail option correctly', async () => {
    // Test initial state
    expect(shell.pipefail).toBe(false)

    // enable pipefail
    const setOn = await shell.execute('set -o pipefail')
    expect(setOn.exitCode).toBe(0)
    expect(shell.pipefail).toBe(true)

    // disable pipefail
    const setOff = await shell.execute('set +o pipefail')
    expect(setOff.exitCode).toBe(0)
    expect(shell.pipefail).toBe(false)
  }, 3000) // 3 second test timeout
})
