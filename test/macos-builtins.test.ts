import type { Shell } from '../src/types'
import { describe, expect, it } from 'bun:test'
import { createBuiltins } from '../src/builtins'

// Minimal shell stub shared with other tests
function makeShell(): Shell {
  return {
    config: { verbose: false, streamOutput: false },
    cwd: process.cwd(),
    environment: process.env as unknown as Record<string, string>,
    history: [],
    aliases: {},
    builtins: createBuiltins(),
    log: console as any,

    async execute(cmd: string) {
      return this.executeCommand('sh', ['-c', cmd])
    },
    async executeCommand(command: string, args: string[]) {
      const proc = Bun.spawn([command, ...args], { stdout: 'pipe', stderr: 'pipe' })
      const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()])
      const exitCode = await proc.exited
      return { exitCode, stdout, stderr, duration: 0 }
    },
    parseCommand: () => Promise.resolve({ commands: [] }),
    changeDirectory: () => true,
    reload: async () => ({ exitCode: 0, stdout: '', stderr: '', duration: 0 }),

    start: async () => {},
    stop: () => {},

    renderPrompt: async () => '$ ',

    addToHistory: () => {},
    searchHistory: () => [],

    getCompletions: () => [],

    jobs: [],
    addJob: () => 0,
    removeJob: () => true,
    getJob: () => undefined,
    getJobs: () => [],
    setJobStatus: () => true,
  }
}

function runBuiltin(shell: Shell, name: string, args: string[] = []) {
  const cmd = shell.builtins.get(name)
  if (!cmd)
    throw new Error(`Builtin not found: ${name}`)
  return cmd.execute(args, shell)
}

describe('macOS helper builtins', () => {
  it('reloaddns should complete or provide guidance', async () => {
    const shell = makeShell()
    const res = await runBuiltin(shell, 'reloaddns')
    if (res.exitCode === 0) {
      expect(res.stdout).toContain('DNS cache')
    }
    else {
      expect(res.stderr).toMatch(/reloaddns:/)
    }
  })

  it('show should toggle Finder setting or fail gracefully', async () => {
    const shell = makeShell()
    const res = await runBuiltin(shell, 'show')
    if (res.exitCode === 0)
      expect(res.stdout).toContain('Finder hidden files: ON')
    else
      expect(res.stderr).toMatch(/show:|unsupported/)
  })

  it('hide should toggle Finder setting or fail gracefully', async () => {
    const shell = makeShell()
    const res = await runBuiltin(shell, 'hide')
    if (res.exitCode === 0)
      expect(res.stdout).toContain('Finder hidden files: OFF')
    else
      expect(res.stderr).toMatch(/hide:|unsupported/)
  })

  it('ft should attempt to restart Touch Bar or fail gracefully', async () => {
    const shell = makeShell()
    const res = await runBuiltin(shell, 'ft')
    if (res.exitCode === 0)
      expect(res.stdout).toContain('Touch Bar')
    else
      expect(res.stderr).toMatch(/ft:|unsupported/)
  })

  it('emptytrash should run without throwing and be safe', async () => {
    const shell = makeShell()
    const res = await runBuiltin(shell, 'emptytrash')
    if (res.exitCode === 0)
      expect(res.stdout).toContain('Trash')
    else
      expect(res.stderr).toMatch(/emptytrash:/)
  })

  it('dotfiles should use $EDITOR or default to code', async () => {
    const shell = makeShell()

    // Track calls to executeCommand
    const calls: Array<{ command: string, args: string[] }> = []
    const originalExecute = shell.executeCommand

    // Mock executeCommand to track calls and prevent actual execution
    shell.executeCommand = async (command: string, args: string[] = []) => {
      calls.push({ command, args })

      // For command -v checks, simulate command exists
      if (args?.[1]?.includes('command -v')) {
        return { exitCode: 0, stdout: '/usr/bin/editor', stderr: '', duration: 0 }
      }

      // For actual editor execution, just return success without running anything
      if (command === 'sh' && args[1]?.startsWith('command -v')) {
        const editor = args[1].split(' ')[2]
        return { exitCode: 0, stdout: `/usr/bin/${editor}`, stderr: '', duration: 0 }
      }

      // For editor execution
      if (['code', 'nano', 'vim', 'open'].includes(command)) {
        return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
      }

      // Default response for any other command
      return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
    }

    try {
      // Test with no DOTFILES set (should error)
      delete shell.environment.DOTFILES
      const res = await runBuiltin(shell, 'dotfiles')
      expect(res.exitCode).toBe(1)
      expect(res.stderr).toContain('DOTFILES environment variable is not set')

      // Test with DOTFILES set but no editor (should use default 'code')
      shell.environment.DOTFILES = '/path/to/dotfiles'
      calls.length = 0 // Reset calls
      await runBuiltin(shell, 'dotfiles')

      // Verify it checked for 'code' command
      const codeCheck = calls.find(call =>
        call.command === 'sh'
        && call.args[1].includes('command -v code'),
      )
      expect(codeCheck).toBeDefined()

      // Test with explicit editor
      shell.environment.EDITOR = 'nano'
      calls.length = 0 // Reset calls
      await runBuiltin(shell, 'dotfiles')

      // Verify it checked for 'nano' command
      const nanoCheck = calls.find(call =>
        call.command === 'sh'
        && call.args[1].includes('command -v nano'),
      )
      expect(nanoCheck).toBeDefined()

      // Test with editor as argument
      calls.length = 0 // Reset calls
      await runBuiltin(shell, 'dotfiles', ['vim'])

      // Verify it checked for 'vim' command
      const vimCheck = calls.find(call =>
        call.command === 'sh'
        && call.args[1].includes('command -v vim'),
      )
      expect(vimCheck).toBeDefined()
    }
    finally {
      // Restore original executeCommand
      shell.executeCommand = originalExecute
    }
  })

  it('code should open current directory or return a helpful error', async () => {
    const shell = makeShell()
    const originalExecute = shell.executeCommand

    // Mock executeCommand to prevent actual execution
    shell.executeCommand = async (command: string, args: string[] = []) => {
      // For command -v checks, simulate command exists
      if (command === 'sh' && args[1]?.includes('command -v')) {
        return { exitCode: 0, stdout: '/usr/local/bin/code', stderr: '', duration: 0 }
      }

      // For code command, simulate success
      if (command === 'code') {
        return { exitCode: 0, stdout: shell.cwd, stderr: '', duration: 0 }
      }

      // For any other command, simulate not found
      return { exitCode: 1, stdout: '', stderr: 'command not found', duration: 0 }
    }

    try {
      const res = await runBuiltin(shell, 'code')
      if (res.exitCode === 0) {
        expect(res.stdout.trim().length).toBeGreaterThan(0)
      }
      else {
        expect(res.stderr).toMatch(/code:|not found/)
      }
    }
    finally {
      // Restore original executeCommand
      shell.executeCommand = originalExecute
    }
  })

  it('pstorm should open current directory or return a helpful error', async () => {
    const shell = makeShell()
    const originalExecute = shell.executeCommand

    // Mock executeCommand to prevent actual execution
    shell.executeCommand = async (command: string, args: string[] = []) => {
      // For command -v checks, simulate command exists
      if (command === 'sh' && args[1]?.includes('command -v')) {
        return { exitCode: 0, stdout: '/usr/local/bin/pstorm', stderr: '', duration: 0 }
      }

      // For pstorm command, simulate success
      if (command === 'pstorm') {
        return { exitCode: 0, stdout: shell.cwd, stderr: '', duration: 0 }
      }

      // For open command (macOS fallback), simulate success
      if (command === 'open' && args[0] === '-a' && args[1] === 'PhpStorm') {
        return { exitCode: 0, stdout: shell.cwd, stderr: '', duration: 0 }
      }

      // For any other command, simulate not found
      return { exitCode: 1, stdout: '', stderr: 'command not found', duration: 0 }
    }

    try {
      const res = await runBuiltin(shell, 'pstorm')
      if (res.exitCode === 0) {
        expect(res.stdout.trim().length).toBeGreaterThan(0)
      }
      else {
        expect(res.stderr).toMatch(/pstorm:|not found/)
      }
    }
    finally {
      // Restore original executeCommand
      shell.executeCommand = originalExecute
    }
  })
})
