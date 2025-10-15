import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('parser regression', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig

  beforeEach(() => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
      history: { ...defaultConfig.history, file: `/tmp/test_history_parser_${Math.random().toString(36).slice(2)}` },
    }
    shell = new KrustyShell(testConfig)
  })

  afterEach(() => {
    shell.stop()
  })

  it('reports unterminated quote as syntax error with exit code 2', async () => {
    const cmd = 'echo \'unterminated'
    const res = await shell.execute(cmd)
    expect(res.exitCode).toBe(2)
    const caretLine = `${cmd}\n${' '.repeat(cmd.length)}^\n`
    expect(res.stderr).toBe(`krusty: syntax error: unterminated quote\n${caretLine}`)
    expect(res.stdout).toBe('')
  })
})
