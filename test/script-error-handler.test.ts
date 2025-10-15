import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { KrustyShell } from '../src/shell'
import { ScriptErrorHandler } from '../src/utils/script-error-handler'

describe('ScriptErrorHandler', () => {
  let shell: KrustyShell
  let scriptErrorHandler: ScriptErrorHandler
  let testPackageJsonPath: string

  beforeEach(() => {
    shell = new KrustyShell()
    scriptErrorHandler = new ScriptErrorHandler(shell)
    testPackageJsonPath = join(process.cwd(), 'package.json.backup')

    // Backup existing package.json if it exists
    const realPackageJsonPath = join(process.cwd(), 'package.json')
    if (existsSync(realPackageJsonPath)) {
      const realPackageJson = readFileSync(realPackageJsonPath, 'utf-8')
      writeFileSync(testPackageJsonPath, realPackageJson)
    }

    // Create a test package.json with some scripts
    const testPackageJson = {
      name: 'test-package',
      scripts: {
        build: 'echo building',
        test: 'echo testing',
        dev: 'echo developing',
        start: 'echo starting',
        lint: 'echo linting',
      },
    }
    writeFileSync(realPackageJsonPath, JSON.stringify(testPackageJson, null, 2))
  })

  afterEach(() => {
    const realPackageJsonPath = join(process.cwd(), 'package.json')
    
    // Restore original package.json if backup exists
    if (existsSync(testPackageJsonPath)) {
      const backupContent = readFileSync(testPackageJsonPath, 'utf-8')
      writeFileSync(realPackageJsonPath, backupContent)
      unlinkSync(testPackageJsonPath)
    } else {
      // Remove test package.json if no backup existed
      if (existsSync(realPackageJsonPath)) {
        unlinkSync(realPackageJsonPath)
      }
    }
  })

  describe('handleBunRunError', () => {
    it('should enhance script not found errors with suggestions', () => {
      const stderr = 'error: Script not found "buil"'
      const result = scriptErrorHandler.handleBunRunError(stderr, 'buil')

      expect(result.stderr).toContain('Script not found "buil"')
      expect(result.stderr).toContain('Did you mean "build"?')
      expect(result.suggestion).toBe('build')
    })

    it('should return original stderr if no similar script found', () => {
      const stderr = 'error: Script not found "nonexistent"'
      const result = scriptErrorHandler.handleBunRunError(stderr, 'nonexistent')

      expect(result.stderr).toContain('Script not found "nonexistent"')
      expect(result.suggestion).toBeUndefined()
    })

    it('should return original stderr if not a script not found error', () => {
      const stderr = 'Some other error occurred'
      const result = scriptErrorHandler.handleBunRunError(stderr, 'build')

      expect(result.stderr).toBe(stderr)
      expect(result.suggestion).toBeUndefined()
    })
  })
})

describe('Shell Integration with ScriptErrorHandler and Yes Builtin', () => {
  let shell: KrustyShell
  let testPackageJsonPath: string

  beforeEach(() => {
    shell = new KrustyShell()
    testPackageJsonPath = join(process.cwd(), 'package.json.backup')

    // Backup existing package.json if it exists
    const realPackageJsonPath = join(process.cwd(), 'package.json')
    if (existsSync(realPackageJsonPath)) {
      const realPackageJson = readFileSync(realPackageJsonPath, 'utf-8')
      writeFileSync(testPackageJsonPath, realPackageJson)
    }

    // Create a test package.json with some scripts
    const testPackageJson = {
      name: 'test-package',
      scripts: {
        build: 'echo building',
        test: 'echo testing',
        dev: 'echo developing',
      },
    }
    writeFileSync(realPackageJsonPath, JSON.stringify(testPackageJson, null, 2))
  })

  afterEach(() => {
    const realPackageJsonPath = join(process.cwd(), 'package.json')
    
    // Restore original package.json if backup exists
    if (existsSync(testPackageJsonPath)) {
      const backupContent = readFileSync(testPackageJsonPath, 'utf-8')
      writeFileSync(realPackageJsonPath, backupContent)
      unlinkSync(testPackageJsonPath)
    } else {
      // Remove test package.json if no backup existed
      if (existsSync(realPackageJsonPath)) {
        unlinkSync(realPackageJsonPath)
      }
    }
  })

  it('should enhance bun run errors and store suggestions', async () => {
    // Mock the command execution to simulate a script not found error
    const originalExecute = (shell as any).commandChainExecutor.executeCommandChain
    ;(shell as any).commandChainExecutor.executeCommandChain = async () => ({
      exitCode: 1,
      stdout: '',
      stderr: 'error: Script not found "buil"',
      duration: 100,
      streamed: false,
    })

    const result = await shell.execute('bun run buil')

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain('Script not found "buil"')
    expect(result.stderr).toContain('Did you mean "build"?')

    // Check that suggestion was stored
    const suggestion = (shell as any).lastScriptSuggestion
    expect(suggestion).toBeDefined()
    expect(suggestion.suggestion).toBe('build')
    expect(suggestion.originalCommand).toBe('bun run buil')

    // Restore original method
    ;(shell as any).commandChainExecutor.executeCommandChain = originalExecute
  })

  it('should execute suggested script with yes builtin', async () => {
    // First, simulate a failed bun run command that creates a suggestion
    const originalExecute = (shell as any).commandChainExecutor.executeCommandChain.bind((shell as any).commandChainExecutor)
    ;(shell as any).commandChainExecutor.executeCommandChain = async () => ({
      exitCode: 1,
      stdout: '',
      stderr: 'error: Script not found "buil"',
      duration: 100,
      streamed: false
    })

    await shell.execute('bun run buil')
    
    // Now mock successful execution for the suggested script
    ;(shell as any).commandChainExecutor.executeCommandChain = async (command: string) => {
      if (command.includes('bun run build')) {
        return {
          exitCode: 0,
          stdout: 'building',
          stderr: '',
          duration: 100,
          streamed: false
        }
      }
      return originalExecute(command)
    }

    // Execute yes builtin
    const yesResult = await shell.execute('yes')
    
    expect(yesResult.exitCode).toBe(0)
    expect(yesResult.stdout).toBe('building')
    
    // Check that suggestion was cleared
    const suggestion = (shell as any).lastScriptSuggestion
    expect(suggestion).toBeNull()
    
    // Restore original method
    ;(shell as any).commandChainExecutor.executeCommandChain = originalExecute
  })

  it('should handle yes builtin when no suggestion available', async () => {
    const result = await shell.execute('yes')

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain('No script suggestion available')
  })

  it('should handle expired suggestions', async () => {
    // Manually set an expired suggestion
    ;(shell as any).lastScriptSuggestion = {
      originalCommand: 'bun run buil',
      suggestion: 'build',
      timestamp: Date.now() - (6 * 60 * 1000), // 6 minutes ago
    }

    const result = await shell.execute('yes')

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain('Script suggestion has expired')

    // Check that expired suggestion was cleared
    const suggestion = (shell as any).lastScriptSuggestion
    expect(suggestion).toBeNull()
  })

  it('should not modify stderr for successful bun run commands', async () => {
    // Mock successful execution
    const originalExecute = (shell as any).commandChainExecutor.executeCommandChain
    ;(shell as any).commandChainExecutor.executeCommandChain = async () => ({
      exitCode: 0,
      stdout: 'building',
      stderr: '',
      duration: 100,
      streamed: false,
    })

    const result = await shell.execute('bun run build')

    expect(result.exitCode).toBe(0)
    expect(result.stderr).toBe('')

    // Check that no suggestion was stored
    const suggestion = (shell as any).lastScriptSuggestion
    expect(suggestion).toBeNull()

    // Restore original method
    ;(shell as any).commandChainExecutor.executeCommandChain = originalExecute
  })

  it('should not modify stderr for non-bun-run commands', async () => {
    // Mock command execution with error
    const originalExecute = (shell as any).commandChainExecutor.executeCommandChain
    ;(shell as any).commandChainExecutor.executeCommandChain = async () => ({
      exitCode: 1,
      stdout: '',
      stderr: 'command not found: nonexistent',
      duration: 100,
      streamed: false,
    })

    const result = await shell.execute('nonexistent')

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toBe('command not found: nonexistent')

    // Check that no suggestion was stored
    const suggestion = (shell as any).lastScriptSuggestion
    expect(suggestion).toBeNull()

    // Restore original method
    ;(shell as any).commandChainExecutor.executeCommandChain = originalExecute
  })
})
