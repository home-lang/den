import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Scripts + Chaining Integration', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({ ...defaultConfig, verbose: false })
  })

  afterEach(() => {
    shell.stop()
  })

  it('executes right of && when if-then branch succeeds', async () => {
    const res = await shell.execute('if true; then echo A; else echo B; fi && echo C', { bypassScriptDetection: true })
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('A')
    expect(res.stdout).toContain('C')
    expect(res.stdout).not.toContain('B')
  })

  it('executes right of || when if-then branch fails', async () => {
    const res = await shell.execute('if false; then echo A; else echo B; fi || echo F', { bypassScriptDetection: true })
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('B')
    expect(res.stdout).toContain('F')
    expect(res.stdout).not.toContain('A')
  })

  it('supports functions within chaining', async () => {
    const script = [
      'myfn() { echo X; return 0; }',
      'myfn && echo Y',
    ].join('\n')
    // Remove bypassScriptDetection to allow proper script parsing and function handling
    const res = await shell.execute(script)
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('X')
    expect(res.stdout).toContain('Y')
  })
})
