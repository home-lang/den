export function getLines(input: string): string[] {
  return input.split('\n')
}

export function indexToLineCol(input: string, index: number): { line: number, col: number } {
  const lines = getLines(input)
  let remaining = Math.max(0, Math.min(index, input.length))
  for (let i = 0; i < lines.length; i++) {
    const len = lines[i].length
    if (remaining <= len)
      return { line: i, col: remaining }
    remaining -= (len + 1)
  }
  return { line: lines.length - 1, col: (lines[lines.length - 1] || '').length }
}

export function lineColToIndex(input: string, line: number, col: number): number {
  const lines = getLines(input)
  const safeLine = Math.max(0, Math.min(line, lines.length - 1))
  let idx = 0
  for (let i = 0; i < safeLine; i++) idx += lines[i].length + 1
  const maxCol = (lines[safeLine] ?? '').length
  const safeCol = Math.max(0, Math.min(col, maxCol))
  return idx + safeCol
}
