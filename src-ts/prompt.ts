import type { GitInfo, KrustyConfig, PromptSegment, SystemInfo } from './types'
import { exec } from 'node:child_process'
import { existsSync } from 'node:fs'
import { arch, homedir, hostname, platform, userInfo } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'
import { promisify } from 'node:util'

const execAsync = promisify(exec)

export class PromptRenderer {
  private simpleMode: boolean
  constructor(private config: KrustyConfig) {
    // Simple mode triggers when:
    // - Not a TTY, or TERM=dumb
    // - NO_COLOR/CLICOLOR=0/FORCE_COLOR=0
    // - Or config.prompt?.simpleWhenNotTTY !== false (default true)
    const env = process.env || {}
    const notTty = !(process.stdout && process.stdout.isTTY)
    const term = (env.TERM || '').toLowerCase()
    const termDumb = term === 'dumb'
    const noColor = (env.NO_COLOR !== undefined) || (env.FORCE_COLOR === '0') || (env.CLICOLOR === '0')
    const cfgSimpleWhenNotTTY = this.config.prompt?.simpleWhenNotTTY !== false
    this.simpleMode = !!(cfgSimpleWhenNotTTY && (notTty || termDumb || noColor))
    // In test environments, force colors to be enabled so unit tests that
    // assert on ANSI sequences and color differences are reliable.
    if ((process.env.NODE_ENV || '').toLowerCase() === 'test' || (process.env.BUN_ENV || '').toLowerCase() === 'test')
      this.simpleMode = false
  }

  async render(cwd: string, systemInfo: SystemInfo, gitInfo: GitInfo, exitCode: number, lastDurationMs?: number): Promise<string> {
    const format = this.config.prompt?.format || '{user}@{host} {path}{git} {symbol} '
    return this.renderFormat(format, cwd, systemInfo, gitInfo, exitCode, lastDurationMs)
  }

  async renderRight(cwd: string, systemInfo: SystemInfo, gitInfo: GitInfo, exitCode: number): Promise<string> {
    const format = this.config.prompt?.rightPrompt
    if (!format)
      return ''
    return this.renderFormat(format, cwd, systemInfo, gitInfo, exitCode)
  }

  private async renderFormat(format: string, cwd: string, systemInfo: SystemInfo, gitInfo: GitInfo, exitCode: number, lastDurationMs?: number): Promise<string> {
    let result = format

    // Replace placeholders
    result = result.replace(/\{user\}/g, this.renderUser(systemInfo))
    result = result.replace(/\{host\}/g, this.renderHost(systemInfo))
    result = result.replace(/\{path\}/g, this.renderPath(cwd))

    // Render git asynchronously since it now uses modules
    const gitContent = await this.renderGit(gitInfo, cwd)
    result = result.replace(/\{git\}/g, gitContent)

    const modulesContent = this.renderModules(systemInfo, gitInfo)
    result = result.replace(/\{modules\}/g, modulesContent)

    result = result.replace(/\{symbol\}/g, this.renderSymbol(exitCode))
    result = result.replace(/\{exitcode\}/g, this.renderExitCode(exitCode))
    result = result.replace(/\{time\}/g, this.renderTime())
    result = result.replace(/\{duration\}/g, this.renderDuration(lastDurationMs))

    return result
  }

  private renderUser(systemInfo: SystemInfo): string {
    // Starship-like: use primary cyan for user by default
    return this.colorize(systemInfo.user, this.config.theme?.colors?.primary || '#00D9FF')
  }

  private renderHost(systemInfo: SystemInfo): string {
    // Starship-like: use primary cyan for host by default
    return this.colorize(systemInfo.hostname, this.config.theme?.colors?.primary || '#00D9FF')
  }

  private renderPath(cwd: string): string {
    if (!this.config.prompt?.showPath)
      return ''

    let displayPath = cwd
    const home = homedir()

    if (displayPath.startsWith(home)) {
      displayPath = displayPath.replace(home, '~')
    }

    // Truncate long paths
    const maxLength = 50
    if (displayPath.length > maxLength) {
      const parts = displayPath.split('/')
      if (parts.length > 3) {
        displayPath = `${parts[0]}/.../${parts[parts.length - 2]}/${parts[parts.length - 1]}`
      }
    }

    return this.boldColorize(displayPath, this.config.theme?.colors?.primary || '#00D9FF')
  }

  private async renderGit(gitInfo: GitInfo, _cwd: string): Promise<string> {
    if (!this.config.prompt?.showGit || !gitInfo.isRepo)
      return ''

    const segments: string[] = []

    // Add branch name with custom symbol if available
    const branchSymbol = this.simpleEmoji(this.config.theme?.symbols?.git?.branch || '🌱')
    const customBranchColor = this.config.theme?.colors?.git?.branch
    const branchBold = this.config.theme?.gitStatus?.branchBold ?? true
    if (gitInfo.branch) {
      const branchOnly = gitInfo.branch
      if (customBranchColor) {
        // Color configured: colorize the branch name (bold optional), keep symbol unstyled
        const styledBranch = branchBold
          ? this.boldColorize(branchOnly, customBranchColor)
          : this.colorize(branchOnly, customBranchColor)
        segments.push(` ${branchSymbol} ${styledBranch}`)
      }
      else {
        // No color configured: optionally bold only the branch name
        const styledBranch = (branchBold && !this.simpleMode)
          ? `\x1B[1m${branchOnly}\x1B[22m`
          : branchOnly
        segments.push(` ${branchSymbol} ${styledBranch}`)
      }
    }

    // Detailed status indicators in a compact format, using theme flags
    const gitStatusCfg = this.config.theme?.gitStatus || {}
    const sym = this.config.theme?.symbols?.git || {}
    const statusParts: string[] = []

    // Ahead/Behind counts
    if ((gitStatusCfg.showAheadBehind ?? true) && gitInfo.ahead && gitInfo.ahead > 0) {
      const color = this.config.theme?.colors?.git?.ahead || '#50FA7B'
      statusParts.push(this.colorize(`${sym.ahead ?? '⇡'}${gitInfo.ahead}`, color))
    }
    if ((gitStatusCfg.showAheadBehind ?? true) && gitInfo.behind && gitInfo.behind > 0) {
      const color = this.config.theme?.colors?.git?.behind || '#FF5555'
      statusParts.push(this.colorize(`${sym.behind ?? '⇣'}${gitInfo.behind}`, color))
    }

    // Staged changes
    if ((gitStatusCfg.showStaged ?? true) && gitInfo.staged && gitInfo.staged > 0) {
      const color = this.config.theme?.colors?.git?.staged || '#00FF88'
      statusParts.push(this.colorize(`${sym.staged ?? '●'}${gitInfo.staged}`, color))
    }

    // Unstaged changes
    if ((gitStatusCfg.showUnstaged ?? true) && gitInfo.unstaged && gitInfo.unstaged > 0) {
      const color = this.config.theme?.colors?.git?.unstaged || '#FFD700'
      statusParts.push(this.colorize(`${sym.unstaged ?? '○'}${gitInfo.unstaged}`, color))
    }

    // Untracked files
    if ((gitStatusCfg.showUntracked ?? true) && gitInfo.untracked && gitInfo.untracked > 0) {
      const color = this.config.theme?.colors?.git?.untracked || '#FF4757'
      statusParts.push(this.colorize(`${sym.untracked ?? '?'}${gitInfo.untracked}`, color))
    }

    if (statusParts.length > 0) {
      const inside = statusParts.join('')
      segments.push(`${this.dim('[')}${inside}${this.dim(']')}`)
    }

    // Return only the git segments; wording like 'on' should be handled in the format string
    return segments.length > 0 ? `${segments.join(' ')}` : ''
  }

  private renderSymbol(exitCode: number): string {
    const symbol = this.simpleEmoji(this.config.theme?.symbols?.prompt || '❯')
    // Use different colors based on exit code
    const color = exitCode === 0
      ? this.config.theme?.colors?.primary || '#00D9FF' // Success: turquoise
      : this.config.theme?.colors?.error || '#FF4757' // Error: red

    return this.colorize(symbol, color)
  }

  private renderExitCode(exitCode: number): string {
    if (!this.config.prompt?.showExitCode || exitCode === 0)
      return ''
    return this.colorize(`${exitCode}`, this.config.theme?.colors?.error || '#FF4757')
  }

  private renderTime(): string {
    if (!this.config.prompt?.showTime)
      return ''
    const now = new Date()
    const timeString = now.toLocaleTimeString('en-US', { hour12: false })
    return this.colorize(timeString, this.config.theme?.colors?.info || '#74B9FF')
  }

  private renderModules(systemInfo: SystemInfo, _gitInfo: GitInfo): string {
    const modules = []
    const pushModule = (content: string, color: string) => {
      if (content.startsWith('via ')) {
        modules.push('via')
        const rest = content.slice(4).trimStart()
        modules.push(this.boldColorize(rest, color))
      }
      else {
        modules.push(this.boldColorize(content, color))
      }
    }

    // Add package version first (if present) so it appears before runtime info
    if (this.hasFile('package.json')) {
      const packageJson = this.readPackageJson()
      const pkgVersion = packageJson?.version
      if (pkgVersion) {
        const pkgColor = this.config.theme?.colors?.modules?.packageVersion || '#FFA500'
        modules.push(this.boldColorize(`${this.simpleEmoji('📦')} v${pkgVersion}`, pkgColor))
      }
    }

    // Runtime modules: prefer Bun when present and enabled; otherwise Node.js when enabled
    const bunModuleCfg = this.config.modules?.bun
    const nodeModuleCfg = this.config.modules?.nodejs

    const bunEnabled = bunModuleCfg?.enabled !== false
    const nodeEnabled = nodeModuleCfg?.enabled !== false

    if (bunEnabled && systemInfo.bunVersion && systemInfo.bunVersion !== 'unknown') {
      const symbol = this.simpleEmoji(bunModuleCfg?.symbol || '🐰')
      const format = bunModuleCfg?.format || 'via {symbol} {version}'
      const bunColor = this.config.theme?.colors?.modules?.bunVersion || '#FF6B6B'
      const content = format
        .replace('{symbol}', symbol)
        .replace('{version}', `v${systemInfo.bunVersion}`)
      pushModule(content, bunColor)
    }
    else if (nodeEnabled) {
      const symbol = this.simpleEmoji(nodeModuleCfg?.symbol || '⬢')
      const format = nodeModuleCfg?.format || 'via {symbol} {version}'
      const content = format
        .replace('{symbol}', symbol)
        .replace('{version}', systemInfo.nodeVersion)
      // Use a friendly default color for Node when not customized
      pushModule(content, this.config.theme?.colors?.success || '#00FF88')
    }

    // Detect Python projects
    if (this.hasFile('requirements.txt') || this.hasFile('pyproject.toml') || this.hasFile('setup.py')) {
      modules.push(this.colorize(`${this.simpleEmoji('🐍')} python`, this.config.theme?.colors?.warning || '#FFD700'))
    }

    // Detect Go projects
    if (this.hasFile('go.mod') || this.hasFile('go.sum')) {
      modules.push(this.colorize(`${this.simpleEmoji('🐹')} go`, this.config.theme?.colors?.info || '#74B9FF'))
    }

    // Detect Rust projects
    if (this.hasFile('Cargo.toml')) {
      modules.push(this.colorize(`${this.simpleEmoji('🦀')} rust`, this.config.theme?.colors?.error || '#FF4757'))
    }

    // Detect Docker projects
    if (this.hasFile('Dockerfile') || this.hasFile('docker-compose.yml')) {
      modules.push(this.colorize(`${this.simpleEmoji('🐳')} docker`, this.config.theme?.colors?.info || '#74B9FF'))
    }

    return modules.length > 0 ? modules.join(' ') : ''
  }

  private hasFile(filename: string): boolean {
    try {
      return existsSync(join(process.cwd(), filename))
    }
    catch {
      return false
    }
  }

  private readPackageJson(): any {
    try {
      const packageJsonPath = join(process.cwd(), 'package.json')
      if (existsSync(packageJsonPath)) {
        // eslint-disable-next-line ts/no-require-imports
        const { readFileSync } = require('node:fs')
        return JSON.parse(readFileSync(packageJsonPath, 'utf-8'))
      }
    }
    catch {
      // Ignore errors
    }
    return null
  }

  private isBunProject(packageJson: any): boolean {
    if (!packageJson)
      return false

    // Check for Bun-specific indicators
    return !!(
      packageJson.type === 'module'
      || packageJson.scripts?.bun
      || packageJson.dependencies?.bun
      || packageJson.devDependencies?.bun
      || packageJson.peerDependencies?.bun
      || this.hasFile('bun.lockb')
      || this.hasFile('bunfig.toml')
    )
  }

  colorize(text: string, color: string): string {
    if (this.simpleMode)
      return text
    if (!color)
      return text
    const ansiColor = this.hexToAnsi(color)
    return `\x1B[${ansiColor}m${text}\x1B[0m`
  }

  boldColorize(text: string, color: string): string {
    if (this.simpleMode)
      return text
    // Emit a single combined SGR sequence: <color>;1
    if (!color)
      return `\x1B[1m${text}\x1B[0m`
    const ansiColor = this.hexToAnsi(color)
    return `\x1B[${ansiColor};1m${text}\x1B[0m`
  }

  private dim(text: string): string {
    if (this.simpleMode)
      return text
    return `\x1B[2m${text}\x1B[22m`
  }

  private simpleEmoji(symbol: string): string {
    if (!this.simpleMode)
      return symbol
    // Replace common emoji/symbols with ASCII fallbacks for logs/plain terminals
    const map: Record<string, string> = {
      '🌱': 'git:',
      '🐰': 'bun',
      '⬢': 'node',
      '📦': 'pkg',
      '🐍': 'py',
      '🐹': 'go',
      '🦀': 'rs',
      '🐳': 'docker',
      '❯': '>',
    }
    return map[symbol] || symbol
  }

  formatSegment(segment: PromptSegment): string {
    let result = segment.content

    if (segment.style) {
      const codes: string[] = []

      if (segment.style.bold)
        codes.push('1')
      if (segment.style.italic)
        codes.push('3')
      if (segment.style.underline)
        codes.push('4')

      if (segment.style.color) {
        const colorCode = this.hexToAnsi(segment.style.color)
        codes.push(colorCode)
      }

      if (segment.style.background) {
        const bgCode = this.hexToAnsi(segment.style.background, true)
        codes.push(bgCode)
      }

      if (codes.length > 0) {
        result = `\x1B[${codes.join(';')}m${result}\x1B[0m`
      }
    }

    return result
  }

  private hexToAnsi(hex: string, background = false): string {
    // Remove # if present
    hex = hex.replace('#', '')

    // Convert to RGB
    const r = Number.parseInt(hex.substring(0, 2), 16)
    const g = Number.parseInt(hex.substring(2, 4), 16)
    const b = Number.parseInt(hex.substring(4, 6), 16)

    if (this.supportsTruecolor()) {
      const prefix = background ? '48;2' : '38;2'
      return `${prefix};${r};${g};${b}`
    }

    // Fallback to xterm-256 color space
    const idx = this.rgbToXterm256(r, g, b)
    const prefix = background ? '48;5' : '38;5'
    return `${prefix};${idx}`
  }

  private supportsTruecolor(): boolean {
    const env = process.env
    if (!env)
      return false
    const colorterm = (env.COLORTERM || '').toLowerCase()
    if (colorterm.includes('truecolor') || colorterm.includes('24bit'))
      return true
    // Common terminals that support truecolor
    const termProgram = (env.TERM_PROGRAM || '').toLowerCase()
    if (termProgram.includes('iterm') || termProgram.includes('wezterm') || termProgram.includes('apple_terminal'))
      return true
    // VSCode integrated terminal supports truecolor
    if ((env.TERM_PROGRAM || '') === 'vscode')
      return true
    return false
  }

  private rgbToXterm256(r: number, g: number, b: number): number {
    // Grayscale ramp detection
    if (r === g && g === b) {
      if (r < 8)
        return 16
      if (r > 248)
        return 231
      return Math.round(((r - 8) / 247) * 24) + 232
    }

    // 6x6x6 color cube mapping (values 0..5)
    const toCube = (v: number) => {
      if (v < 48)
        return 0
      if (v < 114)
        return 1
      return Math.round((v - 35) / 40)
    }
    const rc = toCube(r)
    const gc = toCube(g)
    const bc = toCube(b)
    return 16 + (36 * rc) + (6 * gc) + bc
  }

  private renderDuration(lastDurationMs?: number): string {
    if (!lastDurationMs || lastDurationMs <= 0)
      return ''

    // Respect duration visibility thresholds if configured
    const durCfg = this.config.modules?.cmd_duration || {}
    const threshold = (durCfg.min_ms ?? durCfg.min_time) ?? 0
    if (threshold && lastDurationMs < threshold)
      return ''

    // If configured, show milliseconds for sub-second durations
    const showMs = durCfg.show_milliseconds === true
    if (showMs && lastDurationMs < 1000) {
      const numColored = this.boldColorize(`${Math.max(1, Math.round(lastDurationMs))}ms`, this.config.theme?.colors?.warning || '#FFD700')
      return `took ${numColored}`
    }

    // Default minutes/seconds formatting
    const totalSec = Math.floor(lastDurationMs / 1000)
    const minutes = Math.floor(totalSec / 60)
    const seconds = totalSec % 60
    const parts: string[] = []
    if (minutes > 0)
      parts.push(`${minutes}m`)
    parts.push(`${seconds}s`)
    const numeric = parts.join('')
    const numColored = this.boldColorize(numeric, this.config.theme?.colors?.warning || '#FFD700')
    return `took ${numColored}`
  }
}

export class SystemInfoProvider {
  private cachedInfo: SystemInfo | null = null

  async getSystemInfo(): Promise<SystemInfo> {
    if (this.cachedInfo) {
      return this.cachedInfo
    }

    const user = userInfo().username
    const host = hostname()
    const platformName = platform()
    const architecture = arch()

    const nodeVersion = process.version
    let bunVersion = 'unknown'

    try {
      const { stdout } = await execAsync('bun --version')
      bunVersion = stdout.trim()
    }
    catch {
      // Fallback if bun command fails
    }

    this.cachedInfo = {
      user,
      hostname: host,
      platform: platformName,
      arch: architecture,
      nodeVersion,
      bunVersion,
    }

    return this.cachedInfo
  }
}

export class GitInfoProvider {
  private cache = new Map<string, { info: GitInfo, timestamp: number }>()
  private readonly cacheTimeout = 5000 // 5 seconds

  async getGitInfo(cwd: string): Promise<GitInfo> {
    const cached = this.cache.get(cwd)
    if (cached && Date.now() - cached.timestamp < this.cacheTimeout) {
      return cached.info
    }

    const info = await this.fetchGitInfo(cwd)
    this.cache.set(cwd, { info, timestamp: Date.now() })
    return info
  }

  private async fetchGitInfo(cwd: string): Promise<GitInfo> {
    const defaultInfo: GitInfo = {
      isRepo: false,
      isDirty: false,
    }

    // Check if we're in a git repository
    if (!this.isGitRepo(cwd)) {
      return defaultInfo
    }

    try {
      const [branch, status, ahead, behind] = await Promise.all([
        this.getBranch(cwd),
        this.getStatus(cwd),
        this.getAheadCount(cwd),
        this.getBehindCount(cwd),
      ])

      return {
        isRepo: true,
        branch,
        ahead,
        behind,
        staged: status.staged,
        unstaged: status.unstaged,
        untracked: status.untracked,
        stashed: await this.getStashCount(cwd),
        isDirty: status.staged > 0 || status.unstaged > 0 || status.untracked > 0,
      }
    }
    catch {
      return { ...defaultInfo, isRepo: true }
    }
  }

  private isGitRepo(cwd: string): boolean {
    let currentDir = cwd
    while (currentDir !== '/') {
      if (existsSync(join(currentDir, '.git'))) {
        return true
      }
      const parent = join(currentDir, '..')
      if (parent === currentDir)
        break
      currentDir = parent
    }
    return false
  }

  private async getBranch(cwd: string): Promise<string | undefined> {
    try {
      const { stdout } = await execAsync('git rev-parse --abbrev-ref HEAD', { cwd })
      return stdout.trim()
    }
    catch {
      return undefined
    }
  }

  private async getStatus(cwd: string): Promise<{ staged: number, unstaged: number, untracked: number }> {
    try {
      const { stdout } = await execAsync('git status --porcelain', { cwd })
      const lines = stdout.trim().split('\n').filter(line => line.length > 0)

      let staged = 0
      let unstaged = 0
      let untracked = 0

      for (const line of lines) {
        const status = line.substr(0, 2)
        if (status[0] !== ' ' && status[0] !== '?')
          staged++
        if (status[1] !== ' ')
          unstaged++
        if (status === '??')
          untracked++
      }

      return { staged, unstaged, untracked }
    }
    catch {
      return { staged: 0, unstaged: 0, untracked: 0 }
    }
  }

  private async getAheadCount(cwd: string): Promise<number> {
    try {
      const { stdout } = await execAsync('git rev-list --count @{u}..HEAD', { cwd })
      return Number.parseInt(stdout.trim(), 10) || 0
    }
    catch {
      return 0
    }
  }

  private async getBehindCount(cwd: string): Promise<number> {
    try {
      const { stdout } = await execAsync('git rev-list --count HEAD..@{u}', { cwd })
      return Number.parseInt(stdout.trim(), 10) || 0
    }
    catch {
      return 0
    }
  }

  private async getStashCount(cwd: string): Promise<number> {
    try {
      const { stdout } = await execAsync('git stash list', { cwd })
      return stdout.trim().split('\n').filter(line => line.length > 0).length
    }
    catch {
      return 0
    }
  }
}
