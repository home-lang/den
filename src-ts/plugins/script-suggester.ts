import type { CommandResult, HookContext, HookHandler, HookResult, Plugin } from '../types'
import { findSimilarScript, formatScriptNotFoundError, getPackageScripts } from '../utils/script-suggestions'

const afterCommandHandler: HookHandler = async (context: HookContext): Promise<HookResult> => {
  const { result, command } = context.data as { result: CommandResult, command: string };
  const { shell } = context;

  const parts = command.trim().split(/\s+/);
  const packageManagers = ['bun', 'npm', 'pnpm', 'yarn'];
  const isPackageManagerRun = packageManagers.includes(parts[0]) && parts[1] === 'run';

  if (isPackageManagerRun && result.exitCode !== 0 && result.stderr) {
    const scriptName = parts[2] || '';
    if (scriptName) {
      try {
        const scripts = getPackageScripts(shell.cwd);
        const looksLikeMissing = /script not found/i.test(result.stderr.toLowerCase());

        if (looksLikeMissing) {
          const suggestion = findSimilarScript(scriptName, scripts);
          if (suggestion) {
            const suggestionMessage = formatScriptNotFoundError(scriptName, suggestion);
            result.stderr = `${result.stderr.trim()}\n${suggestionMessage}`;
          }
        }
      } catch {
        // Ignore errors (e.g., no package.json)
      }
    }
  }

  return { success: true, data: { result, command } };
};

/**
 * A plugin that suggests similar scripts when a package manager `run` command fails because the script was not found.
 */
export const scriptSuggesterPlugin: Plugin = {
  name: 'script-suggester',
  version: '1.0.0',
  description: 'Suggests similar package manager scripts on `not found` errors.',
  hooks: {
    'command:after': afterCommandHandler,
  },
}
