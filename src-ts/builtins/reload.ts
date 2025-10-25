import type { BuiltinCommand, CommandResult, Shell } from './types'

/**
 * Reload command - reloads Krusty configuration, hooks, and plugins
 */
export const reloadCommand: BuiltinCommand = {
  name: 'reload',
  description: 'Reload configuration, hooks, and plugins (same as sourcing shell config)',
  usage: 'reload',
  async execute(_args: string[], shell: Shell): Promise<CommandResult> {
    return shell.reload()
  },
}
