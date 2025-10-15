import type { KrustyConfig } from '../src/types'
import { describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

// Note: relies on `sleep` command being available on Unix-like systems

describe('Execution Timeout', () => {
  it('should terminate long-running external commands after the configured timeout', async () => {
    const cfg: KrustyConfig = {
      ...((await import('../src/config')).defaultConfig),
      execution: {
        defaultTimeoutMs: 200, // 200ms
        killSignal: 'SIGTERM',
      },
      verbose: false,
    }
    const shell = new KrustyShell(cfg)

    // Use a 2-second sleep which should be killed by timeout in ~200ms
    const result = await shell.execute('sleep 2')

    // exitCode is platform dependent after signal; assert stderr contains timeout message
    expect(result.stderr).toContain('process timed out')
    expect(result.duration).toBeGreaterThanOrEqual(0)
  })
})
