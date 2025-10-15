import type { KrustyConfig } from '../src/types'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

// Table-driven negative tests for core builtins: invalid flags and too few args
// We aim for coverage breadth without asserting overly specific stderr across all commands.

interface Case {
  cmd: string
  expectCode?: number
  stderrIncludes?: string | RegExp
}

describe('builtins negative cases', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeAll(() => {
    // Silence verbose output
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_bneg_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterAll(() => shell.stop())

  beforeEach(() => {
    // Ensure clean cwd and env between tests if needed
  })

  afterEach(() => {})

  const cases: Case[] = [
    // Too few args
    { cmd: 'alias -Z', expectCode: 1 },
    // unalias with no args may be a noop in this shell
    // export unknown flag behavior varies; skip
    { cmd: 'printf', expectCode: 1, stderrIncludes: /missing format/i },
    { cmd: 'kill', expectCode: 1 },
    { cmd: 'bg', expectCode: 1 },
    { cmd: 'fg', expectCode: 1 },
    // disown, set, dirs flags vary; skip to avoid brittleness
    { cmd: 'umask -Z', expectCode: 1 },
    // getopts without args may succeed; skip
    { cmd: 'timeout', expectCode: 1 },
    { cmd: 'which', expectCode: 1 },
    { cmd: 'type', expectCode: 1 },
    { cmd: 'hash -Z', expectCode: 1 },
    { cmd: 'popd -Z', expectCode: 1 },
    { cmd: 'source', expectCode: 1 },
  ]

  for (const c of cases) {
    it(`"${c.cmd}" returns non-zero for invalid usage`, async () => {
      const res = await shell.execute(c.cmd)
      if (c.expectCode != null)
        expect(res.exitCode).toBe(c.expectCode)
      else
        expect(res.exitCode).toBeGreaterThan(0)
      if (c.stderrIncludes) {
        if (typeof c.stderrIncludes === 'string')
          expect(res.stderr).toContain(c.stderrIncludes)
        else expect(res.stderr).toMatch(c.stderrIncludes)
      }
    })
  }
})
