import type { KrustyConfig } from '../src/types'
import { describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('Error Recovery - Parse Errors', () => {
  it('returns a clear syntax error with exitCode 2 when parsing fails', async () => {
    const { defaultConfig } = await import('../src/config')
    const cfg: KrustyConfig = { ...defaultConfig, verbose: false }
    const shell = new KrustyShell(cfg)

    // Malformed command (unterminated quote) should trigger parser error
    const result = await shell.execute('echo "unterminated')

    expect(result.exitCode).toBe(2)
    expect(result.stderr).toContain('syntax error')
  })
})
