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
}

// Lightweight syntax highlighting for rendering only (does not affect state)
export function renderHighlighted(
  text: string,
  colorsInput: Partial<SyntaxColors> | undefined,
  fallbackHighlightColor: string | undefined,
): string {
  const reset = '\x1B[0m'
  const dim = fallbackHighlightColor ?? '\x1B[90m'
  const colors: SyntaxColors = {
    command: colorsInput?.command ?? '\x1B[36m',
    subcommand: colorsInput?.subcommand ?? '\x1B[94m',
    string: colorsInput?.string ?? dim,
    operator: colorsInput?.operator ?? dim,
    variable: colorsInput?.variable ?? dim,
    flag: colorsInput?.flag ?? '\x1B[33m',
    number: colorsInput?.number ?? '\x1B[35m',
    path: colorsInput?.path ?? '\x1B[32m',
    comment: colorsInput?.comment ?? dim,
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

  // Strings
  out = out.replace(/("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*')/g, `${colors.string}$1${reset}`)

  // Common subcommands for tools like git/npm/yarn/bun: color the subcommand token
  out = out.replace(/\b(git|npm|yarn|pnpm|bun)\s+([a-z][\w:-]*)/i, (_m, tool: string, sub: string) => {
    return `${tool} ${colors.subcommand}${sub}${reset}`
  })

  // Command at line start
  out = out.replace(/^[\w./-]+/, m => `${colors.command}${m}${reset}`)

  // Flags: -a, -xyz, --long-flag
  out = out.replace(/\s(--?[a-z][\w-]*)/gi, ` ${colors.flag}$1${reset}`)

  // Variables $VAR, ${VAR}, $1
  out = out.replace(/\$(?:\d+|\{?\w+\}?)/g, `${colors.variable}$&${reset}`)

  // Operators and pipes/redirections
  out = out.replace(/(\|\||&&|;|<<?|>>?)/g, `${colors.operator}$1${reset}`)

  // Numbers - only standalone numbers, not digits within words/tokens
  out = out.replace(/(?:^|\s)(\d+)(?=\s|$)/g, (match, digits) => {
    const prefix = match.slice(0, -digits.length)
    return `${prefix}${colors.number}${digits}${reset}`
  })

  // Paths: ./foo, ../bar, /usr/bin, ~/x
  out = out.replace(/((?:\.{1,2}|~)?\/[\w@%\-./]+)/g, `${colors.path}$1${reset}`)

  return out
}
