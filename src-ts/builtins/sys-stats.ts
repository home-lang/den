import type { BuiltinCommand, CommandResult } from './types'

export const sysStats: BuiltinCommand = {
  name: 'sys-stats',
  description: 'Display system resource usage and statistics',
  usage: 'sys-stats [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: sys-stats [options]

Display system resource usage and statistics.

Options:
  -c, --cpu            Show CPU information
  -m, --memory         Show memory usage
  -d, --disk           Show disk usage
  -n, --network        Show network statistics
  -s, --system         Show system information
  -a, --all            Show all statistics (default)
  -j, --json           Output in JSON format
  -w, --watch SECONDS  Watch mode (refresh every N seconds)
  --no-color          Disable colored output

Examples:
  sys-stats                    Show all system stats
  sys-stats -c -m             Show CPU and memory only
  sys-stats -j                Output as JSON
  sys-stats -w 2              Watch mode, refresh every 2 seconds
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    try {
      const result = await getSystemStats(args)
      return {
        exitCode: 0,
        stdout: result.output,
        stderr: '',
        duration: performance.now() - start,
      }
    } catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `sys-stats: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface StatsOptions {
  showCpu: boolean
  showMemory: boolean
  showDisk: boolean
  showNetwork: boolean
  showSystem: boolean
  jsonOutput: boolean
  watchSeconds?: number
  noColor: boolean
}

async function getSystemStats(args: string[]): Promise<{ output: string }> {
  const options: StatsOptions = {
    showCpu: false,
    showMemory: false,
    showDisk: false,
    showNetwork: false,
    showSystem: false,
    jsonOutput: false,
    noColor: false,
  }

  // Parse arguments
  let i = 0
  while (i < args.length) {
    const arg = args[i]

    switch (arg) {
      case '-c':
      case '--cpu':
        options.showCpu = true
        break
      case '-m':
      case '--memory':
        options.showMemory = true
        break
      case '-d':
      case '--disk':
        options.showDisk = true
        break
      case '-n':
      case '--network':
        options.showNetwork = true
        break
      case '-s':
      case '--system':
        options.showSystem = true
        break
      case '-a':
      case '--all':
        options.showCpu = options.showMemory = options.showDisk = options.showNetwork = options.showSystem = true
        break
      case '-j':
      case '--json':
        options.jsonOutput = true
        break
      case '-w':
      case '--watch':
        options.watchSeconds = parseInt(args[++i]) || 1
        break
      case '--no-color':
        options.noColor = true
        break
      default:
        throw new Error(`Unknown option: ${arg}`)
    }
    i++
  }

  // If no specific sections requested, show all
  if (!options.showCpu && !options.showMemory && !options.showDisk && !options.showNetwork && !options.showSystem) {
    options.showCpu = options.showMemory = options.showDisk = options.showNetwork = options.showSystem = true
  }

  const stats = await collectSystemStats(options)

  if (options.jsonOutput) {
    return { output: JSON.stringify(stats, null, 2) }
  }

  return { output: formatStats(stats, options) }
}

async function collectSystemStats(options: StatsOptions): Promise<any> {
  const stats: any = {}

  if (options.showSystem) {
    stats.system = await getSystemInfo()
  }

  if (options.showCpu) {
    stats.cpu = await getCpuStats()
  }

  if (options.showMemory) {
    stats.memory = await getMemoryStats()
  }

  if (options.showDisk) {
    stats.disk = await getDiskStats()
  }

  if (options.showNetwork) {
    stats.network = await getNetworkStats()
  }

  stats.timestamp = new Date().toISOString()

  return stats
}

async function getSystemInfo(): Promise<any> {
  // In Bun environment, we have access to some system information
  const info: any = {
    platform: process.platform,
    arch: process.arch,
    nodeVersion: process.version,
    uptime: process.uptime(),
  }

  // Try to get additional info if available
  try {
    if (process.env.USER) info.user = process.env.USER
    if (process.env.HOME) info.home = process.env.HOME
    if (process.env.SHELL) info.shell = process.env.SHELL
    if (process.env.TERM) info.terminal = process.env.TERM
  } catch {
    // Ignore errors getting environment info
  }

  return info
}

async function getCpuStats(): Promise<any> {
  // Get basic CPU info from process
  const cpuUsage = process.cpuUsage()

  return {
    userTime: cpuUsage.user,
    systemTime: cpuUsage.system,
    totalTime: cpuUsage.user + cpuUsage.system,
    // Note: In browser/Bun environment, detailed CPU stats are limited
    cores: 'N/A (limited access)',
    model: 'N/A (limited access)',
    speed: 'N/A (limited access)',
  }
}

async function getMemoryStats(): Promise<any> {
  const memUsage = process.memoryUsage()

  return {
    rss: memUsage.rss,
    heapTotal: memUsage.heapTotal,
    heapUsed: memUsage.heapUsed,
    external: memUsage.external,
    arrayBuffers: memUsage.arrayBuffers,
    rssFormatted: formatBytes(memUsage.rss),
    heapTotalFormatted: formatBytes(memUsage.heapTotal),
    heapUsedFormatted: formatBytes(memUsage.heapUsed),
    heapUsagePercent: ((memUsage.heapUsed / memUsage.heapTotal) * 100).toFixed(1),
  }
}

async function getDiskStats(): Promise<any> {
  // Limited disk info available in this environment
  try {
    const cwd = process.cwd()
    return {
      currentDirectory: cwd,
      note: 'Limited disk information available in this environment',
    }
  } catch {
    return {
      note: 'Disk information not available',
    }
  }
}

async function getNetworkStats(): Promise<any> {
  // Network stats are very limited in this environment
  return {
    note: 'Limited network statistics available in this environment',
    // Could potentially test connectivity to common services
    // but this would require actual network calls
  }
}

function formatBytes(bytes: number): string {
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB']
  if (bytes === 0) return '0 B'
  const i = Math.floor(Math.log(bytes) / Math.log(1024))
  return Math.round(bytes / Math.pow(1024, i) * 100) / 100 + ' ' + sizes[i]
}

function formatUptime(seconds: number): string {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  const secs = Math.floor(seconds % 60)

  const parts = []
  if (days > 0) parts.push(`${days}d`)
  if (hours > 0) parts.push(`${hours}h`)
  if (minutes > 0) parts.push(`${minutes}m`)
  if (secs > 0 || parts.length === 0) parts.push(`${secs}s`)

  return parts.join(' ')
}

function formatStats(stats: any, options: StatsOptions): string {
  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('System Statistics', '1;36'))
  lines.push(color('='.repeat(50), '36'))
  lines.push('')

  if (stats.system) {
    lines.push(color('📊 System Information', '1;33'))
    lines.push(`Platform: ${stats.system.platform}`)
    lines.push(`Architecture: ${stats.system.arch}`)
    lines.push(`Runtime: ${stats.system.nodeVersion}`)
    lines.push(`Uptime: ${formatUptime(stats.system.uptime)}`)
    if (stats.system.user) lines.push(`User: ${stats.system.user}`)
    if (stats.system.shell) lines.push(`Shell: ${stats.system.shell}`)
    lines.push('')
  }

  if (stats.cpu) {
    lines.push(color('🖥️  CPU Usage', '1;33'))
    lines.push(`User Time: ${stats.cpu.userTime} μs`)
    lines.push(`System Time: ${stats.cpu.systemTime} μs`)
    lines.push(`Total Time: ${stats.cpu.totalTime} μs`)
    lines.push('')
  }

  if (stats.memory) {
    lines.push(color('💾 Memory Usage', '1;33'))
    lines.push(`RSS (Resident Set Size): ${stats.memory.rssFormatted}`)
    lines.push(`Heap Total: ${stats.memory.heapTotalFormatted}`)
    lines.push(`Heap Used: ${stats.memory.heapUsedFormatted} (${stats.memory.heapUsagePercent}%)`)
    lines.push(`External: ${formatBytes(stats.memory.external)}`)
    lines.push(`Array Buffers: ${formatBytes(stats.memory.arrayBuffers)}`)
    lines.push('')
  }

  if (stats.disk) {
    lines.push(color('💿 Disk Information', '1;33'))
    lines.push(`Current Directory: ${stats.disk.currentDirectory || 'N/A'}`)
    if (stats.disk.note) lines.push(`Note: ${stats.disk.note}`)
    lines.push('')
  }

  if (stats.network) {
    lines.push(color('🌐 Network Information', '1;33'))
    if (stats.network.note) lines.push(`Note: ${stats.network.note}`)
    lines.push('')
  }

  lines.push(color(`Last updated: ${new Date(stats.timestamp).toLocaleString()}`, '90'))

  return lines.join('\n')
}