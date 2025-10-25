import type { BuiltinCommand, CommandResult, Shell } from './types'

export const localipCommand: BuiltinCommand = {
  name: 'localip',
  description: 'Show local IP addresses (IPv4/IPv6) from ifconfig output',
  usage: 'localip',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const prev = shell.config.streamOutput
    shell.config.streamOutput = false
    try {
      const hasIfconfig = await shell.executeCommand('sh', ['-c', 'command -v ifconfig >/dev/null 2>&1'])
      const hasGrep = await shell.executeCommand('sh', ['-c', 'command -v grep >/dev/null 2>&1'])
      const hasAwk = await shell.executeCommand('sh', ['-c', 'command -v awk >/dev/null 2>&1'])
      if (hasIfconfig.exitCode !== 0 || hasGrep.exitCode !== 0 || hasAwk.exitCode !== 0)
        return { exitCode: 1, stdout: '', stderr: 'localip: required tools not found\n', duration: performance.now() - start }

      const cmd = 'ifconfig -a | grep -o \'inet6\\? \\ (addr:\\)\\?\\s\\?\\(\\(\\(\\([0-9]\\+\\.\\)\\{3\\}[0-9]\\+\\)\\|[a-fA-F0-9:]\\+\\)\' | awk \'{ sub(/inet6? (addr:)? ?/, ""); print }\''
      const res = await shell.executeCommand('sh', ['-c', cmd])
      if (res.exitCode === 0 && res.stdout.trim().length > 0)
        return { exitCode: 0, stdout: res.stdout, stderr: '', duration: performance.now() - start }

      return { exitCode: 1, stdout: '', stderr: 'localip: failed to parse local IPs\n', duration: performance.now() - start }
    }
    finally {
      shell.config.streamOutput = prev
    }
  },
}
