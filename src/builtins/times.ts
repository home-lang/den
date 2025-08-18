import type { BuiltinCommand, CommandResult } from './types'
import process from 'node:process'

export const timesCommand: BuiltinCommand = {
  name: 'times',
  description: 'Print accumulated user and system times',
  usage: 'times',
  examples: [
    'times',
  ],
  async execute(): Promise<CommandResult> {
    const start = performance.now()
    const up = process.uptime() // seconds
    const fmt = (s: number) => {
      const m = Math.floor(s / 60)
      const sec = (s % 60).toFixed(2)
      return `${m}m${sec}s`
    }
    const line = `${fmt(up)} ${fmt(0)}\n${fmt(0)} ${fmt(0)}\n`
    return { exitCode: 0, stdout: line, stderr: '', duration: performance.now() - start }
  },
}
