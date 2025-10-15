import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('printf builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_printf_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('errors when no format is provided', async () => {
    const res = await shell.execute('printf')
    expect(res.exitCode).toBe(1)
    expect(res.stderr).toBe('printf: missing format string\n')
  })

  it('prints strings and numbers with %s and %d', async () => {
    const res = await shell.execute('printf "%s %d" hello 42')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toBe('hello 42')
  })

  it('prints literal percent with %%', async () => {
    const res = await shell.execute('printf "%%s %%" ignored')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toBe('%s %')
  })

  it('quotes with %q', async () => {
    const res = await shell.execute('printf %q "a b"')
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toBe('"a b"')
  })

  it('supports width and left/right alignment for %s', async () => {
    const r1 = await shell.execute('printf "%5s" hi')
    expect(r1.stdout).toBe('   hi')
    const r2 = await shell.execute('printf "%-5s" hi')
    expect(r2.stdout).toBe('hi   ')
  })

  it('supports zero-padding, width and precision for %d', async () => {
    const r1 = await shell.execute('printf "%05d" 42')
    expect(r1.stdout).toBe('00042')
    const r2 = await shell.execute('printf "%8.4d" 42')
    expect(r2.stdout).toBe('    0042')
    const r3 = await shell.execute('printf "%8d" -7')
    expect(r3.stdout).toBe('      -7')
  })

  it('supports octal/hex with %o/%x/%X', async () => {
    const r1 = await shell.execute('printf "%o" 8')
    expect(r1.stdout).toBe('10')
    const r2 = await shell.execute('printf "%x %X" 255 255')
    expect(r2.stdout).toBe('ff FF')
  })

  it('supports floating formats %f/%e/%g with precision and width', async () => {
    const r1 = await shell.execute('printf "%7.2f" 3.14159')
    expect(r1.stdout).toBe('   3.14')
    const r2 = await shell.execute('printf "%-10.2e" 3.14159')
    // bun uses lowercase e after our normalization
    expect(r2.stdout).toMatch(/^3\.14e[-+]?0?\d\s+$/)
    const r3 = await shell.execute('printf "%g" 3.1400')
    expect(r3.stdout).toBe('3.14')
  })

  it('expands backslash escapes with %b', async () => {
    // Test %b with actual escape sequences - call printf builtin directly
    const result = await shell.builtins.get('printf')!.execute(['%b', 'line\\ntext'], shell)
    expect(result.stdout).toBe('line\ntext')
  })

  it('handles invalid/unknown specifiers by leaving them literal', async () => {
    const r = await shell.execute('printf "%y %s" hello')
    // %y should be left intact, %s filled with hello
    expect(r.stdout).toBe('%y hello')
  })
})
