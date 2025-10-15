import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

// Snapshot tests for help and type outputs

describe('snapshot: help and type', () => {
  let shell: KrustyShell
  let cfg: KrustyConfig

  beforeEach(() => {
    cfg = { ...defaultConfig, verbose: false, history: { ...defaultConfig.history, file: `/tmp/test_history_snap_${Math.random().toString(36).slice(2)}` } }
    shell = new KrustyShell(cfg)
  })

  afterEach(() => shell.stop())

  it('help (no args) output', async () => {
    const res = await shell.execute('help')
    expect(res.exitCode).toBe(0)
    // Normalize dynamic whitespace
    const normalized = res.stdout.replace(/\s+$/gm, '')
    expect(normalized).toMatchSnapshot()
  })

  it('help printf output', async () => {
    const res = await shell.execute('help printf')
    expect(res.exitCode).toBe(0)
    const normalized = res.stdout.replace(/\s+$/gm, '')
    expect(normalized).toMatchSnapshot()
  })

  it('type builtins and external', async () => {
    const r1 = await shell.execute('type printf')
    const r2 = await shell.execute('type env')
    // "echo" is builtin too
    const r3 = await shell.execute('type echo')
    expect([r1.exitCode, r2.exitCode, r3.exitCode]).toEqual([0, 0, 0])
    const snapshot = [r1.stdout.trim(), r2.stdout.trim(), r3.stdout.trim()].join('\n---\n')
    expect(snapshot).toMatchSnapshot()
  })
})
