import type { KrustyConfig } from '../src/types'
import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { KrustyShell } from '../src'
import { defaultConfig } from '../src/config'

describe('Net-Check Builtin', () => {
  let shell: KrustyShell
  let testConfig: KrustyConfig
  let originalFetch: typeof globalThis.fetch

  beforeEach(async () => {
    testConfig = {
      ...defaultConfig,
      verbose: false,
    }
    shell = new KrustyShell(testConfig)

    // Mock fetch for testing network operations
    originalFetch = globalThis.fetch
    globalThis.fetch = mock(async (url: string, options?: any) => {
      const mockUrl = url.toString()

      if (mockUrl.includes('google.com')) {
        return new Response('OK', {
          status: 200,
          statusText: 'OK',
          headers: new Headers({
            'content-type': 'text/html'
          })
        })
      }

      if (mockUrl.includes('timeout-test.com')) {
        return new Promise((_, reject) => {
          setTimeout(() => {
            const error = new Error('Request timeout')
            error.name = 'AbortError'
            reject(error)
          }, 50)
        })
      }

      if (mockUrl.includes('unreachable-host.com')) {
        throw new Error('ECONNREFUSED')
      }

      if (mockUrl.includes('github.com')) {
        return new Response('OK', {
          status: 200,
          statusText: 'OK',
          headers: new Headers({
            'server': 'GitHub.com',
            'content-type': 'text/html'
          })
        })
      }

      if (mockUrl.includes('httpbin.org/bytes/1048576')) {
        // Mock 1MB download for speed test
        const buffer = new ArrayBuffer(1048576)
        return new Response(buffer, {
          status: 200,
          statusText: 'OK'
        })
      }

      // Default response
      return new Response('OK', {
        status: 200,
        statusText: 'OK'
      })
    }) as any
  })

  afterEach(async () => {
    globalThis.fetch = originalFetch
    shell.stop()
  })

  describe('help and basic functionality', () => {
    it('should show help message', async () => {
      const result = await shell.execute('net-check --help')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Usage: net-check [command] [options]')
      expect(result.stdout).toContain('Network connectivity and port checking tools')
      expect(result.stdout).toContain('ping HOST')
      expect(result.stdout).toContain('port HOST PORT')
    })

    it('should show error for missing command', async () => {
      const result = await shell.execute('net-check')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('missing command')
    })

    it('should show error for unknown command', async () => {
      const result = await shell.execute('net-check unknown-command')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Unknown command: unknown-command')
    })
  })

  describe('ping command', () => {
    it('should ping a host successfully', async () => {
      const result = await shell.execute('net-check ping google.com -c 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('PING google.com:')
      expect(result.stdout).toContain('Reply from google.com')
      expect(result.stdout).toContain('Ping statistics')
    })

    it('should handle ping timeout', async () => {
      const result = await shell.execute('net-check ping timeout-test.com -c 1 -t 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('PING timeout-test.com:')
      expect(result.stdout).toContain('timeout')
    })

    it('should handle unreachable host', async () => {
      const result = await shell.execute('net-check ping unreachable-host.com -c 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Host unreachable')
    })

    it('should require host for ping', async () => {
      const result = await shell.execute('net-check ping')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Host is required for ping')
    })

    it('should handle custom count and timeout', async () => {
      const result = await shell.execute('net-check ping google.com -c 2 -t 10')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Packets: Sent = 2')
    })
  })

  describe('port command', () => {
    it('should check if port is open', async () => {
      const result = await shell.execute('net-check port github.com 443')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Port 443 on github.com is OPEN')
    })

    it('should handle closed port', async () => {
      const result = await shell.execute('net-check port unreachable-host.com 9999')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Port 9999 on unreachable-host.com is CLOSED')
    })

    it('should require host for port check', async () => {
      const result = await shell.execute('net-check port')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Host is required')
    })

    it('should require valid port number', async () => {
      const result = await shell.execute('net-check port google.com invalid')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Valid port number is required')
    })

    it('should handle timeout option', async () => {
      const result = await shell.execute('net-check port github.com 443 -t 5')
      expect(result.exitCode).toBe(0)
    })

    it('should reject UDP protocol (not supported)', async () => {
      const result = await shell.execute('net-check port github.com 443 -p udp')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('UDP port checking not supported')
    })
  })

  describe('dns command', () => {
    it('should resolve DNS successfully', async () => {
      const result = await shell.execute('net-check dns github.com')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('DNS resolution for github.com:')
      expect(result.stdout).toContain('Successfully resolved')
    })

    it('should handle DNS resolution failure', async () => {
      const result = await shell.execute('net-check dns unreachable-host.com')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('DNS resolution failed')
    })

    it('should require host for DNS resolution', async () => {
      const result = await shell.execute('net-check dns')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Host is required for DNS resolution')
    })

    it('should handle verbose output', async () => {
      const result = await shell.execute('net-check dns github.com -v')
      expect(result.exitCode).toBe(0)
      expect(result.stderr).toContain('Resolving DNS for github.com')
    })
  })

  describe('trace command', () => {
    it('should perform traceroute', async () => {
      const result = await shell.execute('net-check trace github.com')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Traceroute to github.com:')
      expect(result.stdout).toContain('simplified traceroute')
      expect(result.stdout).toContain('Trace complete')
    })

    it('should handle traceroute failure', async () => {
      const result = await shell.execute('net-check trace unreachable-host.com')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Request failed')
    })

    it('should require host for traceroute', async () => {
      const result = await shell.execute('net-check trace')
      expect(result.exitCode).toBe(1)
      expect(result.stderr).toContain('Host is required for traceroute')
    })
  })

  describe('speed command', () => {
    it('should test internet speed', async () => {
      const result = await shell.execute('net-check speed')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Internet speed test:')
      expect(result.stdout).toContain('Download test:')
      expect(result.stdout).toContain('Size:')
      expect(result.stdout).toContain('Speed:')
      expect(result.stdout).toContain('Mbps')
    })

    it('should handle speed test timeout', async () => {
      const result = await shell.execute('net-check speed -t 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Speed test failed')
    })
  })

  describe('interfaces command', () => {
    it('should show network interfaces', async () => {
      const result = await shell.execute('net-check interfaces')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Network interfaces:')
      expect(result.stdout).toContain('Google DNS')
      expect(result.stdout).toContain('Cloudflare DNS')
      expect(result.stdout).toContain('Connected')
    })

    it('should handle timeout for interfaces', async () => {
      const result = await shell.execute('net-check interfaces -t 1')
      expect(result.exitCode).toBe(0)
      expect(result.stdout).toContain('Network interfaces:')
    })
  })

  describe('options and error handling', () => {
    it('should handle verbose flag', async () => {
      const result = await shell.execute('net-check ping google.com -v -c 1')
      expect(result.exitCode).toBe(0)
      expect(result.stderr).toContain('PING google.com')
    })

    it('should handle invalid timeout value', async () => {
      const result = await shell.execute('net-check ping google.com -t invalid')
      expect(result.exitCode).toBe(0) // Invalid timeout is ignored, uses default
    })

    it('should handle invalid count value', async () => {
      const result = await shell.execute('net-check ping google.com -c invalid')
      expect(result.exitCode).toBe(0) // Invalid count is ignored, uses default
    })

    it('should handle protocol option', async () => {
      const result = await shell.execute('net-check port github.com 443 -p tcp')
      expect(result.exitCode).toBe(0)
    })

    it('should handle invalid protocol', async () => {
      const result = await shell.execute('net-check port github.com 443 -p invalid')
      expect(result.exitCode).toBe(0) // Invalid protocol is ignored, uses default
    })
  })
})