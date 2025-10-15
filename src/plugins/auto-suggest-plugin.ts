import type { Plugin, PluginCompletion, PluginContext } from '../types'

/**
 * Auto Suggest Plugin
 * - Provides extra completions based on history and common corrections
 */
class AutoSuggestPlugin implements Plugin {
  name = 'auto-suggest'
  version = '1.0.0'
  description = 'Inline-like auto suggestions from history and common typos'
  author = 'Krusty Team'
  krustyVersion = '>=1.0.0'

  // Suggestions from history and common corrections
  completions: PluginCompletion[] = [
    {
      // Match any input to consider suggestions
      command: '',
      complete: (input: string, cursor: number, context: PluginContext): string[] => {
        const suggestions: string[] = []
        const before = input.slice(0, Math.max(0, cursor))
        const partial = before.trim()
        const caseSensitive = context.config.completion?.caseSensitive ?? false
        const startsWith = (s: string, p: string) =>
          caseSensitive ? s.startsWith(p) : s.toLowerCase().startsWith(p.toLowerCase())
        const equals = (a: string, b: string) =>
          caseSensitive ? a === b : a.toLowerCase() === b.toLowerCase()
        const max = context.config.completion?.maxSuggestions || 10

        // If the prompt is empty (user deleted everything), do not suggest anything
        if (partial.length === 0)
          return []

        // Special handling for `cd` suggestions
        // Defer to core cd completions if the line starts with `cd` (case-insensitive)
        const trimmedLeading = before.replace(/^\s+/, '')
        if (/^cd\b/i.test(trimmedLeading))
          return []

        // History suggestions (most recent first)
        // Do not suggest `cd ...` here; cd is handled specially above.
        const history = [...context.shell.history].reverse()
        const partialIsCd = /^\s*cd\b/i.test(partial)
        if (!partialIsCd) {
          for (const h of history) {
            if (h.startsWith('cd '))
              continue
            if (!partial || startsWith(h, partial)) {
              if (!suggestions.includes(h))
                suggestions.push(h)
              if (suggestions.length >= max)
                break
            }
          }
        }

        // Alias names (optionally toggleable via plugin config)
        const includeAliases = context.pluginConfig?.autoSuggest?.includeAliases !== false
        if (includeAliases && suggestions.length < max) {
          for (const alias of Object.keys(context.shell.aliases)) {
            if (!partial || startsWith(alias, partial)) {
              if (!suggestions.includes(alias))
                suggestions.push(alias)
              if (suggestions.length >= max)
                break
            }
          }
        }

        // Common typo corrections for git
        const corrections: Record<string, string> = {
          gti: 'git',
          got: 'git',
          gut: 'git',
          gir: 'git',
          gits: 'git status',
          gitst: 'git status',
          gist: 'git status',
        }
        // Apply correction if the current partial exactly matches a known typo
        const correctionKey = Object.keys(corrections).find(k => equals(k, partial))
        if (correctionKey) {
          const fix = corrections[correctionKey]
          // Put correction at the front
          if (!suggestions.includes(fix))
            suggestions.unshift(fix)
        }

        return suggestions.slice(0, max)
      },
    },
  ]

  async activate(context: PluginContext): Promise<void> {
    context.logger.debug('Auto-suggest plugin activated')
  }
}

const plugin: Plugin = new AutoSuggestPlugin()
export default plugin
