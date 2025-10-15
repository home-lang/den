import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createMockShell, createMockShellWithNoChanges } from '../src/test'

describe('wip builtin', () => {
  let tempDir: string

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), 'krusty-wip-'))
  })

  afterEach(async () => {
    try {
      await rm(tempDir, { recursive: true, force: true })
    }
    catch {
      // Ignore cleanup errors
    }
  })

  it('prints banner and skips commit when no staged changes', async () => {
    const shell = createMockShellWithNoChanges(tempDir)
    const { wipCommand } = await import('../src/builtins/wip')

    const res = await wipCommand.execute(['--no-push', '--force-color'], shell)
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('no changes to commit; skipping push')
    shell.stop()
  })

  it('commits staged changes and does not push with --no-push', async () => {
    const shell = createMockShell(tempDir)
    const { wipCommand } = await import('../src/builtins/wip')
    // create a file (but don't actually use git)
    await writeFile(join(tempDir, 'a.txt'), 'hello')

    const res = await wipCommand.execute(['--no-push', '-m', 'wip: test', '--force-color'], shell)
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('1 file changed')
    expect(res.stdout).toContain('abc1234 wip: test')
    shell.stop()
  })

  it('supports --amend', async () => {
    const shell = createMockShell(tempDir)
    const { wipCommand } = await import('../src/builtins/wip')
    // create files (but don't actually use git)
    await writeFile(join(tempDir, 'init.txt'), 'init')
    await writeFile(join(tempDir, 'b.txt'), 'b')

    const res = await wipCommand.execute(['--amend', '--no-push', '--force-color'], shell)
    expect(res.exitCode).toBe(0)
    expect(res.stdout).toContain('1 file changed')
    expect(res.stdout).toContain('abc1234 chore: wip')
    shell.stop()
  })
})
