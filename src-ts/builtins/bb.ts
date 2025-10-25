import type { BuiltinCommand, CommandResult, Shell } from './types'

export const bbCommand: BuiltinCommand = {
  name: 'bb',
  description: 'Run build script via bun run build',
  usage: 'bb [args...]',
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    const hasBun = await shell.executeCommand('sh', ['-c', 'command -v bun >/dev/null 2>&1'])
    if (hasBun.exitCode !== 0)
      return { exitCode: 1, stdout: '', stderr: 'bb: bun not found\n', duration: performance.now() - start }

    // Always use bun run build with any passed args
    const res = await shell.executeCommand('bun', ['run', 'build', ...args])
    // Shell handles echoing the command/scripts via buildPackageRunEcho when buffering
    if (res.streamed === true) {
      // Already streamed to terminal; avoid returning buffers that could be printed again
      return { exitCode: res.exitCode, stdout: '', stderr: '', duration: performance.now() - start, streamed: true }
    }
    if (res.exitCode === 0)
      return { exitCode: 0, stdout: res.stdout || '', stderr: '', duration: performance.now() - start, streamed: false }
    return { exitCode: res.exitCode || 1, stdout: res.stdout || '', stderr: res.stderr || 'bb: build failed\n', duration: performance.now() - start, streamed: false }
  },
}
