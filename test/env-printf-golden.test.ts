import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

// Golden tests for env and printf outputs

describe('golden: env and printf', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      // Ensure deterministic environment
      environment: { FOO: 'one', BAR: 'two' },
      history: { ...defaultConfig.history, file: `/tmp/test_history_golden_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => shell.stop())

  it('env -i A=1 B=2 prints sorted KEY=VALUE', async () => {
    const res = await shell.execute('env -i A=1 B=2')
    expect(res.exitCode).toBe(0)
    // Sorted expected
    const expected = 'A=1\nB=2'
    expect(res.stdout.trim()).toBe(expected)
  })

  it('env prints config environment sorted', async () => {
    const res = await shell.execute('env')
    expect(res.exitCode).toBe(0)
    const expected = 'BAR=two\nFOO=one'
    // Only assert subset since runtime may add PWD/TERM, filter lines
    const lines = res.stdout.trim().split('\n').filter(l => l.startsWith('BAR=') || l.startsWith('FOO='))
    expect(lines.join('\n')).toBe(expected)
  })

  it('printf golden: mixed specifiers and escapes', async () => {
    const res = await shell.execute('printf "Hello %s %d\\n%%x=%x" world 7 255')
    expect(res.exitCode).toBe(0)
    const out = res.stdout.replace(/\r/g, '')
    expect(out).toContain('Hello world 7')
    expect(out).toContain('%x=ff')
  })

  it('printf golden: width/align/zero-pad', async () => {
    const r1 = await shell.execute('printf "%05d" 42')
    const r2 = await shell.execute('printf "%-6s" hi')
    const r3 = await shell.execute('printf "%7.2f" 3.14159')
    expect(r1.stdout).toBe('00042')
    expect(r2.stdout).toBe('hi    ')
    expect(r3.stdout).toBe('   3.14')
  })
})
