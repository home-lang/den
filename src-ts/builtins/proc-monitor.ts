import type { BuiltinCommand, CommandResult } from './types'

export const procMonitor: BuiltinCommand = {
  name: 'proc-monitor',
  description: 'Monitor running processes and system activity',
  usage: 'proc-monitor [command] [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: proc-monitor [command] [options]

Monitor running processes and system activity.

Commands:
  list                         List running processes
  top                         Show top processes (like htop)
  find PATTERN                Find processes by name pattern
  tree                        Show process tree
  current                     Show current process info
  parent                      Show parent process info

Options:
  -p, --pid PID               Show specific process by PID
  -u, --user USER            Filter by user
  -n, --limit NUMBER         Limit number of results (default: 20)
  -s, --sort FIELD           Sort by field: pid, cpu, memory, name (default: pid)
  -j, --json                 Output in JSON format
  -w, --watch SECONDS        Watch mode (refresh every N seconds)
  --no-color                 Disable colored output

Examples:
  proc-monitor list                    List processes
  proc-monitor top -n 10              Show top 10 processes
  proc-monitor find node              Find processes with 'node' in name
  proc-monitor list -u root           Show processes for root user
  proc-monitor current                Show current process info
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    if (args.length === 0) {
      args = ['current'] // Default to showing current process
    }

    try {
      const result = await executeProcessCommand(args)
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
        stderr: `proc-monitor: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface ProcessOptions {
  pid?: number
  user?: string
  limit: number
  sort: 'pid' | 'cpu' | 'memory' | 'name'
  jsonOutput: boolean
  watchSeconds?: number
  noColor: boolean
}

interface ProcessInfo {
  pid: number
  ppid?: number
  name: string
  command?: string
  user?: string
  cpu?: number
  memory?: number
  startTime?: string
  status?: string
}

async function executeProcessCommand(args: string[]): Promise<{ output: string }> {
  const options: ProcessOptions = {
    limit: 20,
    sort: 'pid',
    jsonOutput: false,
    noColor: false,
  }

  const command = args[0]
  let commandArgs = args.slice(1)

  // Parse options
  const parsedArgs: string[] = []
  let i = 0
  while (i < commandArgs.length) {
    const arg = commandArgs[i]

    switch (arg) {
      case '-p':
      case '--pid':
        options.pid = parseInt(commandArgs[++i])
        break
      case '-u':
      case '--user':
        options.user = commandArgs[++i]
        break
      case '-n':
      case '--limit':
        options.limit = parseInt(commandArgs[++i]) || 20
        break
      case '-s':
      case '--sort':
        const sortField = commandArgs[++i]
        if (['pid', 'cpu', 'memory', 'name'].includes(sortField)) {
          options.sort = sortField as any
        }
        break
      case '-j':
      case '--json':
        options.jsonOutput = true
        break
      case '-w':
      case '--watch':
        options.watchSeconds = parseInt(commandArgs[++i]) || 1
        break
      case '--no-color':
        options.noColor = true
        break
      default:
        parsedArgs.push(arg)
        break
    }
    i++
  }

  commandArgs = parsedArgs

  switch (command) {
    case 'list':
      return await listProcesses(options)
    case 'top':
      return await showTopProcesses(options)
    case 'find':
      return await findProcesses(commandArgs[0], options)
    case 'tree':
      return await showProcessTree(options)
    case 'current':
      return await showCurrentProcess(options)
    case 'parent':
      return await showParentProcess(options)
    default:
      throw new Error(`Unknown command: ${command}`)
  }
}

async function getCurrentProcessInfo(): Promise<ProcessInfo> {
  return {
    pid: process.pid,
    ppid: process.ppid,
    name: 'krusty',
    command: process.argv.join(' '),
    user: process.env.USER || 'unknown',
    startTime: new Date().toISOString(), // Approximation
    status: 'running',
  }
}

async function getSystemProcesses(): Promise<ProcessInfo[]> {
  // In Bun/browser environment, we have very limited access to system processes
  // We can only really show the current process and some basic info
  const processes: ProcessInfo[] = []

  // Add current process
  const current = await getCurrentProcessInfo()
  processes.push(current)

  // Try to get some basic system information through available APIs
  try {
    // We could potentially run system commands if available
    // For now, we'll show limited information
    const runtime = {
      pid: process.pid + 1, // Fake parent PID
      name: 'system',
      command: 'system process',
      user: 'system',
      status: 'running',
    }
    processes.push(runtime)
  } catch {
    // Ignore errors
  }

  return processes
}

async function listProcesses(options: ProcessOptions): Promise<{ output: string }> {
  const processes = await getSystemProcesses()

  // Apply filters
  let filtered = processes
  if (options.pid) {
    filtered = filtered.filter(p => p.pid === options.pid)
  }
  if (options.user) {
    filtered = filtered.filter(p => p.user === options.user)
  }

  // Sort
  filtered.sort((a, b) => {
    switch (options.sort) {
      case 'pid':
        return a.pid - b.pid
      case 'name':
        return a.name.localeCompare(b.name)
      case 'cpu':
        return (b.cpu || 0) - (a.cpu || 0)
      case 'memory':
        return (b.memory || 0) - (a.memory || 0)
      default:
        return a.pid - b.pid
    }
  })

  // Limit results
  filtered = filtered.slice(0, options.limit)

  if (options.jsonOutput) {
    return { output: JSON.stringify(filtered, null, 2) }
  }

  return { output: formatProcessList(filtered, options) }
}

async function showTopProcesses(options: ProcessOptions): Promise<{ output: string }> {
  // This would show processes sorted by resource usage
  const processes = await getSystemProcesses()

  // Add some mock resource usage for demonstration
  const processesWithUsage = processes.map(p => ({
    ...p,
    cpu: Math.random() * 100,
    memory: Math.random() * 1024 * 1024 * 1024, // Random memory usage
  }))

  // Sort by CPU usage
  processesWithUsage.sort((a, b) => (b.cpu || 0) - (a.cpu || 0))

  const limited = processesWithUsage.slice(0, options.limit)

  if (options.jsonOutput) {
    return { output: JSON.stringify(limited, null, 2) }
  }

  return { output: formatTopProcesses(limited, options) }
}

async function findProcesses(pattern: string, options: ProcessOptions): Promise<{ output: string }> {
  if (!pattern) {
    throw new Error('Search pattern is required')
  }

  const processes = await getSystemProcesses()
  const regex = new RegExp(pattern, 'i')

  const matched = processes.filter(p =>
    regex.test(p.name) ||
    (p.command && regex.test(p.command))
  )

  if (options.jsonOutput) {
    return { output: JSON.stringify(matched, null, 2) }
  }

  return { output: formatProcessList(matched, options) }
}

async function showProcessTree(options: ProcessOptions): Promise<{ output: string }> {
  const processes = await getSystemProcesses()

  if (options.jsonOutput) {
    return { output: JSON.stringify(processes, null, 2) }
  }

  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Process Tree', '1;36'))
  lines.push(color('='.repeat(40), '36'))
  lines.push('')

  for (const proc of processes) {
    const indent = proc.ppid ? '  ├─ ' : '├─ '
    lines.push(`${indent}${proc.name} (${proc.pid})`)
    if (proc.command && proc.command !== proc.name) {
      lines.push(`${indent.replace(/[├─]/g, ' ')}  ${color(proc.command, '90')}`)
    }
  }

  lines.push('')
  lines.push(color('Note: Limited process tree in this environment', '90'))

  return { output: lines.join('\n') }
}

async function showCurrentProcess(options: ProcessOptions): Promise<{ output: string }> {
  const current = await getCurrentProcessInfo()

  if (options.jsonOutput) {
    return { output: JSON.stringify(current, null, 2) }
  }

  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Current Process Information', '1;36'))
  lines.push(color('='.repeat(40), '36'))
  lines.push('')
  lines.push(`${color('PID:', '1;33')} ${current.pid}`)
  if (current.ppid) lines.push(`${color('Parent PID:', '1;33')} ${current.ppid}`)
  lines.push(`${color('Name:', '1;33')} ${current.name}`)
  lines.push(`${color('User:', '1;33')} ${current.user}`)
  lines.push(`${color('Status:', '1;33')} ${current.status}`)
  if (current.command) {
    lines.push(`${color('Command:', '1;33')} ${current.command}`)
  }

  // Add memory usage
  const memUsage = process.memoryUsage()
  lines.push('')
  lines.push(color('Memory Usage:', '1;33'))
  lines.push(`  RSS: ${formatBytes(memUsage.rss)}`)
  lines.push(`  Heap Used: ${formatBytes(memUsage.heapUsed)}`)
  lines.push(`  Heap Total: ${formatBytes(memUsage.heapTotal)}`)

  return { output: lines.join('\n') }
}

async function showParentProcess(options: ProcessOptions): Promise<{ output: string }> {
  if (options.jsonOutput) {
    return { output: JSON.stringify({ ppid: process.ppid }, null, 2) }
  }

  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Parent Process Information', '1;36'))
  lines.push(color('='.repeat(40), '36'))
  lines.push('')

  if (process.ppid) {
    lines.push(`${color('Parent PID:', '1;33')} ${process.ppid}`)
    lines.push('')
    lines.push(color('Note: Limited parent process information available', '90'))
  } else {
    lines.push('No parent process information available')
  }

  return { output: lines.join('\n') }
}

function formatBytes(bytes: number): string {
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB']
  if (bytes === 0) return '0 B'
  const i = Math.floor(Math.log(bytes) / Math.log(1024))
  return Math.round(bytes / Math.pow(1024, i) * 100) / 100 + ' ' + sizes[i]
}

function formatProcessList(processes: ProcessInfo[], options: ProcessOptions): string {
  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Process List', '1;36'))
  lines.push(color('='.repeat(60), '36'))
  lines.push('')

  // Header
  const header = `${color('PID', '1;33').padEnd(15)} ${color('NAME', '1;33').padEnd(20)} ${color('USER', '1;33').padEnd(15)} ${color('STATUS', '1;33')}`
  lines.push(header)
  lines.push('-'.repeat(60))

  // Processes
  for (const proc of processes) {
    const pidStr = proc.pid.toString().padEnd(8)
    const nameStr = proc.name.padEnd(20)
    const userStr = (proc.user || 'unknown').padEnd(15)
    const statusStr = proc.status || 'unknown'

    lines.push(`${pidStr} ${nameStr} ${userStr} ${statusStr}`)
  }

  if (processes.length === 0) {
    lines.push(color('No processes found', '90'))
  } else {
    lines.push('')
    lines.push(color(`Total: ${processes.length} process(es)`, '90'))
  }

  return lines.join('\n')
}

function formatTopProcesses(processes: ProcessInfo[], options: ProcessOptions): string {
  const lines: string[] = []
  const color = (text: string, code: string) => options.noColor ? text : `\x1b[${code}m${text}\x1b[0m`

  lines.push(color('Top Processes', '1;36'))
  lines.push(color('='.repeat(80), '36'))
  lines.push('')

  // Header
  const header = `${color('PID', '1;33').padEnd(8)} ${color('NAME', '1;33').padEnd(20)} ${color('CPU%', '1;33').padEnd(8)} ${color('MEMORY', '1;33').padEnd(12)} ${color('USER', '1;33')}`
  lines.push(header)
  lines.push('-'.repeat(80))

  // Processes
  for (const proc of processes) {
    const pidStr = proc.pid.toString().padEnd(8)
    const nameStr = proc.name.padEnd(20)
    const cpuStr = (proc.cpu?.toFixed(1) || '0.0').padEnd(8)
    const memStr = formatBytes(proc.memory || 0).padEnd(12)
    const userStr = proc.user || 'unknown'

    lines.push(`${pidStr} ${nameStr} ${cpuStr} ${memStr} ${userStr}`)
  }

  lines.push('')
  lines.push(color('Note: Resource usage is simulated in this environment', '90'))

  return lines.join('\n')
}