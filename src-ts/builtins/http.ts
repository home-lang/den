import type { BuiltinCommand, CommandResult } from './types'

export const http: BuiltinCommand = {
  name: 'http',
  description: 'Simple HTTP client for making web requests',
  usage: 'http [METHOD] URL [options]',
  async execute(args, _shell): Promise<CommandResult> {
    const start = performance.now()

    if (args.includes('--help') || args.includes('-h')) {
      const helpText = `Usage: http [METHOD] URL [options]

Simple HTTP client for making web requests (like curl but simpler).

Methods:
  GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS

Options:
  -H, --header KEY:VALUE    Add HTTP header
  -d, --data DATA          Request body data
  -j, --json DATA          Send JSON data (sets Content-Type)
  -f, --form DATA          Send form data
  -o, --output FILE        Save response to file
  -i, --include            Include response headers
  -v, --verbose            Verbose output
  -t, --timeout SECONDS    Request timeout (default: 30)
  --follow                 Follow redirects

Examples:
  http GET https://api.github.com/users/octocat
  http POST https://httpbin.org/post -j '{"name":"test"}'
  http GET https://example.com -H "Authorization:Bearer token"
  http POST https://httpbin.org/post -d "key=value"
  http GET https://example.com -o response.html
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
        stderr: 'http: missing URL\nUsage: http [METHOD] URL [options]\n',
        duration: performance.now() - start,
      }
    }

    try {
      const result = await makeHttpRequest(args)
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
        stderr: `http: ${error.message}\n`,
        duration: performance.now() - start,
      }
    }
  },
}

interface HttpRequestOptions {
  method: string
  url: string
  headers: Record<string, string>
  body?: string
  timeout: number
  includeHeaders: boolean
  verbose: boolean
  outputFile?: string
  followRedirects: boolean
}

async function makeHttpRequest(args: string[]): Promise<{ output: string; verbose?: string }> {
  const options: HttpRequestOptions = {
    method: 'GET',
    url: '',
    headers: {},
    timeout: 30000,
    includeHeaders: false,
    verbose: false,
    followRedirects: false,
  }

  // Parse arguments
  let i = 0
  while (i < args.length) {
    const arg = args[i]

    if (arg.match(/^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)$/i)) {
      options.method = arg.toUpperCase()
      i++
    } else if (arg.startsWith('http://') || arg.startsWith('https://')) {
      options.url = arg
      i++
    } else if (arg === '-H' || arg === '--header') {
      const header = args[++i]
      if (!header) throw new Error('Header value required')
      const [key, ...valueParts] = header.split(':')
      if (!key || valueParts.length === 0) throw new Error('Invalid header format (use KEY:VALUE)')
      options.headers[key.trim()] = valueParts.join(':').trim()
      i++
    } else if (arg === '-d' || arg === '--data') {
      options.body = args[++i]
      if (!options.body) throw new Error('Data value required')
      i++
    } else if (arg === '-j' || arg === '--json') {
      options.body = args[++i]
      if (!options.body) throw new Error('JSON data required')
      options.headers['Content-Type'] = 'application/json'
      i++
    } else if (arg === '-f' || arg === '--form') {
      options.body = args[++i]
      if (!options.body) throw new Error('Form data required')
      options.headers['Content-Type'] = 'application/x-www-form-urlencoded'
      i++
    } else if (arg === '-o' || arg === '--output') {
      options.outputFile = args[++i]
      if (!options.outputFile) throw new Error('Output file required')
      i++
    } else if (arg === '-i' || arg === '--include') {
      options.includeHeaders = true
      i++
    } else if (arg === '-v' || arg === '--verbose') {
      options.verbose = true
      i++
    } else if (arg === '-t' || arg === '--timeout') {
      const timeout = parseInt(args[++i])
      if (isNaN(timeout)) throw new Error('Invalid timeout value')
      options.timeout = timeout * 1000
      i++
    } else if (arg === '--follow') {
      options.followRedirects = true
      i++
    } else if (!options.url) {
      options.url = arg
      i++
    } else {
      throw new Error(`Unknown option: ${arg}`)
    }
  }

  if (!options.url) {
    throw new Error('URL is required')
  }

  // Validate URL
  try {
    new URL(options.url)
  } catch {
    throw new Error('Invalid URL')
  }

  const verboseOutput: string[] = []
  if (options.verbose) {
    verboseOutput.push(`> ${options.method} ${options.url}`)
    for (const [key, value] of Object.entries(options.headers)) {
      verboseOutput.push(`> ${key}: ${value}`)
    }
    if (options.body) {
      verboseOutput.push(`> `)
      verboseOutput.push(`> ${options.body}`)
    }
    verboseOutput.push(``)
  }

  // Make the request
  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), options.timeout)

  try {
    const response = await fetch(options.url, {
      method: options.method,
      headers: options.headers,
      body: options.body,
      signal: controller.signal,
      redirect: options.followRedirects ? 'follow' : 'manual',
    })

    clearTimeout(timeoutId)

    if (options.verbose) {
      verboseOutput.push(`< HTTP/${response.status} ${response.statusText}`)
      response.headers.forEach((value, key) => {
        verboseOutput.push(`< ${key}: ${value}`)
      })
      verboseOutput.push(``)
    }

    let output = ''

    // Include headers if requested
    if (options.includeHeaders) {
      output += `HTTP/${response.status} ${response.statusText}\n`
      response.headers.forEach((value, key) => {
        output += `${key}: ${value}\n`
      })
      output += '\n'
    }

    // Get response body
    const responseText = await response.text()
    output += responseText

    // Save to file if requested
    if (options.outputFile) {
      await Bun.write(options.outputFile, responseText)
      return {
        output: `Response saved to ${options.outputFile}\n`,
        verbose: verboseOutput.length > 0 ? verboseOutput.join('\n') : undefined,
      }
    }

    // Check for errors
    if (!response.ok && !options.verbose) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }

    return {
      output,
      verbose: verboseOutput.length > 0 ? verboseOutput.join('\n') : undefined,
    }
  } catch (error) {
    clearTimeout(timeoutId)
    if (error.name === 'AbortError') {
      throw new Error(`Request timeout after ${options.timeout / 1000}s`)
    }
    throw error
  }
}