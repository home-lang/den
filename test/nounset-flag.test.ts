import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('nounset (-u) flag', () => {
  let shell: KrustyShell
  let config: KrustyConfig

  beforeEach(() => {
    config = {
      verbose: false,
      streamOutput: false,
      prompt: { format: '$ ' },
      history: { maxEntries: 100 },
      completion: { enabled: true },
      aliases: {},
      environment: {},
      plugins: [],
      theme: {},
      modules: {},
      hooks: {},
      logging: {},
    }
    shell = new KrustyShell(config)
  })

  it('toggles nounset via set -u/+u', async () => {
    expect(shell.nounset).toBe(false)

    let res = await shell.execute('set -u')
    expect(res.exitCode).toBe(0)
    expect(shell.nounset).toBe(true)

    res = await shell.execute('set +u')
    expect(res.exitCode).toBe(0)
    expect(shell.nounset).toBe(false)
  })

  it('errors on unset variable when -u is enabled', async () => {
    const setRes = await shell.execute('set -u')
    expect(setRes.exitCode).toBe(0)
    expect(shell.nounset).toBe(true)

    const res = await shell.execute('echo $UNDEFINED_VAR')
    expect(res.exitCode).toBeGreaterThan(0)
    expect(res.stderr).toContain('unbound variable')
  })

  it('expands unset variable to empty when -u is disabled', async () => {
    // Ensure -u is off
    if (shell.nounset) {
      await shell.execute('set +u')
    }
    const res = await shell.execute('echo $NOT_SET')
    expect(res.exitCode).toBe(0)
    // echo of empty expands to a trailing newline only
    expect(res.stdout.trim()).toBe('')
  })

  it('supports default parameter expansion with -u enabled', async () => {
    const setRes = await shell.execute('set -u')
    expect(setRes.exitCode).toBe(0)
    const expr = ['${', 'FOO:-bar', '}'].join('')
    const res = await shell.execute(['echo ', expr].join(''))
    expect(res.exitCode).toBe(0)
    expect(res.stdout.trim()).toBe('bar')
  })
})
