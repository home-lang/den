import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('Simple Script Test', () => {
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

  it('should execute basic echo command', async () => {
    const result = await shell.execute('echo "hello world"')
    expect(result.exitCode).toBe(0)
    expect(result.stdout?.trim()).toBe('hello world')
  })

  it('should execute true command', async () => {
    const result = await shell.execute('true')
    expect(result.exitCode).toBe(0)
  })

  it('should execute false command', async () => {
    const result = await shell.execute('false')
    expect(result.exitCode).toBe(1)
  })
})
