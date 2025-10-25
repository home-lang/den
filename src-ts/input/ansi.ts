// ANSI helpers shared across input rendering
// Strip ANSI escape sequences commonly used for styling and cursor control
// and compute the visible length of a string.

// eslint-disable-next-line no-control-regex
const ANSI_REGEX = /\x1B\[[0-9;]*[mGKH]/g

export function stripAnsi(text: string): string {
  return text.replace(ANSI_REGEX, '')
}

export function visibleLength(text: string): number {
  return stripAnsi(text).length
}

// Basic width calculation utilities
// Note: This is a light-weight implementation sufficient for prompts and suggestions.
// It handles:
// - Control and combining characters (width 0)
// - Common wide characters (CJK, some symbols) as width 2

function isControl(charCode: number): boolean {
  return (charCode >= 0 && charCode < 32) || charCode === 127
}

function isCombining(charCode: number): boolean {
  // Combining Diacritical Marks, and a few common zero-width ranges
  return (
    (charCode >= 0x0300 && charCode <= 0x036F)
    || (charCode >= 0x1AB0 && charCode <= 0x1AFF)
    || (charCode >= 0x1DC0 && charCode <= 0x1DFF)
    || (charCode >= 0x20D0 && charCode <= 0x20FF)
    || (charCode >= 0xFE20 && charCode <= 0xFE2F)
  )
}

function isWide(charCode: number): boolean {
  // A pragmatic subset of Unicode East Asian Wide ranges
  return (
    (charCode >= 0x1100 && charCode <= 0x115F) // Hangul Jamo
    || charCode === 0x2329 || charCode === 0x232A // Brackets
    || (charCode >= 0x2E80 && charCode <= 0xA4CF) // CJK Radicals .. Yi
    || (charCode >= 0xAC00 && charCode <= 0xD7A3) // Hangul Syllables
    || (charCode >= 0xF900 && charCode <= 0xFAFF) // CJK Compatibility Ideographs
    || (charCode >= 0xFE10 && charCode <= 0xFE19) // Small Form Variants
    || (charCode >= 0xFE30 && charCode <= 0xFE6F) // CJK Compatibility Forms
    || (charCode >= 0xFF00 && charCode <= 0xFF60) // Fullwidth Forms
    || (charCode >= 0xFFE0 && charCode <= 0xFFE6)
  )
}

export function wcwidth(ch: string): number {
  const code = ch.codePointAt(0) ?? 0
  if (isControl(code) || isCombining(code))
    return 0
  return isWide(code) ? 2 : 1
}

export function displayWidth(text: string): number {
  const clean = stripAnsi(text)
  let width = 0
  for (const ch of clean) width += wcwidth(ch)
  return width
}

export function truncateToWidth(text: string, maxWidth: number): string {
  if (maxWidth <= 0)
    return ''
  const clean = stripAnsi(text)
  let width = 0
  let out = ''
  for (const ch of Array.from(clean)) { // by code points
    const w = wcwidth(ch)
    if (width + w > maxWidth)
      break
    width += w
    out += ch
  }
  return out
}
