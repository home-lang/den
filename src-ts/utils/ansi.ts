/**
 * Strips ANSI escape codes from a string
 * @param str The string to strip ANSI codes from
 * @returns The string with ANSI codes removed
 */
export function stripAnsi(str: string): string {
  // This regex matches ANSI escape codes including colors, styles, etc.
  // eslint-disable-next-line no-control-regex
  return str.replace(/[\u001B\u009B][[\]()#;?]*(?:(?:(?:(?:;[-a-zA-Z\d\/#&.:=?%@~_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d\/#&.:=?%@~_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g, '')
}

/**
 * Checks if a string contains ANSI escape codes
 * @param str The string to check
 * @returns True if the string contains ANSI codes
 */
export function hasAnsi(str: string): boolean {
  // eslint-disable-next-line no-control-regex
  return /[\u001B\u009B][[\]()#;?]*(?:(?:(?:(?:;[-a-zA-Z\d\/#&.:=?%@~_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d\/#&.:=?%@~_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/.test(str)
}
