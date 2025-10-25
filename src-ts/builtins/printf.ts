import type { BuiltinCommand, CommandResult, Shell } from '../types'

// Expand a subset of backslash escapes in strings (used by %b)
function expandEscapes(input: string): string {
  let out = ''
  for (let i = 0; i < input.length; i++) {
    const ch = input[i]
    if (ch !== '\\') {
      out += ch
      continue
    }
    // Handle escape
    i++
    if (i >= input.length) {
      out += '\\'
      break
    }
    const e = input[i]
    switch (e) {
      // Simple escapes
      case 'n':
        out += '\n'
        break
      case 't':
        out += '\t'
        break
      case 'r':
        out += '\r'
        break
      case 'a':
        out += '\x07'
        break
      case 'b':
        out += '\b'
        break
      case 'f':
        out += '\f'
        break
      case 'v':
        out += '\v'
        break
      case '\\':
        out += '\\'
        break
      // Hex: \xHH
      case 'x': {
        const h1 = input[i + 1]
        const h2 = input[i + 2]
        if (h1 && h2 && /[0-9a-f]{2}/i.test(h1 + h2)) {
          out += String.fromCharCode(Number.parseInt(h1 + h2, 16))
          i += 2
        }
        else {
          out += 'x'
        }
        break
      }
      // Octal: \0OOO (up to 3 octal digits)
      case '0': {
        let j = 0
        let oct = ''
        while (j < 3 && /[0-7]/.test(input[i + 1])) {
          oct += input[i + 1]
          i++
          j++
        }
        if (oct)
          out += String.fromCharCode(Number.parseInt(oct, 8))
        else
          out += '\0'
        break
      }
      // \c: stop output here
      case 'c':
        return out
      default:
        // Unknown escape: keep as-is (like POSIX)
        out += e
    }
  }
  return out
}

function pad(str: string, width?: number, leftAlign?: boolean, padChar = ' '): string {
  if (!width || width <= str.length)
    return str
  const diff = width - str.length
  const fill = padChar.repeat(diff)
  return leftAlign ? (str + fill) : (fill + str)
}

function formatNumberBase(value: number, base: number, uppercase = false): string {
  const s = Math.trunc(value).toString(base)
  return uppercase ? s.toUpperCase() : s
}

function formatFloat(value: number, spec: 'f' | 'e' | 'g', precision?: number): string {
  const p = precision ?? 6
  if (!Number.isFinite(value))
    return String(value)
  switch (spec) {
    case 'f':
      return value.toFixed(p)
    case 'e':
      return value.toExponential(p)
    case 'g': {
      // Use toPrecision, then trim insignificant trailing zeros and possible trailing dot
      const prec = Math.max(1, p)
      let out = value.toPrecision(prec)
      // Normalize casing like POSIX (lowercase e)
      out = out.replace(/E/g, 'e')
      if (out.includes('e')) {
        // For scientific, leave as-is
        return out
      }
      // For decimal, trim trailing zeros
      if (out.includes('.')) {
        // Trim trailing zeros safely without catastrophic backtracking
        // 1) Remove trailing zeros after a non-zero decimal digit
        out = out.replace(/(\.\d*[1-9])0+$/u, '$1')
        // 2) If only zeros after decimal remain, drop the fractional part
        out = out.replace(/\.0+$/u, '')
        // 3) Remove trailing dot if any
        out = out.replace(/\.$/u, '')
      }
      return out
    }
  }
}

// Parse and apply printf-style formatting
function formatPrintf(spec: string, args: string[]): string {
  let i = 0
  let out = ''
  // Regex for % [flags] [width] [.precision] [specifier]
  // Use non-ambiguous width ([1-9]\d*) so '0' belongs to flags, avoiding overlap
  const re = /%(%|([-0]*)([1-9]\d*)?(?:\.(\d+))?([sdqboxXfeg]))/g
  let lastIndex = 0
  let match: RegExpExecArray | null
  // eslint-disable-next-line no-cond-assign
  while ((match = re.exec(spec))) {
    out += spec.slice(lastIndex, match.index)
    lastIndex = re.lastIndex

    // Handle %%
    if (match[1] === '%') {
      out += '%'
      continue
    }

    const flag = match[2] || ''
    const widthStr = match[3]
    const precStr = match[4]
    const type = match[5] as 's' | 'd' | 'q' | 'b' | 'o' | 'x' | 'X' | 'f' | 'e' | 'g'
    const leftAlign = flag.includes('-')
    const zeroPad = flag.includes('0') && !leftAlign
    const width = widthStr ? Number(widthStr) : undefined
    const precision = precStr ? Number(precStr) : undefined

    const arg = args[i++] ?? ''
    let formatted = ''

    switch (type) {
      case 's': {
        const s = String(arg)
        const truncated = (precision != null) ? s.slice(0, precision) : s
        formatted = pad(truncated, width, leftAlign, zeroPad ? '0' : ' ')
        break
      }
      case 'q': {
        const s = JSON.stringify(String(arg))
        formatted = pad(s, width, leftAlign, zeroPad ? '0' : ' ')
        break
      }
      case 'd': {
        const n = Number(arg)
        const isNeg = n < 0
        let s = Math.trunc(Math.abs(n)).toString()
        if (precision != null)
          s = s.padStart(precision, '0')
        if (isNeg)
          s = `-${s}`
        const padChar = zeroPad && precision == null ? '0' : ' '
        formatted = pad(s, width, leftAlign, padChar)
        break
      }
      case 'o': {
        const n = Number(arg)
        let s = formatNumberBase(Math.abs(n), 8)
        if (precision != null)
          s = s.padStart(precision, '0')
        if (n < 0)
          s = `-${s}`
        const padChar = zeroPad && precision == null ? '0' : ' '
        formatted = pad(s, width, leftAlign, padChar)
        break
      }
      case 'x':
      case 'X': {
        const upper = type === 'X'
        const n = Number(arg)
        let s = formatNumberBase(Math.abs(n), 16, upper)
        if (precision != null)
          s = s.padStart(precision, '0')
        if (n < 0)
          s = `-${s}`
        const padChar = zeroPad && precision == null ? '0' : ' '
        formatted = pad(s, width, leftAlign, padChar)
        break
      }
      case 'f':
      case 'e':
      case 'g': {
        const n = Number(arg)
        const s = formatFloat(n, type, precision)
        const padChar = zeroPad ? '0' : ' '
        formatted = pad(s, width, leftAlign, padChar)
        break
      }
      case 'b': {
        const s = expandEscapes(String(arg))
        formatted = pad(s, width, leftAlign, zeroPad ? '0' : ' ')
        break
      }
      default: {
        // Unknown specifier: leave literal and step arg index back
        i--
        formatted = match[0]
      }
    }

    out += formatted
  }
  out += spec.slice(lastIndex)
  return out
}

export const printfCommand: BuiltinCommand = {
  name: 'printf',
  description: 'Format and print data',
  usage: 'printf format [arguments...]',
  examples: [
    'printf "%10s" hello',
    'printf "%-8.3f" 3.14159',
    'printf "%x %X %o" 255 255 8',
    'printf %b "line\\nbreak"',
  ],
  async execute(args: string[], shell: Shell): Promise<CommandResult> {
    const start = performance.now()
    if (shell.config.verbose)
      shell.log.debug('[printf] args:', args.join(' '))
    if (args.length === 0)
      return { exitCode: 1, stdout: '', stderr: 'printf: missing format string\n', duration: performance.now() - start }

    const fmt = args.shift()!
    const out = formatPrintf(fmt, args)
    if (shell.config.verbose)
      shell.log.debug('[printf] format:', fmt, 'out.len:', out.length)
    return { exitCode: 0, stdout: out, stderr: '', duration: performance.now() - start }
  },
}
