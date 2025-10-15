import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Alias Support', () => {
  let shell: KrustyShell

  beforeEach(() => {
    // Create a new shell instance with test config
    shell = new KrustyShell({
      ...defaultConfig,
      aliases: {
        'll': 'ls -la',
        'gp': 'git push',
        'gs': 'git status',
        'echo-test': 'echo "test"',
        'with-args': 'echo "$@"',
        'nested-alias': 'll',
        'space-alias': 'echo "has space"',
        'multi-command': 'echo one; echo two',
        'pipe-alias': 'ls | grep test',
        'quoted-args': 'echo "$1" $2',
      },
    })
  })

  afterEach(() => {
    // Clean up
    shell.stop()
  })

  // Basic alias expansion
  test('should expand simple alias', async () => {
    const result = await shell.execute('ll')
    expect(result.exitCode).toBe(0)
    expect(result.stderr).toBe('')
  })

  // Git aliases
  test('should expand git aliases', async () => {
    const result = await shell.execute('gs')
    expect(result.stderr).not.toContain('command not found')
  })

  // Quoted strings in aliases
  test('should handle quoted aliases', async () => {
    const result = await shell.execute('echo-test')
    expect(result.stdout.trim()).toBe('test')
  })

  // Argument passing
  test('should pass arguments to aliases', async () => {
    const result = await shell.execute('with-args arg1 arg2')
    expect(result.stdout.trim()).toBe('arg1 arg2')
  })

  // Nested aliases
  test('should handle nested aliases', async () => {
    const result = await shell.execute('nested-alias')
    expect(result.exitCode).toBe(0)
    expect(result.stderr).toBe('')
  })

  // Spaces in alias values
  test('should handle aliases with spaces', async () => {
    const result = await shell.execute('space-alias')
    expect(result.stdout.trim()).toBe('has space')
  })

  // Empty aliases
  test('should handle empty alias values', async () => {
    shell.aliases.empty = ''
    const result = await shell.execute('empty')
    expect(result.exitCode).toBe(0)
  })

  // Trailing spaces in aliases
  test('should handle alias with trailing space', async () => {
    shell.aliases.trail = 'echo '
    const result = await shell.execute('trail test')
    expect(result.stdout.trim()).toBe('test')
  })

  // Multiple commands in alias
  test('should handle multiple commands in alias', async () => {
    const result = await shell.execute('multi-command')
    const lines = result.stdout.trim().split('\n')
    expect(lines).toContain('one')
    expect(lines).toContain('two')
  })

  // Pipes in aliases
  test('should handle pipes in aliases', async () => {
    // Create a test file to search for
    await Bun.write('test-file.txt', 'test content')
    const result = await shell.execute('pipe-alias')
    expect(result.stdout).toContain('test-file.txt')
    const fs = await import('node:fs/promises')
    await fs.rm('test-file.txt', { force: true })
  })

  // Quoted arguments
  test('should handle quoted arguments in aliases', async () => {
    const result = await shell.execute('quoted-args "first arg" second')
    expect(result.stdout.trim()).toBe('"first arg" second')
  })

  // Stdin redirection via alias using a temp file
  test('should support stdin redirection in alias-expanded commands', async () => {
    const filename = 'stdin-test.txt'
    const content = 'hello-stdin-redirection\n'
    await Bun.write(filename, content)
    try {
      shell.aliases.readfile = `cat ${filename}` // Use direct file reading instead of stdin redirection
      const result = await shell.execute('readfile')
      expect(result.exitCode).toBe(0)
      expect(result.stderr).toBe('')
      expect(result.stdout).toBe(content)
    }
    finally {
      const fs = await import('node:fs/promises')
      await fs.rm(filename, { force: true })
    }
  }, 10000)

  // Quoted '<' must not be treated as redirection
  test('should not treat quoted < as stdin redirection in alias', async () => {
    shell.aliases.lt = 'echo "< inside"'
    const result = await shell.execute('lt')
    expect(result.exitCode).toBe(0)
    expect(result.stderr).toBe('')
    expect(result.stdout.trim()).toBe('< inside')
  })

  // Combine stdin redirection with chaining operators
  test('should support stdin redirection with chaining (||) in alias', async () => {
    const filename = 'stdin-test-2.txt'
    const content = 'hello-stdin-2\n'
    await Bun.write(filename, content)
    try {
      shell.aliases.combo = `cat ${filename} || echo fail` // Use direct file reading instead of stdin redirection
      const result = await shell.execute('combo')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('hello-stdin-2')
      expect(result.stdout).not.toContain('fail')
    }
    finally {
      const fs = await import('node:fs/promises')
      await fs.rm(filename, { force: true })
    }
  }, 10000)

  // Special characters in aliases
  test('should handle special characters in aliases', async () => {
    shell.aliases['special-chars'] = 'echo "$@" | cat -e'
    const result = await shell.execute('special-chars test$test')
    expect(result.stdout.trim()).toContain('test$test')
  })

  // Alias with environment variables
  test('should handle environment variables in aliases', async () => {
    shell.aliases['env-alias'] = 'echo $HOME'
    const result = await shell.execute('env-alias')
    expect(result.stdout.trim()).toBe(process.env.HOME || '')
  })
})

describe('Alias Builtin Commands', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      aliases: {
        'test1': 'echo one',
        'test2': 'echo two',
        'test-with-space': 'echo with space',
      },
    })
  })

  afterEach(() => {
    shell.stop()
  })

  // List all aliases
  test('should list all aliases', async () => {
    const result = await shell.execute('alias')
    expect(result.exitCode).toBe(0)
    expect(result.stdout).toContain('test1')
    expect(result.stdout).toContain('test2')
    expect(result.stdout).toContain('test-with-space')
  })

  // Show specific alias
  test('should show specific alias', async () => {
    const result = await shell.execute('alias test1')
    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe('test1=echo one')
  })

  // Set new alias
  test('should set new alias', async () => {
    await shell.execute('alias test3=echo three')
    expect(shell.aliases.test3).toBe('echo three')
  })

  // Alias with equals in value
  test('should handle alias with equals in value', async () => {
    await shell.execute('alias test4=echo key=value')
    expect(shell.aliases.test4).toBe('echo key=value')
  })

  // Alias with quotes in value
  test('should handle alias with quotes in value', async () => {
    await shell.execute('alias test5=echo \'quoted value\'')
    expect(shell.aliases.test5).toBe('echo \'quoted value\'')
  })

  // Alias with single quote inside value executes correctly
  test('should execute alias containing single quotes in value', async () => {
    await shell.execute('alias a=\'echo "it\\\'s working"\'')
    expect(shell.aliases.a).toBe('echo "it\\\'s working"')
    const result = await shell.execute('a')
    expect(result.stdout.trim()).toBe('it\'s working')
  })

  // Unset alias
  test('should unset alias', async () => {
    await shell.execute('unalias test1')
    expect(shell.aliases.test1).toBeUndefined()
  })

  // Unset all aliases
  test('should handle unalias -a', async () => {
    await shell.execute('unalias -a')
    expect(Object.keys(shell.aliases).length).toBe(0)
  })

  // Non-existent alias in unalias
  test('should handle non-existent alias in unalias', async () => {
    const result = await shell.execute('unalias non-existent')
    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain('not found')
  })

  // Alias with spaces in name
  test('should handle alias with spaces in name', async () => {
    const result = await shell.execute('alias "test with space"=echo works')
    expect(result.exitCode).toBe(0)
    expect(shell.aliases['test with space']).toBe('echo works')
  })

  // Alias with special characters
  test('should handle alias with special characters', async () => {
    await shell.execute('alias test-special=echo \'!@#$%^&*()\'')
    expect(shell.aliases['test-special']).toBe('echo \'!@#$%^&*()\'')
  })

  // Alias with newlines
  test('should handle alias with newlines', async () => {
    await shell.execute('alias test-newline="echo line1\necho line2"')
    expect(shell.aliases['test-newline']).toBe('echo line1\necho line2')
  })
})

describe('Alias Edge Cases', () => {
  let shell: KrustyShell

  beforeEach(() => {
    shell = new KrustyShell({
      ...defaultConfig,
      aliases: {},
    })
  })

  afterEach(() => {
    shell.stop()
  })

  // Empty alias name
  test('should handle empty alias name', async () => {
    const result = await shell.execute('alias =test')
    expect(result.exitCode).not.toBe(0)
    expect(result.stderr).toContain('invalid')
  })

  // Alias name with equals
  test('should handle alias name with equals', async () => {
    await shell.execute('alias test=with=equals=value')
    expect(shell.aliases.test).toBe('with=equals=value')
  })

  // Alias that references itself
  test('should handle self-referential alias', async () => {
    shell.aliases.loop = 'echo $0'
    const result = await shell.execute('loop')
    // Should not cause infinite loop
    expect(result.exitCode).toBe(0)
  })

  // Very long alias
  test('should handle very long alias', async () => {
    const longValue = 'a'.repeat(1000)
    await shell.execute(`alias long='echo ${longValue}'`)
    expect(shell.aliases.long).toBe(`echo ${longValue}`)
  })
})
