import type { CommandResult, Shell } from '../types'

export async function yes(args: string[], shell: Shell): Promise<CommandResult> {
  // Check if there's a recent script suggestion
  const suggestion = (shell as any).lastScriptSuggestion
  
  if (!suggestion) {
    return {
      exitCode: 1,
      stdout: '',
      stderr: 'No script suggestion available. Use "yes" after a failed "bun run" command with suggestions.\n',
      duration: 0,
      streamed: false
    }
  }

  // Check if suggestion is recent (within last 5 minutes)
  const fiveMinutesAgo = Date.now() - (5 * 60 * 1000)
  if (suggestion.timestamp < fiveMinutesAgo) {
    // Clear stale suggestion
    ;(shell as any).lastScriptSuggestion = null
    return {
      exitCode: 1,
      stdout: '',
      stderr: 'Script suggestion has expired. Please run the command again to get a fresh suggestion.\n',
      duration: 0,
      streamed: false
    }
  }

  // Clear the suggestion since we're using it
  ;(shell as any).lastScriptSuggestion = null

  // Execute the suggested script
  const suggestedCommand = `bun run ${suggestion.suggestion}`
  return await shell.execute(suggestedCommand)
}
