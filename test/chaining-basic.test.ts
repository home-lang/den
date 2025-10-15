import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('basic command chaining operators', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({ ...defaultConfig, verbose: false })
  })

  afterEach(() => {
    shell.stop()
  })

  it('executes right side of && only when left succeeds', async () => {
    const res = await shell.execute('true && echo ok')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('ok')
  })

  it('executes right side of || only when left fails', async () => {
    const res = await shell.execute('false || echo fallback')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('fallback')
  })

  it('always executes following segment with ;', async () => {
    const res = await shell.execute('echo first; echo second')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('first')
    expect(res.stdout).toContain('second')
  })
})
