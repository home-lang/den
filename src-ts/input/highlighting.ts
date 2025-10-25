export interface SyntaxColors {
  command: string
  subcommand: string
  string: string
  operator: string
  variable: string
  flag: string
  number: string
  path: string
  comment: string
  builtin: string
  alias: string
  error: string
  keyword: string
}

// Enhanced syntax highlighting for rendering only (does not affect state)
export function renderHighlighted(
  text: string,
  colorsInput: Partial<SyntaxColors> | undefined,
  fallbackHighlightColor: string | undefined,
  context?: { builtins?: Set<string>; aliases?: Record<string, string> },
): string {
  const reset = '\x1B[0m'
  const dim = fallbackHighlightColor ?? '\x1B[90m'
  const colors: SyntaxColors = {
    command: colorsInput?.command ?? '\x1B[36m',
    subcommand: colorsInput?.subcommand ?? '\x1B[94m',
    string: colorsInput?.string ?? '\x1B[32m',
    operator: colorsInput?.operator ?? '\x1B[93m',
    variable: colorsInput?.variable ?? '\x1B[95m',
    flag: colorsInput?.flag ?? '\x1B[33m',
    number: colorsInput?.number ?? '\x1B[35m',
    path: colorsInput?.path ?? '\x1B[92m',
    comment: colorsInput?.comment ?? dim,
    builtin: colorsInput?.builtin ?? '\x1B[96m',
    alias: colorsInput?.alias ?? '\x1B[91m',
    error: colorsInput?.error ?? '\x1B[31m',
    keyword: colorsInput?.keyword ?? '\x1B[97m',
  }

  // Handle comments first: color from first unquoted # to end
  // Simple heuristic: split on first # not preceded by \
  let commentIndex = -1
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '#') {
      if (i === 0 || text[i - 1] !== '\\') {
        commentIndex = i
        break
      }
    }
  }
  if (commentIndex >= 0) {
    const left = text.slice(0, commentIndex)
    const comment = text.slice(commentIndex)
    return `${renderHighlighted(left, colorsInput, fallbackHighlightColor)}${colors.comment}${comment}${reset}`
  }

  let out = text

  // Tokenize the input to handle proper highlighting
  const tokens = tokenizeInput(text)
  const highlightedTokens = tokens.map((token, index) => highlightToken(token, index, tokens, colors, context))

  return highlightedTokens.join('')
}

interface Token {
  type: 'command' | 'argument' | 'flag' | 'operator' | 'string' | 'variable' | 'number' | 'path' | 'whitespace' | 'comment'
  value: string
  position: number
}

function tokenizeInput(text: string): Token[] {
  const tokens: Token[] = []
  let position = 0
  let inString = false
  let stringChar = ''
  let current = ''

  const pushToken = (type: Token['type'], value: string) => {
    if (value) {
      tokens.push({ type, value, position: position - value.length })
    }
  }

  const finishCurrent = () => {
    if (current) {
      // Determine token type based on content and position
      const trimmed = current.trim()
      if (!trimmed) {
        pushToken('whitespace', current)
      } else if (trimmed.startsWith('#')) {
        pushToken('comment', current)
      } else if (trimmed.match(/^--?[a-zA-Z]/)) {
        pushToken('flag', current)
      } else if (trimmed.match(/^\$\w+|\$\{\w+\}|\$\d+/)) {
        pushToken('variable', current)
      } else if (trimmed.match(/^\d+$/)) {
        pushToken('number', current)
      } else if (trimmed.match(/^[\|\&\;\<\>]+$/)) {
        pushToken('operator', current)
      } else if (trimmed.match(/^(\.{1,2}|~)?\/[\w@%\-./]+$/)) {
        pushToken('path', current)
      } else if (tokens.length === 0 || tokens[tokens.length - 1]?.type === 'operator') {
        pushToken('command', current)
      } else {
        pushToken('argument', current)
      }
      current = ''
    }
  }

  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    position = i + 1

    if (inString) {
      current += char
      if (char === stringChar && text[i - 1] !== '\\') {
        inString = false
        pushToken('string', current)
        current = ''
      }
    } else {
      if (char === '"' || char === "'") {
        finishCurrent()
        inString = true
        stringChar = char
        current = char
      } else if (char === '#' && (i === 0 || text[i - 1] !== '\\')) {
        finishCurrent()
        // Rest of line is comment
        current = text.slice(i)
        break
      } else if (/\s/.test(char)) {
        finishCurrent()
        current = char
        // Collect consecutive whitespace
        while (i + 1 < text.length && /\s/.test(text[i + 1])) {
          current += text[++i]
          position = i + 1
        }
        pushToken('whitespace', current)
        current = ''
      } else if (/[\|\&\;\<\>]/.test(char)) {
        finishCurrent()
        current = char
        // Collect consecutive operators
        while (i + 1 < text.length && /[\|\&\;\<\>]/.test(text[i + 1])) {
          current += text[++i]
          position = i + 1
        }
        pushToken('operator', current)
        current = ''
      } else {
        current += char
      }
    }
  }

  finishCurrent()

  // Handle final comment if we ended in one
  if (current) {
    pushToken('comment', current)
  }

  return tokens
}

function highlightToken(
  token: Token,
  index: number,
  allTokens: Token[],
  colors: SyntaxColors,
  context?: { builtins?: Set<string>; aliases?: Record<string, string> }
): string {
  const reset = '\x1B[0m'
  const { type, value } = token

  switch (type) {
    case 'command': {
      const trimmed = value.trim()

      // Check if it's a builtin command
      if (context?.builtins?.has(trimmed)) {
        return `${colors.builtin}${value}${reset}`
      }

      // Check if it's an alias
      if (context?.aliases && trimmed in context.aliases) {
        return `${colors.alias}${value}${reset}`
      }

      // Check for keywords
      const keywords = new Set(['if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case', 'esac', 'function'])
      if (keywords.has(trimmed)) {
        return `${colors.keyword}${value}${reset}`
      }

      return `${colors.command}${value}${reset}`
    }

    case 'argument': {
      // Special handling for subcommands after known tools
      const prevTokens = allTokens.slice(0, index)
      const commandToken = prevTokens.find(t => t.type === 'command')

      if (commandToken) {
        const cmd = commandToken.value.trim()
        const knownTools = ['git', 'npm', 'yarn', 'pnpm', 'bun', 'docker', 'kubectl', 'aws']

        if (knownTools.includes(cmd)) {
          // This might be a subcommand
          const nonWhitespaceTokens = prevTokens.filter(t => t.type !== 'whitespace')
          if (nonWhitespaceTokens.length === 1) {
            return `${colors.subcommand}${value}${reset}`
          }
        }
      }

      return value // No special highlighting for regular arguments
    }

    case 'flag':
      return `${colors.flag}${value}${reset}`

    case 'operator':
      return `${colors.operator}${value}${reset}`

    case 'string':
      return `${colors.string}${value}${reset}`

    case 'variable':
      return `${colors.variable}${value}${reset}`

    case 'number':
      return `${colors.number}${value}${reset}`

    case 'path':
      return `${colors.path}${value}${reset}`

    case 'comment':
      return `${colors.comment}${value}${reset}`

    case 'whitespace':
    default:
      return value
  }
}
