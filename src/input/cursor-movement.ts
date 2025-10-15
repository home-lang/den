import { getLines as utilGetLines, indexToLineCol as utilIndexToLineCol, lineColToIndex as utilLineColToIndex } from './cursor-utils'

export class CursorMovement {
  private currentInput: string
  private cursorPosition: number

  constructor(getCurrentInput: () => string, getCursorPosition: () => number, setCursorPosition: (pos: number) => void) {
    this.getCurrentInput = getCurrentInput
    this.getCursorPosition = getCursorPosition
    this.setCursorPosition = setCursorPosition
  }

  private getCurrentInput: () => string
  private getCursorPosition: () => number
  private setCursorPosition: (pos: number) => void

  moveLeft(): void {
    const pos = this.getCursorPosition()
    if (pos > 0)
      this.setCursorPosition(pos - 1)
  }

  moveRight(): void {
    const input = this.getCurrentInput()
    const pos = this.getCursorPosition()
    if (pos < input.length)
      this.setCursorPosition(pos + 1)
  }

  moveToLineStart(): void {
    const input = this.getCurrentInput()
    const pos = this.getCursorPosition()
    const { line } = this.indexToLineCol(input, pos)
    this.setCursorPosition(this.lineColToIndex(input, line, 0))
  }

  moveToLineEnd(): void {
    const input = this.getCurrentInput()
    const pos = this.getCursorPosition()
    const { line } = this.indexToLineCol(input, pos)
    const lines = this.getLines(input)
    const endCol = (lines[line] ?? '').length
    this.setCursorPosition(this.lineColToIndex(input, line, endCol))
  }

  moveWordLeft(): void {
    const input = this.getCurrentInput()
    let pos = this.getCursorPosition()
    if (pos === 0)
      return

    // Skip initial spaces to previous non-space
    while (pos > 0 && input[pos - 1] === ' ') pos--
    // Move over word characters
    while (pos > 0 && this.isWordChar(input[pos - 1])) pos--
    this.setCursorPosition(pos)
  }

  moveWordRight(): void {
    const input = this.getCurrentInput()
    let pos = this.getCursorPosition()
    if (pos >= input.length)
      return

    // Skip spaces
    while (pos < input.length && input[pos] === ' ') pos++
    // If at delimiters (non-space, non-word), skip them (e.g., '--')
    while (pos < input.length && input[pos] !== ' ' && !this.isWordChar(input[pos])) pos++
    // Move over word characters
    while (pos < input.length && this.isWordChar(input[pos])) pos++
    this.setCursorPosition(pos)
  }

  moveUp(): void {
    const input = this.getCurrentInput()
    const pos = this.getCursorPosition()
    const { line, col } = this.indexToLineCol(input, pos)
    if (line === 0)
      return
    this.setCursorPosition(this.lineColToIndex(input, line - 1, col))
  }

  moveDown(): void {
    const input = this.getCurrentInput()
    const pos = this.getCursorPosition()
    const lines = this.getLines(input)
    const { line, col } = this.indexToLineCol(input, pos)
    if (line >= lines.length - 1)
      return
    this.setCursorPosition(this.lineColToIndex(input, line + 1, col))
  }

  private isWordChar(ch: string): boolean {
    return /\w/.test(ch)
  }

  private getLines(input: string): string[] {
    return utilGetLines(input)
  }

  private indexToLineCol(input: string, index: number): { line: number, col: number } {
    return utilIndexToLineCol(input, index)
  }

  private lineColToIndex(input: string, line: number, col: number): number {
    return utilLineColToIndex(input, line, col)
  }
}
