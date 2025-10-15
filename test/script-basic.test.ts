import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe('Basic Script Features', () => {
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

  it('should execute simple if statement', async () => {
    const script = 'if true; then\necho "success"\nfi'
    const result = await shell.execute(script)
    expect(result.exitCode).toBe(0)
    expect(result.stdout?.trim()).toBe('success')
  })

  it('should execute simple for loop', async () => {
    const script = 'for i in 1 2; do\necho "num: $i"\ndone'
    const result = await shell.execute(script)
    expect(result.exitCode).toBe(0)
    expect(result.stdout?.includes('num: 1')).toBe(true)
    expect(result.stdout?.includes('num: 2')).toBe(true)
  })

  it('should handle script built-ins', async () => {
    const result1 = await shell.execute('true')
    expect(result1.exitCode).toBe(0)

    const result2 = await shell.execute('false')
    expect(result2.exitCode).toBe(1)
  })

  it('should handle test command', async () => {
    const result1 = await shell.execute('test "hello" = "hello"')
    expect(result1.exitCode).toBe(0)

    const result2 = await shell.execute('test "hello" = "world"')
    expect(result2.exitCode).toBe(1)
  })
})
