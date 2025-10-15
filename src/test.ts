import type { CommandResult } from './builtins/types'
import { mock } from 'bun:test'
import { defaultConfig } from './config'
import { KrustyShell } from './index'

/**
 * Creates a mock shell for testing that prevents actual git operations
 * and other potentially destructive commands from executing.
 *
 * @param tempDir - Optional temporary directory to set as working directory
 * @returns A KrustyShell instance with mocked executeCommand method
 */
export function createMockShell(tempDir?: string): KrustyShell {
  const shell = new KrustyShell({ ...defaultConfig, verbose: true }) // Set verbose: true to indicate "has changes"

  if (tempDir) {
    shell.changeDirectory(tempDir)
  }

  // Mock executeCommand to COMPLETELY prevent all external command execution
  shell.executeCommand = mock(async (command: string, args: string[]): Promise<CommandResult> => {
    // Mock git commands to return appropriate responses without executing
    if (command === 'git') {
      return mockGitCommand(args)
    }

    // Mock ALL other commands to prevent any external execution
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  })

  return shell
}

/**
 * Mock git command responses for testing
 */
function mockGitCommand(args: string[]): CommandResult {
  // Check if we're in a git repository
  if (args.includes('rev-parse') && args.includes('--is-inside-work-tree')) {
    return { exitCode: 0, stdout: 'true\n', stderr: '', duration: 0 }
  }

  // Mock git status operations
  if (args.includes('status')) {
    return { exitCode: 0, stdout: '## main...origin/main\n M src/builtins/wip.ts\n', stderr: '', duration: 0 }
  }

  // Mock git add operations
  if (args.includes('add')) {
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Mock git diff operations
  if (args.includes('diff')) {
    if (args.includes('--cached') && args.includes('--quiet')) {
      // Return non-zero to indicate there are staged changes (unless specifically testing no changes)
      return { exitCode: 1, stdout: '', stderr: '', duration: 0 }
    }
    if (args.includes('--cached') && args.includes('--stat')) {
      return { exitCode: 0, stdout: ' src/builtins/wip.ts | 14 ++++++++++----\n 1 file changed, 10 insertions(+), 4 deletions(-)\n', stderr: '', duration: 0 }
    }
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Mock git commit operations
  if (args.includes('commit')) {
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Mock git log operations
  if (args.includes('log')) {
    return { exitCode: 0, stdout: 'abc1234 chore: wip\n', stderr: '', duration: 0 }
  }

  // Mock git push operations
  if (args.includes('push')) {
    return { exitCode: 0, stdout: 'To https://github.com/stacksjs/krusty.git\n   a301d92..397f43c  main -> main\n', stderr: '', duration: 0 }
  }

  // Mock git config operations (prevent actual config changes)
  if (args.includes('config')) {
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Mock git init operations (prevent actual repo creation)
  if (args.includes('init')) {
    return { exitCode: 0, stdout: 'Initialized empty Git repository\n', stderr: '', duration: 0 }
  }

  // Default git command response
  return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
}

/**
 * Creates a mock shell that simulates no staged changes for git operations
 */
export function createMockShellWithNoChanges(tempDir?: string): KrustyShell {
  const shell = new KrustyShell({ ...defaultConfig, verbose: false })

  if (tempDir) {
    shell.changeDirectory(tempDir)
  }

  // Mock executeCommand to prevent all external command execution
  shell.executeCommand = mock(async (command: string, args: string[]): Promise<CommandResult> => {
    // Mock git commands for no changes scenario
    if (command === 'git') {
      return mockGitCommandNoChanges(args)
    }

    // Mock all other commands
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  })

  return shell
}

/**
 * Mock git command responses for no changes scenario
 */
function mockGitCommandNoChanges(args: string[]): CommandResult {
  // Check if we're in a git repository
  if (args.includes('rev-parse') && args.includes('--is-inside-work-tree')) {
    return { exitCode: 0, stdout: 'true\n', stderr: '', duration: 0 }
  }

  // Mock git add operations
  if (args.includes('add')) {
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Mock git diff operations - return 0 to indicate no staged changes
  if (args.includes('diff')) {
    if (args.includes('--cached') && args.includes('--quiet')) {
      return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
    }
    return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
  }

  // Default git command response
  return { exitCode: 0, stdout: '', stderr: '', duration: 0 }
}
