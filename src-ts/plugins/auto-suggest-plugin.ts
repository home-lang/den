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

        // Enhanced typo corrections and smart suggestions
        const corrections: Record<string, string> = {
          // Git typos
          gti: 'git',
          got: 'git',
          gut: 'git',
          gir: 'git',
          gits: 'git status',
          gitst: 'git status',
          gist: 'git status',

          // Command typos
          sl: 'ls',
          la: 'ls -la',
          ks: 'ls',
          cd: 'cd',
          claer: 'clear',
          clar: 'clear',
          celar: 'clear',

          // Package manager typos
          nmp: 'npm',
          npn: 'npm',
          yran: 'yarn',
          bunx: 'bunx',

          // Bun shortcuts
          b: 'bun',
          br: 'bun run',
          bt: 'bun test',
          bi: 'bun install',
          bd: 'bun run dev',
          bb: 'bun run build',

          // Docker shortcuts
          dk: 'docker',
          dkc: 'docker-compose',
          dockerc: 'docker-compose',

          // Git workflow shortcuts
          gst: 'git status',
          gco: 'git checkout',
          gpl: 'git pull',
          gps: 'git push',
          gac: 'git add . && git commit -m',

          // System shortcuts
          pf: 'ps aux | grep',
          kp: 'kill -9',
          ll: 'ls -la',
          la: 'ls -la',
        }

        // Context-aware suggestions based on previous commands
        if (history.length > 0) {
          const lastCommand = history[0]

          // If last command was git-related, suggest git commands
          if (lastCommand.startsWith('git') && partial && startsWith('git', partial)) {
            const gitSuggestions = [
              'git status',
              'git add .',
              'git commit -m',
              'git push',
              'git pull',
              'git checkout',
              'git branch',
              'git log --oneline',
            ]

            for (const gitCmd of gitSuggestions) {
              if (startsWith(gitCmd, partial) && !suggestions.includes(gitCmd)) {
                suggestions.push(gitCmd)
                if (suggestions.length >= max) break
              }
            }
          }

          // If last command was npm/bun related, suggest package commands
          if ((lastCommand.startsWith('npm') || lastCommand.startsWith('bun')) &&
              (partial && (startsWith('npm', partial) || startsWith('bun', partial)))) {
            const packageSuggestions = [
              'npm install',
              'npm run dev',
              'npm run build',
              'npm test',
              'bun install',
              'bun run dev',
              'bun run build',
              'bun test',
            ]

            for (const pkgCmd of packageSuggestions) {
              if (startsWith(pkgCmd, partial) && !suggestions.includes(pkgCmd)) {
                suggestions.push(pkgCmd)
                if (suggestions.length >= max) break
              }
            }
          }
        }

        // Apply correction if the current partial exactly matches a known typo
        const correctionKey = Object.keys(corrections).find(k => equals(k, partial))
        if (correctionKey) {
          const fix = corrections[correctionKey]
          // Put correction at the front
          if (!suggestions.includes(fix))
            suggestions.unshift(fix)
        }

        // Fuzzy matching for partial input
        if (partial.length >= 2 && suggestions.length < max) {
          const fuzzyMatches = this.getFuzzyMatches(partial, history, context)
          for (const match of fuzzyMatches) {
            if (!suggestions.includes(match)) {
              suggestions.push(match)
              if (suggestions.length >= max) break
            }
          }
        }

        return suggestions.slice(0, max)
      },
    },
  ]

  private getFuzzyMatches(partial: string, history: string[], context: PluginContext): string[] {
    const matches: string[] = []
    const lowerPartial = partial.toLowerCase()

    for (const command of history) {
      if (this.fuzzyMatch(command.toLowerCase(), lowerPartial)) {
        matches.push(command)
        if (matches.length >= 5) break // Limit fuzzy matches
      }
    }

    return matches.sort((a, b) => {
      // Sort by relevance: exact prefix first, then by fuzzy score
      const aStartsWith = a.toLowerCase().startsWith(lowerPartial)
      const bStartsWith = b.toLowerCase().startsWith(lowerPartial)

      if (aStartsWith && !bStartsWith) return -1
      if (!aStartsWith && bStartsWith) return 1

      return this.fuzzyScore(a.toLowerCase(), lowerPartial) - this.fuzzyScore(b.toLowerCase(), lowerPartial)
    })
  }

  private fuzzyMatch(text: string, pattern: string): boolean {
    let textIndex = 0
    let patternIndex = 0

    while (textIndex < text.length && patternIndex < pattern.length) {
      if (text[textIndex] === pattern[patternIndex]) {
        patternIndex++
      }
      textIndex++
    }

    return patternIndex === pattern.length
  }

  private fuzzyScore(text: string, pattern: string): number {
    let score = 0
    let lastIndex = -1

    for (const char of pattern) {
      const index = text.indexOf(char, lastIndex + 1)
      if (index === -1) return 1000 // High penalty for missing characters
      score += index - lastIndex
      lastIndex = index
    }

    return score
  }

  async activate(context: PluginContext): Promise<void> {
    context.logger.debug('Auto-suggest plugin activated')
  }
}

const plugin: Plugin = new AutoSuggestPlugin()
export default plugin
