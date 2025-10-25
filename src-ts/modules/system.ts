import type { ModuleContext, ModuleResult } from '../types'
import { existsSync } from 'node:fs'
import { homedir, hostname, platform, userInfo } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'
import { BaseModule, ModuleUtils } from './index'

// OS module
export class OsModule extends BaseModule {
  name = 'os'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const platformName = platform()
    const symbols: Record<string, string> = {
      darwin: '🍎',
      linux: '🐧',
      win32: '🪟',
      freebsd: '😈',
      openbsd: '🐡',
      netbsd: '🚩',
      aix: '➿',
      sunos: '🌞',
      android: '🤖',
    }

    const cfg = (context.config as any)?.os || {}
    const symbolOverride = cfg.symbols?.[platformName]
    const symbol = symbolOverride ?? symbols[platformName] ?? (cfg.symbol ?? '💻')
    const format = cfg.format ?? '{symbol} {name}'
    const content = format
      .replace('{symbol}', symbol)
      .replace('{name}', this.getPrettyName(platformName))

    return this.formatResult(content)
  }

  private getPrettyName(platform: string): string {
    const names: Record<string, string> = {
      darwin: 'macOS',
      linux: 'Linux',
      win32: 'Windows',
      freebsd: 'FreeBSD',
      openbsd: 'OpenBSD',
      netbsd: 'NetBSD',
      aix: 'AIX',
      sunos: 'Solaris',
      android: 'Android',
    }

    return names[platform] || platform
  }
}

// Hostname module
export class HostnameModule extends BaseModule {
  name = 'hostname'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const host = hostname()
    const isSSH = !!(context.environment.SSH_CONNECTION || context.environment.SSH_CLIENT)

    const cfg = (context.config as any)?.hostname || {}
    const showOnLocal = cfg.showOnLocal ?? !(cfg.ssh_only ?? true)
    if (!isSSH && !showOnLocal)
      return null

    const format = cfg.format ?? '@{host}'
    const content = format
      .replace('{host}', host)
      .replace('{hostname}', host)
    return this.formatResult(content)
  }
}

// Directory module
export class DirectoryModule extends BaseModule {
  name = 'directory'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    let path = context.cwd
    const home = homedir()

    // Replace home directory with ~
    if (path.startsWith(home)) {
      path = path.replace(home, '~')
    }

    // Truncate long paths
    const maxLength = 50
    if (path.length > maxLength) {
      const parts = path.split('/')
      if (parts.length > 3) {
        path = `${parts[0]}/…/${parts[parts.length - 2]}/${parts[parts.length - 1]}`
      }
    }

    const cfg = (context.config as any)?.directory || {}
    const isReadonly = this.isReadonlyDirectory(context.cwd)
    const lock = cfg.readonly_symbol ?? '🔒'
    const symbol = isReadonly ? lock : ''

    const format = cfg.format ?? '{symbol}{path}'
    const content = format
      .replace('{symbol}', symbol)
      .replace('{path}', path)

    return this.formatResult(content)
  }

  private isReadonlyDirectory(path: string): boolean {
    try {
      // Try to check if directory is writable
      const testFile = join(path, `.write-test-${Date.now()}`)
      // eslint-disable-next-line ts/no-require-imports
      require('node:fs').writeFileSync(testFile, '')
      // eslint-disable-next-line ts/no-require-imports
      require('node:fs').unlinkSync(testFile)
      return false
    }
    catch {
      return true
    }
  }
}

// Username module
export class UsernameModule extends BaseModule {
  name = 'username'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const user = userInfo().username
    const isSSH = !!(context.environment.SSH_CONNECTION || context.environment.SSH_CLIENT)
    const isRoot = process.getuid?.() === 0

    const cfg = (context.config as any)?.username || {}
    const showOnLocal = cfg.showOnLocal ?? (cfg.show_always ?? false)
    if (!isSSH && !isRoot && !showOnLocal)
      return null

    const format = (isRoot ? (cfg.root_format ?? '{user}') : (cfg.format ?? '{user}'))
    const content = format
      .replace('{user}', user)
      .replace('{username}', user)
    return this.formatResult(content)
  }
}

// Shell module
export class ShellModule extends BaseModule {
  name = 'shell'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return !!_context.environment.SHELL
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const shell = context.environment.SHELL
    if (!shell)
      return null

    const shellName = shell.split('/').pop() || shell
    const indicators: Record<string, string> = {
      bash: 'bash',
      zsh: 'zsh',
      fish: 'fish',
      powershell: 'pwsh',
      pwsh: 'pwsh',
      ion: 'ion',
      elvish: 'elvish',
      tcsh: 'tcsh',
      nu: 'nu',
      xonsh: 'xonsh',
      cmd: 'cmd',
    }

    const indicator = indicators[shellName] || shellName
    const cfg = (context.config as any)?.shell || {}
    const format = cfg.format ?? '{shell}'
    const content = format
      .replace('{shell}', indicator)
      .replace('{indicator}', indicator)

    return this.formatResult(content)
  }
}

// Battery module
export class BatteryModule extends BaseModule {
  name = 'battery'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return this.hasBattery()
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const batteryInfo = await this.getBatteryInfo()
    if (!batteryInfo)
      return null

    const { percentage, isCharging, isLow } = batteryInfo

    const cfg = (context.config as any)?.battery || {}
    const sCharging = cfg.symbol_charging ?? cfg.charging_symbol ?? '🔌'
    const sLow = cfg.symbol_low ?? cfg.empty_symbol ?? '🪫'
    const sNormal = cfg.symbol ?? cfg.discharging_symbol ?? cfg.full_symbol ?? '🔋'
    const symbol = isCharging ? sCharging : isLow ? sLow : sNormal

    const format = cfg.format ?? '{symbol} {percentage}%'
    const content = format
      .replace('{symbol}', symbol)
      .replace('{percentage}', String(percentage))

    return this.formatResult(content)
  }

  private hasBattery(): boolean {
    // Simple check - this would need platform-specific implementation
    return platform() === 'darwin' || existsSync('/sys/class/power_supply')
  }

  private async getBatteryInfo(): Promise<{ percentage: number, isCharging: boolean, isLow: boolean } | null> {
    try {
      if (platform() === 'darwin') {
        const output = await ModuleUtils.getCommandOutput('pmset -g batt')
        if (!output)
          return null

        const match = output.match(/(\d+)%.*?(charging|discharging|charged)/i)
        if (!match)
          return null

        const percentage = Number.parseInt(match[1], 10)
        const isCharging = match[2]?.toLowerCase() === 'charging'
        const isLow = percentage < 20

        return { percentage, isCharging, isLow }
      }

      // Linux implementation would go here
      return null
    }
    catch {
      return null
    }
  }
}

// Command duration module
export class CmdDurationModule extends BaseModule {
  name = 'cmd_duration'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return !!(_context.environment.CMD_DURATION_MS || _context.environment.STARSHIP_DURATION)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const durationMs = Number.parseInt(context.environment.CMD_DURATION_MS || context.environment.STARSHIP_DURATION || '0', 10)

    const cfg = (context.config as any)?.cmd_duration || {}
    const minMs = cfg.min_ms ?? cfg.min_time ?? 2000
    if (durationMs < minMs)
      return null // Only show for commands longer than threshold

    const duration = this.formatDuration(durationMs)
    const format = cfg.format ?? 'took {duration}'
    const content = format.replace('{duration}', duration)

    return this.formatResult(content)
  }

  private formatDuration(ms: number): string {
    if (ms < 1000)
      return `${ms}ms`
    if (ms < 60000)
      return `${(ms / 1000).toFixed(1)}s`
    if (ms < 3600000)
      return `${Math.floor(ms / 60000)}m ${Math.floor((ms % 60000) / 1000)}s`
    return `${Math.floor(ms / 3600000)}h ${Math.floor((ms % 3600000) / 60000)}m`
  }
}

// Memory usage module
export class MemoryUsageModule extends BaseModule {
  name = 'memory_usage'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const memInfo = this.getMemoryInfo()
    if (!memInfo)
      return null

    const { used, total, percentage } = memInfo

    const cfg = (context.config as any)?.memory_usage || {}
    const threshold = cfg.threshold ?? 75
    if (percentage < threshold)
      return null

    const symbol = cfg.symbol ?? '🐏'
    const format = cfg.format ?? '{symbol} {used}/{total} ({percentage}%)'
    const ram = `${this.formatBytes(used)}/${this.formatBytes(total)} (${percentage}%)`
    const content = format
      .replace('{symbol}', symbol)
      .replace('{used}', this.formatBytes(used))
      .replace('{total}', this.formatBytes(total))
      .replace('{percentage}', String(percentage))
      .replace('{ram}', ram)

    return this.formatResult(content)
  }

  private getMemoryInfo(): { used: number, total: number, percentage: number } | null {
    try {
      // eslint-disable-next-line ts/no-require-imports
      const { totalmem, freemem } = require('node:os')
      const total = totalmem()
      const free = freemem()
      const used = total - free
      const percentage = Math.round((used / total) * 100)

      return { used, total, percentage }
    }
    catch {
      return null
    }
  }

  private formatBytes(bytes: number): string {
    const units = ['B', 'KB', 'MB', 'GB', 'TB']
    let size = bytes
    let unitIndex = 0

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024
      unitIndex++
    }

    return `${size.toFixed(1)}${units[unitIndex]}`
  }
}

// Time module
export class TimeModule extends BaseModule {
  name = 'time'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return true // Always available
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const now = new Date()
    const cfg = (context.config as any)?.time || {}
    const locale = cfg.locale || 'en-US'
    const options = cfg.options || { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' }
    const timeString = now.toLocaleTimeString(locale, options)

    const symbol = cfg.symbol ?? '🕐'
    const format = cfg.format ?? '{symbol} {time}'
    const content = format
      .replace('{symbol}', symbol)
      .replace('{time}', timeString)
    return this.formatResult(content)
  }
}

// Nix shell module
export class NixShellModule extends BaseModule {
  name = 'nix_shell'
  enabled = true

  detect(_context: ModuleContext): boolean {
    return !!(_context.environment.IN_NIX_SHELL || _context.environment.NIX_SHELL_PACKAGES)
  }

  async render(context: ModuleContext): Promise<ModuleResult | null> {
    const inNixShell = context.environment.IN_NIX_SHELL
    const packages = context.environment.NIX_SHELL_PACKAGES

    if (!inNixShell && !packages)
      return null

    const cfg = (context.config as any)?.nix_shell || {}
    const symbol = cfg.symbol ?? '❄️'
    const format = cfg.format ?? '{symbol} {state}'
    const pureMsg = cfg.pure_msg ?? 'pure'
    const impureMsg = cfg.impure_msg ?? 'impure'
    const unknownMsg = cfg.unknown_msg ?? 'shell'
    let state = ''
    if (inNixShell === 'pure')
      state = pureMsg
    else if (inNixShell === 'impure')
      state = impureMsg
    else if (packages)
      state = unknownMsg

    const content = format
      .replace('{symbol}', symbol)
      .replace('{state}', state)

    return this.formatResult(content)
  }
}
