import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Operator Chaining Integration', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({ ...defaultConfig, verbose: false })
  })

  afterEach(() => {
    shell.stop()
  })

  it('short-circuits && when left fails with pipelines', async () => {
    // Without pipefail, pipeline exit is the last command's exit.
    // Make the last command fail so && short-circuits.
    const res = await shell.execute('true | false && echo should-not-run')
    expect(res.exitCode).not.toBe(0)
    expect(res.stdout).not.toContain('should-not-run')
  })

  it('executes || fallback when left fails with pipelines', async () => {
    // Without pipefail, pipeline exit is the last command's exit.
    // Make the last command fail so || executes fallback.
    const res = await shell.execute('true | false || echo fallback')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('fallback')
  })

  it('respects pipefail with && and ||', async () => {
    // enable pipefail
    await shell.execute('set -o pipefail')

    const r1 = await shell.execute('true | false && echo ok')
    // left fails due to pipefail, so && should short-circuit
    expect(r1.exitCode).not.toBe(0)
    expect(r1.stdout).not.toContain('ok')

    const r2 = await shell.execute('true | false || echo recovered')
    expect(r2.exitCode).toBe(0)
    expect(r2.stdout).toContain('recovered')

    // disable pipefail for cleanliness
    await shell.execute('set +o pipefail')
  })

  it('handles mixed sequence ; with conditional operators', async () => {
    const res = await shell.execute('echo A && echo B; echo C || echo D')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('A')
    expect(res.stdout).toContain('B')
    expect(res.stdout).toContain('C')
    expect(res.stdout).not.toContain('D')
  })
})
