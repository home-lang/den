import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('Basic Shell Functionality', () => {
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

  it('should execute echo command', async () => {
    const result = await shell.execute('echo "hello world"')
    expect(result.exitCode).toBe(0)
    expect(result.stdout?.trim()).toBe('hello world')
  })

  it('should handle built-in commands', async () => {
    const result1 = await shell.execute('true')
    expect(result1.exitCode).toBe(0)

    const result2 = await shell.execute('false')
    expect(result2.exitCode).toBe(1)
  })

  it('should handle test command properly', async () => {
    const result1 = await shell.execute('test "hello" = "hello"')
    expect(result1.exitCode).toBe(0)

    const result2 = await shell.execute('test "hello" = "world"')
    expect(result2.exitCode).toBe(1)
  })

  it('should handle pwd command', async () => {
    const result = await shell.execute('pwd')
    expect(result.exitCode).toBe(0)
    expect(result.stdout?.trim()).toBeTruthy()
  })
})
