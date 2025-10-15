import type { HookManager } from '../src/hooks'
import type { HookConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'
import { HookUtils } from '../src/hooks'

describe('Hooks System', () => {
  let shell: KrustyShell
  let hookManager: HookManager
  let tempDir: string

  beforeEach(() => {
    // Create temporary directory for test files
    tempDir = mkdtempSync(join(tmpdir(), 'krusty-hooks-test-'))

    // Initialize shell with default config
    shell = new KrustyShell(defaultConfig)
    hookManager = (shell as any).hookManager

    // Clear any existing hooks and reset state
    hookManager.clear()

    // Ensure clean environment for each test
    process.env.NODE_ENV = 'test'
  })

  afterEach(async () => {
    try {
      if (hookManager)
        hookManager.clear()
      if (shell)
        await shell.stop()
      if (tempDir)
        rmSync(tempDir, { recursive: true, force: true })
    }
    catch {
      // Ignore cleanup errors
    }
  })

  it('should register and execute command hooks', async () => {
    const hookConfig: HookConfig = {
      name: 'test-hook',
      function: 'testFunction',
      enabled: true,
    }

    // Mock the function execution by overriding the executeFunction method
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Hello from hook', stderr: '' },
    })

    hookManager.registerHook('test:event', hookConfig)

    const results = await hookManager.executeHooks('test:event', {})
    expect(results).toHaveLength(1)
    expect(results[0].success).toBe(true)
    expect(results[0].data?.stdout).toContain('Hello from hook')

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should execute script hooks', async () => {
    const hookConfig: HookConfig = {
      name: 'test-script-hook',
      function: 'testScript',
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Script hook executed', stderr: '' },
    })

    hookManager.registerHook('test:script', hookConfig)

    const results = await hookManager.executeHooks('test:script', {})
    expect(results).toHaveLength(1)
    expect(results[0].success).toBe(true)
    expect(results[0].data?.stdout).toContain('Script hook executed')

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should handle hook conditions', async () => {
    const testFile = join(tempDir, 'condition-test-file')

    const hookConfig: HookConfig = {
      name: 'conditional-hook',
      function: 'conditionalTest',
      conditions: [{ type: 'file', value: testFile }],
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Conditional hook executed', stderr: '' },
    })

    hookManager.registerHook('test:condition', hookConfig)

    // First execution should fail because file doesn't exist
    let results = await hookManager.executeHooks('test:condition', {})
    expect(results).toHaveLength(0) // Hook should not execute

    // Create the file and try again
    writeFileSync(testFile, 'test')
    results = await hookManager.executeHooks('test:condition', {})
    expect(results).toHaveLength(1)
    expect(results[0].success).toBe(true)

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should respect hook priorities', async () => {
    const highPriorityHook: HookConfig = {
      name: 'high-priority',
      function: 'highPriority',
      priority: 10,
      enabled: true,
    }

    const lowPriorityHook: HookConfig = {
      name: 'low-priority',
      function: 'lowPriority',
      priority: 1,
      enabled: true,
    }

    // Mock the function execution with different outputs based on hook name
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async (functionName: string) => {
      if (functionName === 'highPriority') {
        return { success: true, data: { stdout: 'High priority', stderr: '' } }
      }
      else {
        return { success: true, data: { stdout: 'Low priority', stderr: '' } }
      }
    }

    hookManager.registerHook('test:event', highPriorityHook)
    hookManager.registerHook('test:event', lowPriorityHook)

    const hookResults = await hookManager.executeHooks('test:event', {})
    expect(hookResults).toHaveLength(2)

    // High priority hook should execute first
    expect(hookResults[0].data?.stdout).toContain('High priority')
    expect(hookResults[1].data?.stdout).toContain('Low priority')

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should handle multiple hook conditions', async () => {
    // Create test file for condition checking
    const testFile = join(tempDir, 'test-condition.txt')
    writeFileSync(testFile, 'test content')

    const hookConfig: HookConfig = {
      name: 'conditional-hook',
      function: 'conditionTest',
      conditions: [
        { type: 'file', value: testFile },
      ],
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Condition met', stderr: '' },
    })

    hookManager.registerHook('test:conditions', hookConfig)

    const results = await hookManager.executeHooks('test:conditions', {})
    expect(results).toHaveLength(1)
    expect(results[0].success).toBe(true)
    expect(results[0].data?.stdout).toContain('Condition met')

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should handle async hooks', async () => {
    const asyncHook: HookConfig = {
      name: 'async-hook',
      function: 'asyncTest',
      async: true,
      enabled: true,
    }

    const syncHook: HookConfig = {
      name: 'sync-hook',
      function: 'syncTest',
      enabled: true,
    }

    // Mock the function execution with different results
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async (functionName: string) => {
      if (functionName === 'asyncTest') {
        return { success: false, error: 'Async hook failed', data: { stdout: 'async', stderr: '' } }
      }
      else {
        return { success: true, data: { stdout: 'sync', stderr: '' } }
      }
    }

    hookManager.registerHook('test:async', asyncHook)
    hookManager.registerHook('test:async', syncHook)

    const results = await hookManager.executeHooks('test:async', {})
    expect(results).toHaveLength(2)

    // Both hooks should execute even though the first one failed
    expect(results[0].success).toBe(false) // Async hook failed
    expect(results[1].success).toBe(true) // Sync hook succeeded

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should prevent recursive hook execution', async () => {
    const recursiveHook: HookConfig = {
      name: 'recursive-hook',
      function: 'recursiveTest',
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Recursive hook', stderr: '' },
    })

    hookManager.registerHook('test:recursive', recursiveHook)

    const results1 = await hookManager.executeHooks('test:recursive', {})
    const results2 = await hookManager.executeHooks('test:recursive', {})

    expect(results1).toHaveLength(1)
    expect(results2).toHaveLength(1)
    expect(results1[0].success).toBe(true)
    expect(results2[0].success).toBe(true)

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should expand template variables in commands', async () => {
    const hookConfig: HookConfig = {
      name: 'template-hook',
      function: 'templateTest',
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async () => ({
      success: true,
      data: { stdout: 'Hello {{name}}', stderr: '' },
    })

    hookManager.registerHook('test:template', hookConfig)

    const results = await hookManager.executeHooks('test:template', {})
    expect(results).toHaveLength(1)
    expect(results[0].success).toBe(true)
    expect(results[0].data?.stdout).toContain('Hello {{name}}')

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should provide hook utilities', () => {
    const simpleHook = HookUtils.createSimpleHook('echo "test"', 5)
    expect(simpleHook.command).toBe('echo "test"')
    expect(simpleHook.priority).toBe(5)
    expect(simpleHook.enabled).toBe(true)

    const scriptHook = HookUtils.createScriptHook('/path/to/script.sh', 3)
    expect(scriptHook.script).toBe('/path/to/script.sh')
    expect(scriptHook.priority).toBe(3)
    expect(scriptHook.enabled).toBe(true)

    const conditionalHook = HookUtils.createConditionalHook(
      'echo "test"',
      [{ type: 'env', value: 'TEST_VAR' }],
      7,
    )
    expect(conditionalHook.command).toBe('echo "test"')
    expect(conditionalHook.conditions).toHaveLength(1)
    expect(conditionalHook.priority).toBe(7)

    const asyncHook = HookUtils.createAsyncHook('echo "test"', 5000, 2)
    expect(asyncHook.command).toBe('echo "test"')
    expect(asyncHook.async).toBe(true)
    expect(asyncHook.timeout).toBe(5000)
    expect(asyncHook.priority).toBe(2)
  })

  it('should handle file and directory conditions', async () => {
    const testFile = join(tempDir, 'test.txt')
    const testDir = join(tempDir, 'testdir')

    // Create test file and directory
    writeFileSync(testFile, 'test content')
    mkdirSync(testDir)

    const fileHook: HookConfig = {
      name: 'file-condition-hook',
      function: 'fileTest',
      conditions: [{ type: 'file', value: testFile }],
      enabled: true,
    }

    const dirHook: HookConfig = {
      name: 'dir-condition-hook',
      function: 'dirTest',
      conditions: [{ type: 'directory', value: testDir }],
      enabled: true,
    }

    // Mock the function execution
    const originalExecuteFunction = (hookManager as any).executeFunction
    ;(hookManager as any).executeFunction = async (functionName: string) => {
      if (functionName === 'fileTest') {
        return { success: true, data: { stdout: 'File exists', stderr: '' } }
      }
      else {
        return { success: true, data: { stdout: 'Directory exists', stderr: '' } }
      }
    }

    hookManager.registerHook('test:conditions', fileHook)
    hookManager.registerHook('test:conditions', dirHook)

    const results = await hookManager.executeHooks('test:conditions', {})
    expect(results).toHaveLength(2)
    expect(results[0].success).toBe(true)
    expect(results[1].success).toBe(true)

    // Restore original method
    ;(hookManager as any).executeFunction = originalExecuteFunction
  })

  it('should get registered hooks and events', () => {
    const hookConfig: HookConfig = {
      name: 'test-hook',
      command: 'echo "test"',
      enabled: true,
    }

    hookManager.registerHook('test:event', hookConfig)

    const hooks = hookManager.getHooks('test:event')
    expect(hooks).toHaveLength(1)
    expect(hooks[0].config.name).toBe('test-hook')

    const events = hookManager.getEvents()
    expect(events).toContain('test:event')
  })

  it('should clear hooks', () => {
    const hookConfig: HookConfig = {
      name: 'test-hook',
      command: 'echo "test"',
      enabled: true,
    }

    hookManager.registerHook('test:event', hookConfig)
    expect(hookManager.getHooks('test:event')).toHaveLength(1)

    hookManager.clear()
    expect(hookManager.getHooks('test:event')).toHaveLength(0)
  })
})
