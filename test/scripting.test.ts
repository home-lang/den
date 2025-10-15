import type { KrustyConfig } from '../src/types'
import { beforeEach, describe, expect, it } from 'bun:test'
import { KrustyShell } from '../src'

describe.skip('Scripting Features', () => {
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

  describe('Control Flow - If Statements', () => {
    it('should execute if-then-fi with true condition', async () => {
      const script = `
        if [ "hello" = "hello" ]; then
          echo "condition is true"
        fi
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('condition is true')
    })

    it('should skip if-then-fi with false condition', async () => {
      const script = `
        if [ "hello" = "world" ]; then
          echo "should not print"
        fi
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('')
    })

    it('should execute if-then-else-fi with false condition', async () => {
      const script = `
        if [ "hello" = "world" ]; then
          echo "should not print"
        else
          echo "condition is false"
        fi
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('condition is false')
    })

    it('should handle elif statements', async () => {
      const script = `
        if [ "1" = "2" ]; then
          echo "first condition"
        elif [ "2" = "2" ]; then
          echo "second condition"
        else
          echo "else condition"
        fi
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('second condition')
    })
  })

  describe('Control Flow - For Loops', () => {
    it('should execute for loop with list', async () => {
      const script = `
        for item in apple banana cherry; do
          echo "fruit: $item"
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('fruit: apple')
      expect(result.stdout?.trim()).toContain('fruit: banana')
      expect(result.stdout?.trim()).toContain('fruit: cherry')
    })

    it('should handle empty for loop', async () => {
      const script = `
        for item in; do
          echo "should not print"
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('')
    })
  })

  describe('Control Flow - While Loops', () => {
    it('should execute while loop with counter', async () => {
      shell.environment.counter = '1'
      const script = `
        while [ "$counter" -le "3" ]; do
          echo "count: $counter"
          counter=$((counter + 1))
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('count: 1')
      expect(result.stdout?.trim()).toContain('count: 2')
      expect(result.stdout?.trim()).toContain('count: 3')
    })

    it('should skip while loop with false condition', async () => {
      const script = `
        while [ "false" = "true" ]; do
          echo "should not print"
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('')
    })
  })

  describe('Control Flow - Until Loops', () => {
    it('should execute until loop', async () => {
      shell.environment.counter = '1'
      const script = `
        until [ "$counter" -gt "2" ]; do
          echo "count: $counter"
          counter=$((counter + 1))
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('count: 1')
      expect(result.stdout?.trim()).toContain('count: 2')
    })
  })

  describe('Control Flow - Case Statements', () => {
    it('should execute matching case', async () => {
      shell.environment.fruit = 'apple'
      const script = `
        case "$fruit" in
          apple)
            echo "red fruit"
            ;;
          banana)
            echo "yellow fruit"
            ;;
          *)
            echo "unknown fruit"
            ;;
        esac
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('red fruit')
    })

    it('should execute default case', async () => {
      shell.environment.fruit = 'grape'
      const script = `
        case "$fruit" in
          apple)
            echo "red fruit"
            ;;
          banana)
            echo "yellow fruit"
            ;;
          *)
            echo "unknown fruit"
            ;;
        esac
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('unknown fruit')
    })
  })

  describe('Functions', () => {
    it('should define and call function with function keyword', async () => {
      const script = `
        function greet {
          echo "Hello, $1!"
        }
        greet World
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('Hello, World!')
    })

    it('should define and call function with () syntax', async () => {
      const script = `
        greet() {
          echo "Hello, $1!"
        }
        greet Universe
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('Hello, Universe!')
    })

    it('should handle function with return value', async () => {
      const script = `
        add() {
          local result=$((1 + 2))
          echo $result
          return 0
        }
        add
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('3')
    })
  })

  describe('Error Handling', () => {
    it('should continue on error by default', async () => {
      const script = `
        false
        echo "this should print"
      `
      const result = await shell.execute(script.trim())
      expect(result.stdout?.trim()).toBe('this should print')
    })

    it('should exit on error with set -e', async () => {
      const script = `
        set -e
        false
        echo "this should not print"
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(1)
      expect(result.stdout?.trim()).not.toContain('this should not print')
    })

    it('should disable exit on error with set +e', async () => {
      const script = `
        set -e
        set +e
        false
        echo "this should print"
      `
      const result = await shell.execute(script.trim())
      expect(result.stdout?.trim()).toBe('this should print')
    })
  })

  describe('Built-in Commands', () => {
    it('should execute test command', async () => {
      const result1 = await shell.execute('test -f /etc/passwd')
      expect(result1.exitCode).toBe(0)

      const result2 = await shell.execute('test -f /nonexistent/file')
      expect(result2.exitCode).toBe(1)
    })

    it('should execute [ command', async () => {
      const result1 = await shell.execute('[ "hello" = "hello" ]')
      expect(result1.exitCode).toBe(0)

      const result2 = await shell.execute('[ "hello" = "world" ]')
      expect(result2.exitCode).toBe(1)
    })

    it('should execute true command', async () => {
      const result = await shell.execute('true')
      expect(result.exitCode).toBe(0)
    })

    it('should execute false command', async () => {
      const result = await shell.execute('false')
      expect(result.exitCode).toBe(1)
    })

    it('should handle local variables', async () => {
      const result = await shell.execute('local var=value')
      expect(result.exitCode).toBe(0)
      expect(shell.environment.var).toBe('value')
    })

    it('should handle declare command', async () => {
      const result = await shell.execute('declare var=value')
      expect(result.exitCode).toBe(0)
      expect(shell.environment.var).toBe('value')
    })

    it('should handle readonly variables', async () => {
      const result = await shell.execute('readonly var=value')
      expect(result.exitCode).toBe(0)
      expect(shell.environment.var).toBe('value')
      expect(shell.environment.READONLY_var).toBe('true')
    })
  })

  describe('Loop Control', () => {
    it('should handle break in for loop', async () => {
      const script = `
        for i in 1 2 3 4 5; do
          if [ "$i" = "3" ]; then
            break
          fi
          echo "number: $i"
        done
        echo "after loop"
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('number: 1')
      expect(result.stdout?.trim()).toContain('number: 2')
      expect(result.stdout?.trim()).not.toContain('number: 3')
      expect(result.stdout?.trim()).toContain('after loop')
    })

    it('should handle continue in for loop', async () => {
      const script = `
        for i in 1 2 3 4 5; do
          if [ "$i" = "3" ]; then
            continue
          fi
          echo "number: $i"
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('number: 1')
      expect(result.stdout?.trim()).toContain('number: 2')
      expect(result.stdout?.trim()).not.toContain('number: 3')
      expect(result.stdout?.trim()).toContain('number: 4')
      expect(result.stdout?.trim()).toContain('number: 5')
    })
  })

  describe('Complex Scripts', () => {
    it('should handle nested control structures', async () => {
      const script = `
        for i in 1 2 3; do
          if [ "$i" = "2" ]; then
            echo "found two"
          else
            echo "number: $i"
          fi
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('number: 1')
      expect(result.stdout?.trim()).toContain('found two')
      expect(result.stdout?.trim()).toContain('number: 3')
    })

    it('should handle function with control flow', async () => {
      const script = `
        check_number() {
          if [ "$1" -gt "5" ]; then
            echo "big number"
          else
            echo "small number"
          fi
        }
        check_number 3
        check_number 7
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('small number')
      expect(result.stdout?.trim()).toContain('big number')
    })
  })

  describe('Variable Expansion', () => {
    it('should expand variables in conditions', async () => {
      shell.environment.name = 'test'
      const script = `
        if [ "$name" = "test" ]; then
          echo "variable expanded correctly"
        fi
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('variable expanded correctly')
    })

    it('should expand variables in for loops', async () => {
      shell.environment.items = 'a b c'
      const script = `
        for item in $items; do
          echo "item: $item"
        done
      `
      const result = await shell.execute(script.trim())
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toContain('item: a')
      expect(result.stdout?.trim()).toContain('item: b')
      expect(result.stdout?.trim()).toContain('item: c')
    })
  })

  describe('Source Command', () => {
    it('should execute source command', async () => {
      // Create a temporary script file
      const fs = await import('node:fs/promises')
      const scriptPath = '/tmp/test_script.sh'
      await fs.writeFile(scriptPath, 'echo "sourced script"')

      const result = await shell.execute(`source ${scriptPath}`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('sourced script')

      // Clean up
      await fs.unlink(scriptPath)
    })

    it('should execute . command (alias for source)', async () => {
      // Create a temporary script file
      const fs = await import('node:fs/promises')
      const scriptPath = '/tmp/test_script2.sh'
      await fs.writeFile(scriptPath, 'echo "dot sourced script"')

      const result = await shell.execute(`. ${scriptPath}`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout?.trim()).toBe('dot sourced script')

      // Clean up
      await fs.unlink(scriptPath)
    })
  })
})
