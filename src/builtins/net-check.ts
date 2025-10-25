import type { BuiltinCommand, CommandResult } from './types'

export const netCheck: BuiltinCommand = {
  name: 'net-check',
  description: 'Network connectivity and port checking tools',
  usage: 'net-check [command] [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: net-check [command] [options]

Network connectivity and port checking tools.

Commands:
  ping HOST                     Check if host is reachable
  port HOST PORT               Check if port is open on host
  dns HOST                     Resolve DNS for host
  trace HOST                   Simple traceroute to host
  speed                        Test internet speed (download)
  interfaces                   Show network interfaces

Options:
  -t, --timeout SECONDS        Connection timeout (default: 5)
  -c, --count NUMBER          Number of ping attempts (default: 4)
  -p, --protocol PROTOCOL     Protocol: tcp, udp (default: tcp)
  -v, --verbose               Verbose output

Examples:
  net-check ping google.com
  net-check port github.com 443
  net-check dns example.com
  net-check port localhost 3000 -t 10
  net-check speed
  net-check interfaces
`
      return {
        exitCode: 0,
        stdout: helpText,
        stderr: '',
        duration: performance.now() - start,
      }
    }

    if (args.length === 0) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: 'net-check: missing command\nUsage: net-check [command] [options]\n',
        duration: performance.now() - start,
      }
    }

    try {
      const result = await executeNetworkCommand(args)
      return {
        exitCode: 0,
        stdout: result.output,
        stderr: result.verbose || '',
        duration: performance.now() - start,
      }
    } catch (error) {
      return {
        exitCode: 1,
        stdout: '',
        stderr: `net-check: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface NetworkOptions {
  timeout: number
  count: number
  protocol: 'tcp' | 'udp'
  verbose: boolean
}

async function executeNetworkCommand(args: string[]): Promise<{ output: string; verbose?: string }> {
  const options: NetworkOptions = {
    timeout: 5000,
    count: 4,
    protocol: 'tcp',
    verbose: false,
  }

  const command = args[0]
  let commandArgs = args.slice(1)

  // Parse options
  const parsedArgs: string[] = []
  let i = 0
  while (i < commandArgs.length) {
    const arg = commandArgs[i]

    if (arg === '-t' || arg === '--timeout') {
      const timeout = parseInt(commandArgs[++i])
      if (!isNaN(timeout)) options.timeout = timeout * 1000
      i++
    } else if (arg === '-c' || arg === '--count') {
      const count = parseInt(commandArgs[++i])
      if (!isNaN(count)) options.count = count
      i++
    } else if (arg === '-p' || arg === '--protocol') {
      const protocol = commandArgs[++i]
      if (protocol === 'tcp' || protocol === 'udp') options.protocol = protocol
      i++
    } else if (arg === '-v' || arg === '--verbose') {
      options.verbose = true
      i++
    } else {
      parsedArgs.push(arg)
      i++
    }
  }

  commandArgs = parsedArgs

  switch (command) {
    case 'ping':
      return await pingHost(commandArgs[0], options)
    case 'port':
      return await checkPort(commandArgs[0], parseInt(commandArgs[1]), options)
    case 'dns':
      return await resolveDns(commandArgs[0], options)
    case 'trace':
      return await traceRoute(commandArgs[0], options)
    case 'speed':
      return await testSpeed(options)
    case 'interfaces':
      return await showInterfaces(options)
    default:
      throw new Error(`Unknown command: ${command}`)
  }
}

async function pingHost(host: string, options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  if (!host) throw new Error('Host is required for ping')

  const results: string[] = []
  const verbose: string[] = []
  let successful = 0

  if (options.verbose) {
    verbose.push(`PING ${host} (timeout=${options.timeout}ms, count=${options.count})`)
  }

  results.push(`PING ${host}:`)

  for (let i = 0; i < options.count; i++) {
    const start = performance.now()
    try {
      // Use a simple HTTP HEAD request as a connectivity test
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), options.timeout)

      const url = host.startsWith('http') ? host : `https://${host}`
      await fetch(url, {
        method: 'HEAD',
        signal: controller.signal,
      })

      clearTimeout(timeoutId)
      const duration = performance.now() - start
      results.push(`${i + 1}: Reply from ${host}: time=${duration.toFixed(1)}ms`)
      successful++
    } catch (error) {
      const duration = performance.now() - start
      if (error.name === 'AbortError') {
        results.push(`${i + 1}: Request timeout (${duration.toFixed(1)}ms)`)
      } else {
        results.push(`${i + 1}: Host unreachable (${duration.toFixed(1)}ms)`)
      }
    }
  }

  const lossRate = ((options.count - successful) / options.count) * 100
  results.push(``)
  results.push(`Ping statistics for ${host}:`)
  results.push(`    Packets: Sent = ${options.count}, Received = ${successful}, Lost = ${options.count - successful} (${lossRate.toFixed(0)}% loss)`)

  return {
    output: results.join('\n'),
    verbose: verbose.length > 0 ? verbose.join('\n') : undefined,
  }
}

async function checkPort(host: string, port: number, options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  if (!host) throw new Error('Host is required')
  if (!port || isNaN(port)) throw new Error('Valid port number is required')

  const verbose: string[] = []
  if (options.verbose) {
    verbose.push(`Checking ${host}:${port} (${options.protocol.toUpperCase()}, timeout=${options.timeout}ms)`)
  }

  const start = performance.now()

  try {
    if (options.protocol === 'tcp') {
      // For TCP, we can use a simple fetch or WebSocket connection attempt
      const url = `http://${host}:${port}`
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), options.timeout)

      try {
        await fetch(url, {
          method: 'HEAD',
          signal: controller.signal,
        })
        clearTimeout(timeoutId)
      } catch (fetchError) {
        clearTimeout(timeoutId)
        // Even if the HTTP request fails, if we get a connection error vs timeout,
        // it might mean the port is open but not HTTP
        if (fetchError.name === 'AbortError') {
          throw new Error('Connection timeout')
        }
        // For other errors, try to determine if port is open based on error type
        if (fetchError.message.includes('ECONNREFUSED')) {
          throw new Error('Connection refused')
        }
      }

      const duration = performance.now() - start
      return {
        output: `Port ${port} on ${host} is OPEN (${duration.toFixed(1)}ms)`,
        verbose: verbose.length > 0 ? verbose.join('\n') : undefined,
      }
    } else {
      // UDP port checking is more complex and not easily doable with web APIs
      throw new Error('UDP port checking not supported in this environment')
    }
  } catch (error) {
    const duration = performance.now() - start
    return {
      output: `Port ${port} on ${host} is CLOSED or filtered (${duration.toFixed(1)}ms) - ${error.message}`,
      verbose: verbose.length > 0 ? verbose.join('\n') : undefined,
    }
  }
}

async function resolveDns(host: string, options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  if (!host) throw new Error('Host is required for DNS resolution')

  const verbose: string[] = []
  if (options.verbose) {
    verbose.push(`Resolving DNS for ${host}`)
  }

  const results: string[] = []
  results.push(`DNS resolution for ${host}:`)

  try {
    // Try to resolve by making a request and examining the resolved address
    // This is limited in browser/Bun environment, but we can try
    const url = host.startsWith('http') ? host : `https://${host}`
    const start = performance.now()

    const response = await fetch(url, {
      method: 'HEAD',
      signal: AbortSignal.timeout(options.timeout),
    })

    const duration = performance.now() - start
    results.push(`  Successfully resolved ${host} (${duration.toFixed(1)}ms)`)
    results.push(`  Status: ${response.status} ${response.statusText}`)

    // Try to extract some header information
    const server = response.headers.get('server')
    if (server) {
      results.push(`  Server: ${server}`)
    }

  } catch (error) {
    if (error.name === 'TimeoutError') {
      results.push(`  DNS resolution timeout after ${options.timeout}ms`)
    } else {
      results.push(`  DNS resolution failed: ${error.message}`)
    }
  }

  return {
    output: results.join('\n'),
    verbose: verbose.length > 0 ? verbose.join('\n') : undefined,
  }
}

async function traceRoute(host: string, options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  if (!host) throw new Error('Host is required for traceroute')

  // Simple traceroute simulation - in a real environment this would require system calls
  const results: string[] = []
  results.push(`Traceroute to ${host}:`)
  results.push(`Note: This is a simplified traceroute using application-level probes`)
  results.push(``)

  try {
    const url = host.startsWith('http') ? host : `https://${host}`
    const start = performance.now()

    const response = await fetch(url, {
      method: 'HEAD',
      signal: AbortSignal.timeout(options.timeout),
    })

    const duration = performance.now() - start
    results.push(`1. ${host} (${duration.toFixed(1)}ms) - ${response.status}`)

  } catch (error) {
    results.push(`1. ${host} - Request failed: ${error.message}`)
  }

  results.push(``)
  results.push(`Trace complete. (Limited functionality in this environment)`)

  return {
    output: results.join('\n'),
  }
}

async function testSpeed(options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  const results: string[] = []
  const verbose: string[] = []

  results.push(`Internet speed test:`)
  results.push(``)

  if (options.verbose) {
    verbose.push(`Starting speed test...`)
  }

  try {
    // Test download speed by downloading a known file
    const testUrl = 'https://httpbin.org/bytes/1048576' // 1MB test file
    const start = performance.now()

    const response = await fetch(testUrl, {
      signal: AbortSignal.timeout(options.timeout),
    })

    const buffer = await response.arrayBuffer()
    const duration = (performance.now() - start) / 1000 // Convert to seconds
    const bytes = buffer.byteLength
    const mbps = (bytes * 8) / (1024 * 1024) / duration // Convert to Mbps

    results.push(`Download test:`)
    results.push(`  Size: ${(bytes / 1024 / 1024).toFixed(2)} MB`)
    results.push(`  Time: ${duration.toFixed(2)} seconds`)
    results.push(`  Speed: ${mbps.toFixed(2)} Mbps`)

  } catch (error) {
    results.push(`Speed test failed: ${error.message}`)
  }

  return {
    output: results.join('\n'),
    verbose: verbose.length > 0 ? verbose.join('\n') : undefined,
  }
}

async function showInterfaces(options: NetworkOptions): Promise<{ output: string; verbose?: string }> {
  const results: string[] = []
  results.push(`Network interfaces:`)
  results.push(``)

  // In a browser/Bun environment, we have limited access to network interface information
  // We can try to get some basic connectivity information

  try {
    // Test connectivity to a few well-known services
    const tests = [
      { name: 'Google DNS', host: '8.8.8.8', port: 53 },
      { name: 'Cloudflare DNS', host: '1.1.1.1', port: 53 },
      { name: 'Google', host: 'google.com', port: 443 },
    ]

    for (const test of tests) {
      try {
        const url = `https://${test.host}`
        const start = performance.now()
        await fetch(url, {
          method: 'HEAD',
          signal: AbortSignal.timeout(options.timeout),
        })
        const duration = performance.now() - start
        results.push(`✓ ${test.name} (${test.host}): Connected (${duration.toFixed(1)}ms)`)
      } catch {
        results.push(`✗ ${test.name} (${test.host}): Not reachable`)
      }
    }

    results.push(``)
    results.push(`Note: Limited interface information available in this environment`)

  } catch (error) {
    results.push(`Failed to check network connectivity: ${error.message}`)
  }

  return {
    output: results.join('\n'),
  }
}