import type { CommandResult, Plugin, PluginCommand, PluginContext } from '../types'

/**
 * Highlight Plugin
 * - Provides a demo highlight command and prepares hooks for future inline highlighting
 */
class HighlightPlugin implements Plugin {
  name = 'highlight'
  version = '1.0.0'
  description = 'Simple command highlighting utilities'
  author = 'Krusty Team'
  krustyVersion = '>=1.0.0'

  commands: Record<string, PluginCommand> = {
    demo: {
      description: 'Show a highlighted example of a command line',
      usage: 'highlight:demo "your command here"',
      examples: ['highlight:demo "git commit -m \"feat: add plugin\""'],
      execute: async (args: string[], _context: PluginContext): Promise<CommandResult> => {
        const text = args.join(' ') || 'git commit -m "feat: add plugin" && bun test'
        const colored = this.syntaxColor(text)
        return { exitCode: 0, stdout: `${colored}\n`, stderr: '', duration: 0 }
      },
    },
  }

  // Simple lexer-style colorizer using ANSI sequences
  private syntaxColor(text: string): string {
    const reset = '\x1B[0m'
    const colors = {
      cmd: '\x1B[36m', // cyan
      flag: '\x1B[33m', // yellow
      str: '\x1B[32m', // green
      op: '\x1B[35m', // magenta
      path: '\x1B[34m', // blue
    }

    // Tokenize roughly: strings, flags, operators, paths, words
    const tokens: { v: string, t: 'str' | 'flag' | 'op' | 'path' | 'cmd' }[] = []
    // Simplified regex without unnecessary non-capturing groups
    const regex = /"[^"]*"|'[^']*'|-\w[\w-]*|[|&]{1,2}|\.{1,2}\/[\w./-]+|\/[\w./-]+|\w+/g
    let lastIndex = 0
    let match: RegExpExecArray | null

    // Fix: Move the assignment out of the while condition
    while (true) {
      match = regex.exec(text)
      if (!match) {
        break
      }

      if (match.index > lastIndex) {
        tokens.push({ v: text.slice(lastIndex, match.index), t: 'cmd' }) // keep spacing
      }

      const tok = match[0]
      let t: 'str' | 'flag' | 'op' | 'path' | 'cmd'

      if (tok.startsWith('"') || tok.startsWith('\'')) {
        t = 'str'
      }
      else if (tok.startsWith('--') || (tok.startsWith('-') && tok.length > 1)) {
        t = 'flag'
      }
      else if (tok === '|' || tok === '&&' || tok === '&') {
        t = 'op'
      }
      else if (tok.startsWith('/') || tok.startsWith('./') || tok.startsWith('../')) {
        t = 'path'
      }
      else {
        t = 'cmd'
      }

      tokens.push({ v: tok, t })
      lastIndex = regex.lastIndex
    }
    if (lastIndex < text.length) {
      tokens.push({ v: text.slice(lastIndex), t: 'cmd' })
    }

    return tokens
      .map((tk, idx) => {
        if (/^\s+$/.test(tk.v)) {
          return tk.v // keep spacing uncolored
        }

        // Use a more readable approach for color selection
        let color: string
        switch (tk.t) {
          case 'str':
            color = colors.str
            break
          case 'flag':
            color = colors.flag
            break
          case 'op':
            color = colors.op
            break
          case 'path':
            color = colors.path
            break
          default: // 'cmd'
            color = idx === 0 ? colors.cmd : colors.cmd
        }

        return color + tk.v + reset
      })
      .join('')
  }

  async activate(context: PluginContext): Promise<void> {
    context.logger.info('Highlight plugin activated')
  }
}

const plugin: Plugin = new HighlightPlugin()
export default plugin
