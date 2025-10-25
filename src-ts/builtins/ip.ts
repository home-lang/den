import type { BuiltinCommand, CommandResult, Shell } from './types'

export const ipCommand: BuiltinCommand = {
  name: 'ip',
  description: 'Show public IP address via OpenDNS diagnostic service',
  usage: 'ip',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasCurl = await shell.executeCommand('sh', ['-c', 'command -v curl >/dev/null 2>&1'])
      if (hasCurl.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'ip: curl not found\n', duration: performance.now() - start }

      const res = await shell.executeCommand('sh', ['-c', 'curl -s https://diagnostic.opendns.com/myip ; echo'])
      if (res.exitCode === 0) {
        const out = res.stdout.trim()
        const isIp = /^(?:\d{1,3}\.){3}\d{1,3}$|^[a-f0-9:]+$/i.test(out)
        if (isIp)
          return { exitCode: 0, stdout: `${out}\n`, stderr: '', duration: performance.now() - start }
        return { exitCode: 1, stdout: '', stderr: 'ip: received unexpected response\n', duration: performance.now() - start }
      }
      return { exitCode: 1, stdout: '', stderr: 'ip: failed to fetch public IP\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
