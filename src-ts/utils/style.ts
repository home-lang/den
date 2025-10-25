/*
 * Centralized styling helpers for terminal output.
 * - Theme-aware (optionally accepts hex colors)
 * - TTY & env-based color detection
 * - Lightweight ANSI wrappers
 */

import process from 'node:process'

export interface StyleOptions {
  forceColor?: boolean
  noColor?: boolean
}

function envBool(name: string | undefined): boolean | undefined {
  if (!name)
    return undefined
  const v = name.trim()
  if (v === '')
    return undefined
  if (v === '0' || v.toLowerCase() === 'false' || v.toLowerCase() === 'no')
    return false
  return true
}

export function supportsColor(opts: StyleOptions = {}): boolean {
  if (opts.noColor)
    return false
  if (opts.forceColor)
    return true

  const env = process.env
  if (env) {
    const noColor = env.NO_COLOR != null
    if (noColor)
      return false

    const force = env.FORCE_COLOR
    const f = envBool(force)
    if (typeof f === 'boolean')
      return f

    if (env.CI)
      return true
    if (env.TERM_PROGRAM === 'Apple_Terminal' || env.TERM_PROGRAM === 'iTerm.app')
      return true
    if (env.TERM && /color|ansi|xterm|vt100|screen|tmux/i.test(env.TERM))
      return true
  }

  // Fallback to TTY check
  return !!process.stdout.isTTY
}

// Basic ANSI codes
const codes = {
  reset: '\u001B[0m',
  bold: '\u001B[1m',
  dim: '\u001B[2m',
  italic: '\u001B[3m',
  underline: '\u001B[4m',
  inverse: '\u001B[7m',
  hidden: '\u001B[8m',
  strike: '\u001B[9m',
  // 30-37 fg basic
  fg: (n: number) => `\u001B[38;5;${n}m`,
  bg: (n: number) => `\u001B[48;5;${n}m`,
  // common colors
  red: '\u001B[31m',
  green: '\u001B[32m',
  yellow: '\u001B[33m',
  blue: '\u001B[34m',
  magenta: '\u001B[35m',
  cyan: '\u001B[36m',
  gray: '\u001B[90m',
}

function wrap(open: string, input: string, close: string = codes.reset, enable: boolean = true): string {
  if (!enable)
    return input
  if (!input)
    return ''
  return open + input + close
}

export function dim(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.dim, input, codes.reset, enable)
}
export function bold(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.bold, input, codes.reset, enable)
}
export function cyan(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.cyan, input, codes.reset, enable)
}
export function green(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.green, input, codes.reset, enable)
}
export function yellow(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.yellow, input, codes.reset, enable)
}
export function red(input: string, enable: boolean = supportsColor()): string {
  return wrap(codes.red, input, codes.reset, enable)
}
export function reset(): string {
  return codes.reset
}

export function banner(text: string, color: 'cyan' | 'green' | 'yellow' | 'red' | 'none' = 'none', opts?: StyleOptions): string {
  const enable = supportsColor(opts)
  const line = `─── ${text} ───`
  switch (color) {
    case 'cyan': return dim(cyan(line, enable), enable)
    case 'green': return dim(green(line, enable), enable)
    case 'yellow': return dim(yellow(line, enable), enable)
    case 'red': return dim(red(line, enable), enable)
    default: return dim(line, enable)
  }
}

// Hex -> 256-color approximation for basic mapping (simple heuristic)
export function hexTo256(hex: string): number {
  const m = /^#?([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i.exec(hex)
  if (!m)
    return 15 // white
  const r = Number.parseInt(m[1], 16)
  const g = Number.parseInt(m[2], 16)
  const b = Number.parseInt(m[3], 16)
  // 16..231 color cube
  const ir = Math.round((r / 255) * 5)
  const ig = Math.round((g / 255) * 5)
  const ib = Math.round((b / 255) * 5)
  return 16 + 36 * ir + 6 * ig + ib
}

export function color256(text: string, n: number, enable: boolean = supportsColor()): string {
  return wrap(codes.fg(n), text, codes.reset, enable)
}

export const ansi: { codes: typeof codes, wrap: (open: string, input: string, close: string, enable: boolean) => string } = { codes, wrap }
