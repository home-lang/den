import type { ModuleContext, ModuleResult } from '../types'
import { exec } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { BaseModule } from './index'

const execAsync = promisify(exec)

// Git branch module
export class GitBranchModule extends BaseModule {
  name = 'git_branch'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!context.gitInfo?.isRepo
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const gitInfo = context.gitInfo
    if (!gitInfo?.isRepo || !gitInfo.branch)
      return null

    // Read formatting from ModuleConfig
    const cfg = context.config?.git_branch || {}
    const symbol = cfg.symbol ?? ''
    const format = cfg.format ?? 'on {symbol} {branch}'
    const branch = gitInfo.branch
    const content = format
      .replace('{symbol}', symbol)
      .replace('{branch}', branch)

    // Defer styling to prompt/theme; no color here
    return this.formatResult(content)
  }
}

// Git commit module
export class GitCommitModule extends BaseModule {
  name = 'git_commit'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!context.gitInfo?.isRepo
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    try {
      const cfg = context.config?.git_commit || {}
      const len = (cfg.commit_hash_length as number) ?? 7
      const { stdout } = await execAsync(`git rev-parse --short=${len} HEAD`, { cwd: context.cwd })
      const hash = stdout.trim()

      if (!hash)
        return null

      const format = cfg.format ?? '({hash})'
      const content = format.replace('{hash}', hash)
      return this.formatResult(content)
    }
    catch {
      return null
    }
  }
}

// Git state module
export class GitStateModule extends BaseModule {
  name = 'git_state'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!context.gitInfo?.isRepo && this.hasGitState(context.cwd)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const state = this.getGitState(context.cwd)
    if (!state)
      return null

    // Get configuration from context
    const config = context.config?.git_state || {}

    // Use custom symbols from config if available; no colors here
    const stateMap: Record<string, { symbol: string }> = {
      REBASE: {
        symbol: config.rebase || '🔄 REBASING',
      },
      MERGE: {
        symbol: config.merge || '🔀 MERGING',
      },
      CHERRY_PICK: {
        symbol: config.cherry_pick || '🍒 PICKING',
      },
      REVERT: {
        symbol: config.revert || '↩️ REVERTING',
      },
      BISECT: {
        symbol: config.bisect || '🔍 BISECTING',
      },
    }

    const stateInfo = stateMap[state] || { symbol: state }

    // Try to get progress information if available
    let progressInfo = ''
    try {
      if (state === 'REBASE' || state === 'CHERRY_PICK') {
        const { stdout } = await execAsync('git status --porcelain', { cwd: context.cwd })
        const lines = stdout.trim().split('\n').filter(line => line.length > 0)
        if (lines.length > 0) {
          progressInfo = ` ${lines.length} files`
        }
      }
    }
    catch {
      // Ignore errors getting progress
    }

    const content = `(${stateInfo.symbol}${progressInfo})`
    return this.formatResult(content)
  }

  private hasGitState(cwd: string): boolean {
    const gitDir = join(cwd, '.git')
    const states = ['REBASE_HEAD', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG']

    return states.some(state => existsSync(join(gitDir, state)))
  }

  private getGitState(cwd: string): string | null {
    const gitDir = join(cwd, '.git')

    if (existsSync(join(gitDir, 'REBASE_HEAD')))
      return 'REBASE'
    if (existsSync(join(gitDir, 'MERGE_HEAD')))
      return 'MERGE'
    if (existsSync(join(gitDir, 'CHERRY_PICK_HEAD')))
      return 'CHERRY_PICK'
    if (existsSync(join(gitDir, 'REVERT_HEAD')))
      return 'REVERT'
    if (existsSync(join(gitDir, 'BISECT_LOG')))
      return 'BISECT'

    return null
  }
}

// Git status module
export class GitStatusModule extends BaseModule {
  name = 'git_status'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!context.gitInfo?.isRepo
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const gitInfo = context.gitInfo
    if (!gitInfo?.isRepo)
      return null

    // Get configuration from context
    const config = context.config?.git_status || {}

    // Debug logging of git status configuration
    context.logger.debug('GitStatusModule config:', JSON.stringify(config, null, 2))
    context.logger.debug('GitStatusModule ahead symbol:', config.ahead)

    const parts: string[] = []

    // Ahead/behind
    if (gitInfo.ahead && gitInfo.ahead > 0) {
      const symbol = config.ahead || '⇡'
      parts.push(`${symbol}${gitInfo.ahead}`)
    }
    if (gitInfo.behind && gitInfo.behind > 0) {
      const symbol = config.behind || '⇣'
      parts.push(`${symbol}${gitInfo.behind}`)
    }

    // File status with custom symbols
    if (gitInfo.staged && gitInfo.staged > 0) {
      const symbol = config.staged || '●'
      parts.push(`${symbol}${gitInfo.staged}`)
    }
    if (gitInfo.unstaged && gitInfo.unstaged > 0) {
      const symbol = config.modified || '○'
      parts.push(`${symbol}${gitInfo.unstaged}`)
    }
    if (gitInfo.untracked && gitInfo.untracked > 0) {
      const symbol = config.untracked || '?'
      parts.push(`${symbol}${gitInfo.untracked}`)
    }
    if (gitInfo.stashed && gitInfo.stashed > 0) {
      const symbol = config.stashed || '$'
      parts.push(`${symbol}${gitInfo.stashed}`)
    }

    // Check for conflicted files
    try {
      const { stdout } = await execAsync('git diff --name-only --diff-filter=U', { cwd: context.cwd })
      if (stdout.trim()) {
        const conflictedCount = stdout.trim().split('\n').length
        const symbol = config.conflicted || '🏳'
        parts.push(`${symbol}${conflictedCount}`)
      }
    }
    catch {
      // Ignore errors
    }

    if (parts.length === 0)
      return null

    const format = config.format || '[{status}]'
    const content = format.replace('{status}', parts.join(' '))
    return this.formatResult(content)
  }
}

// Git metrics module (shows +/- lines)
export class GitMetricsModule extends BaseModule {
  name = 'git_metrics'
  enabled = true

  detect(context: ModuleContext): boolean {
    return !!context.gitInfo?.isRepo
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    try {
      const { stdout } = await execAsync('git diff --numstat', { cwd: context.cwd })
      if (!stdout.trim())
        return null

      let added = 0
      let deleted = 0

      const lines = stdout.trim().split('\n')
      for (const line of lines) {
        const [addedStr, deletedStr] = line.split('\t')
        if (addedStr !== '-')
          added += Number.parseInt(addedStr, 10) || 0
        if (deletedStr !== '-')
          deleted += Number.parseInt(deletedStr, 10) || 0
      }

      if (added === 0 && deleted === 0)
        return null

      const cfg = context.config?.git_metrics || {}
      const format = cfg.format || '({metrics})'
      const metricsParts: string[] = []
      if (added > 0)
        metricsParts.push(`+${added}`)
      if (deleted > 0)
        metricsParts.push(`-${deleted}`)

      const content = format.replace('{metrics}', metricsParts.join('/'))
      return this.formatResult(content)
    }
    catch {
      return null
    }
  }
}
