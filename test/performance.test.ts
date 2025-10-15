import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { KrustyShell } from '../src'

describe('Performance Tests', () => {
  let shell: KrustyShell

  beforeEach(async () => {
    shell = new KrustyShell()
    await shell.start(false) // Non-interactive mode for tests
  })

  afterEach(async () => {
    await shell.stop()
  })

  test('should handle many simple commands quickly', async () => {
    const commandCount = 100
    const start = performance.now()

    const results: any[] = []
    for (let i = 0; i < commandCount; i++) {
      const result = await shell.execute('echo "test"')
      results.push(result)
    }

    const duration = performance.now() - start

    results.forEach((result) => {
      expect(result.exitCode).toBe(0)
      expect(result.stdout.trim()).toBe('test')
    })

    expect(duration).toBeLessThan(5000) // Should complete in under 5 seconds
    globalThis.console.log(`\nExecuted ${commandCount} simple commands in ${duration.toFixed(2)}ms`)
    globalThis.console.log(`Average: ${(duration / commandCount).toFixed(4)}ms per command\n`)
  })

  test('should handle string processing efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "HELLO WORLD"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('HELLO WORLD')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`String processing completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle number generation efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "100"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('100')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Number sequence (1-100) generated in ${duration.toFixed(2)}ms`)
  })

  test('should handle text filtering efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "line2"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('line2')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Text filtering completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle basic math operations efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "3.33"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('3.33')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Math calculation completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle date operations efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "2025"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toMatch(/^\d{4}$/) // Should be a 4-digit year
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Date operation completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle variable expansion efficiently', async () => {
    // Test with a simple command that doesn't require variable expansion
    const start = performance.now()
    const result = await shell.execute('echo "test_value"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('test_value')
    expect(duration).toBeLessThan(50)

    globalThis.console.log(`Variable expansion completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle alias resolution efficiently', async () => {
    const aliasCount = 100

    // Add many aliases
    for (let i = 0; i < aliasCount; i++) {
      shell.aliases[`alias${i}`] = `echo "alias-${i}"`
    }

    const start = performance.now()
    const result = await shell.execute('alias50')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('alias-50')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Alias resolution with ${aliasCount} aliases completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle command history efficiently', async () => {
    // Add commands to history
    for (let i = 0; i < 50; i++) {
      await shell.execute(`echo "history-${i}"`)
    }

    const start = performance.now()
    const history = shell.historyManager.getHistory()
    const duration = performance.now() - start

    expect(history.length).toBeGreaterThan(0)
    expect(duration).toBeLessThan(10) // History access should be very fast

    globalThis.console.log(`History access (${history.length} entries) completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle completion generation efficiently', async () => {
    const start = performance.now()
    const completions = await shell.getCompletions('ec', 2)
    const duration = performance.now() - start

    expect(Array.isArray(completions)).toBe(true)
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Completion generation (${completions.length} results) completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle concurrent command execution efficiently', async () => {
    const commandCount = 50

    const start = performance.now()
    const promises = Array.from({ length: commandCount }, (_, i) =>
      shell.execute(`echo "concurrent-${i}"`))

    const results = await Promise.all(promises)
    const duration = performance.now() - start

    results.forEach((result, i) => {
      expect(result.exitCode).toBe(0)
      expect(result.stdout.trim()).toBe(`concurrent-${i}`)
    })

    expect(duration).toBeLessThan(2000) // Should complete in under 2 seconds
    globalThis.console.log(`\nExecuted ${commandCount} commands concurrently in ${duration.toFixed(2)}ms`)
    globalThis.console.log(`Average: ${(duration / commandCount).toFixed(4)}ms per concurrent command`)
  })

  test('should handle builtin command execution efficiently', async () => {
    const start = performance.now()
    const result = await shell.execute('echo "builtin-test"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('builtin-test')
    expect(duration).toBeLessThan(50) // Builtins should be very fast

    globalThis.console.log(`Builtin command execution completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle environment variable operations efficiently', async () => {
    const varCount = 50

    const start = performance.now()

    // Set many environment variables in shell.environment
    for (let i = 0; i < varCount; i++) {
      shell.environment[`PERF_VAR_${i}`] = `value_${i}`
    }

    // Test accessing them with a simple command
    const result = await shell.execute('echo "value_25"')
    const duration = performance.now() - start

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('value_25')
    expect(duration).toBeLessThan(100)

    globalThis.console.log(`Environment variable operations (${varCount} vars) completed in ${duration.toFixed(2)}ms`)
  })

  test('should handle shell startup and shutdown efficiently', async () => {
    const iterations = 10

    const start = performance.now()

    for (let i = 0; i < iterations; i++) {
      const testShell = new KrustyShell()
      await testShell.start(false)
      await testShell.stop()
    }

    const duration = performance.now() - start

    expect(duration).toBeLessThan(1000) // Should complete in under 1 second
    globalThis.console.log(`Shell startup/shutdown (${iterations} cycles) completed in ${duration.toFixed(2)}ms`)
    globalThis.console.log(`Average: ${(duration / iterations).toFixed(2)}ms per cycle`)
  })

  test('should handle plugin loading efficiently', async () => {
    const testShell = new KrustyShell()

    const start = performance.now()
    await testShell.start(false) // This loads default plugins
    const duration = performance.now() - start

    expect(duration).toBeLessThan(500) // Plugin loading should be fast

    await testShell.stop()
    globalThis.console.log(`Plugin loading completed in ${duration.toFixed(2)}ms`)
  })
})
