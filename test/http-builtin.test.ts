import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { mkdtemp, rmdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('HTTP Builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig
  let tempDir: string
  let originalFetch: typeof globalThis.fetch

  beforeEach(async () => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
    }
    shell = new KrustyShell(testConfig)
    tempDir = await mkdtemp(join(tmpdir(), 'krusty-http-test-'))

    // Mock fetch for testing
    originalFetch = globalThis.fetch
    globalThis.fetch = mock(async (url: string, options?: any) => {
      const mockUrl = url.toString()

      if (mockUrl.includes('httpbin.org/get')) {
        return new Response(JSON.stringify({
          url: mockUrl,
          args: {},
          headers: options?.headers || {},
          origin: '127.0.0.1'
        }), {
          status: 200,
          statusText: 'OK',
          headers: new Headers({
            'content-type': 'application/json',
            'server': 'httpbin/1.0'
          })
        })
      }

      if (mockUrl.includes('httpbin.org/post')) {
        return new Response(JSON.stringify({
          url: mockUrl,
          data: options?.body || '',
          headers: options?.headers || {},
          json: options?.body ? JSON.parse(options.body) : null
        }), {
          status: 200,
          statusText: 'OK',
          headers: new Headers({
            'content-type': 'application/json'
          })
        })
      }

      if (mockUrl.includes('httpbin.org/status/404')) {
        return new Response('Not Found', {
          status: 404,
          statusText: 'Not Found'
        })
      }

      if (mockUrl.includes('timeout-test.com')) {
        return new Promise((_, reject) => {
          setTimeout(() => reject(new Error('AbortError')), 100)
        })
      }

      // Default success response
      return new Response('OK', {
        status: 200,
        statusText: 'OK',
        headers: new Headers({
          'content-type': 'text/plain'
        })
      })
    }) as any
  })

  afterEach(async () => {
    // Restore original fetch
    globalThis.fetch = originalFetch
    shell.stop()
    try {
      await rmdir(tempDir, { recursive: true })
    } catch {
      // Ignore cleanup errors
    }
  })

  describe('help and basic functionality', () => {
    it('should show help message', async () => {
      const result = await shell.execute('http --help')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: http [METHOD] URL [options]')
      expect(result.stdout).toContain('Simple HTTP client')
      expect(result.stdout).toContain('GET, POST, PUT, DELETE')
    })

    it('should show error for missing URL', async () => {
      const result = await shell.execute('http')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('missing URL')
    })
  })

  describe('GET requests', () => {
    it('should make a simple GET request', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('httpbin.org/get')
    })

    it('should make GET request without explicit method', async () => {
      const result = await shell.execute('http https://httpbin.org/get')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('httpbin.org/get')
    })

    it('should add custom headers', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -H "Authorization:Bearer token123"')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('token123')
    })

    it('should include response headers with -i flag', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -i')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('HTTP/200 OK')
      expect(result.stdout).toContain('content-type:')
    })

    it('should handle verbose output', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -v')
      expect(result.exitCode).toBe(0)
      expect(result.stderr).toContain('> GET https://httpbin.org/get')
    })
  })

  describe('POST requests', () => {
    it('should make POST request with data', async () => {
      const result = await shell.execute('http POST https://httpbin.org/post -d "test data"')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('test data')
    })

    it('should make POST request with JSON data', async () => {
      const result = await shell.execute('http POST https://httpbin.org/post -j \'{"name":"test"}\'')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('name')
      expect(result.stdout).toContain('test')
    })

    it('should make POST request with form data', async () => {
      const result = await shell.execute('http POST https://httpbin.org/post -f "key=value&name=test"')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('key=value')
    })
  })

  describe('file operations', () => {
    it('should save response to file', async () => {
      const outputFile = join(tempDir, 'response.txt')
      const result = await shell.execute(`http GET https://httpbin.org/get -o "${outputFile}"`)
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain(`Response saved to ${outputFile}`)

      // Check file exists
      const file = Bun.file(outputFile)
      expect(await file.exists()).toBe(true)
    })
  })

  describe('error handling', () => {
    it('should handle HTTP error status codes', async () => {
      const result = await shell.execute('http GET https://httpbin.org/status/404')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('HTTP 404')
    })

    it('should handle timeout', async () => {
      const result = await shell.execute('http GET https://timeout-test.com -t 1')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('timeout')
    })

    it('should handle invalid URL', async () => {
      const result = await shell.execute('http GET invalid-url')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Invalid URL')
    })

    it('should handle missing header value', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -H')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Header value required')
    })

    it('should handle invalid header format', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -H "invalid-header"')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Invalid header format')
    })

    it('should handle missing data for JSON', async () => {
      const result = await shell.execute('http POST https://httpbin.org/post -j')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('JSON data required')
    })
  })

  describe('options and flags', () => {
    it('should handle timeout option', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get -t 30')
      expect(result.exitCode).toBe(0)
    })

    it('should handle follow redirects', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get --follow')
      expect(result.exitCode).toBe(0)
    })

    it('should handle unknown options', async () => {
      const result = await shell.execute('http GET https://httpbin.org/get --unknown-option')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown option')
    })
  })

  describe('HTTP methods', () => {
    const methods = ['PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS']

    methods.forEach(method => {
      it(`should handle ${method} method`, async () => {
        const result = await shell.execute(`http ${method} https://httpbin.org/get`)
        expect(result.exitCode).toBe(0)
      })
    })
  })
})