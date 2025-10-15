import { describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

// Tests focus on parsing and successful execution within time limit.
// We avoid asserting forced termination behavior since the shell API doesn't expose cancellation.
describe('timeout builtin', () => {
  it('errors when missing duration', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout')
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toContain('missing duration')
    shell.stop()
  })

  it('errors on invalid duration', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout abc echo ok')
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toContain('invalid duration')
    shell.stop()
  })

  it('errors when missing command', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout 1')
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toContain('missing command')
    shell.stop()
  })

  it('returns 124 immediately when duration is 0', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout 0 echo ok')
    expect(res.exitCode).toBe(124)
    expect(res.stderr).toContain('timed out')
    shell.stop()
  })

  it('runs a fast command successfully within timeout', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout 1 echo hi')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('hi')
    shell.stop()
  })

  it('terminates a long-running external command with exit 124', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const start = Date.now()
    const res = await shell.execute('timeout 0.1 sleep 5')
    const elapsed = Date.now() - start
    expect(res.exitCode).toBe(124)
    expect(res.stderr).toContain('timed out')
    // Should return quickly (< 1500ms to be lenient in CI)
    expect(elapsed).toBeLessThan(1500)
    shell.stop()
  })

  it('supports -s/--signal option', async () => {
    const shell = new KrustyShell({ ...defaultConfig, verbose: false })
    const res = await shell.execute('timeout -s KILL 0.1 sleep 5')
    expect(res.exitCode).toBe(124)
    expect(res.stderr).toContain('timed out')
    shell.stop()
  })
})
