import { describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Custom simple builtins', () => {
  it('c should clear the screen (ANSI sequence)', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('c')
    expect(res.exitCode).toBe(0)
    // ESC [ 2J ESC [ H
    expect(res.stdout).toContain('\u001B')
    shell.stop()
  })

  it('shrug should output the face and attempt clipboard silently', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('shrug')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('¯\\_(ツ)_/¯')
    shell.stop()
  })
})
