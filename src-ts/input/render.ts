import type { AutoSuggestOptions } from './auto-suggest'
import process from 'node:process'
import { displayWidth, truncateToWidth, visibleLength, wcwidth } from './ansi'
import { renderHighlighted } from './highlighting'

// Remember how many lines the last grouped suggestion render used, so we can
// clear exactly that many lines on the next render. This prevents duplicated
// blocks when the terminal is small or the list shrinks.
let lastGroupedRenderHeight = 0
// Track how many lines the last flat suggestion render used
let lastFlatRenderHeight = 0

// Truncate a string to a given display width while preserving ANSI escape sequences.
// This avoids cutting in the middle of an escape and prevents style bleed by keeping codes intact.
function truncateAnsiToWidth(text: string, maxWidth: number): string {
  if (maxWidth <= 0)
    return ''
  let out = ''
  let width = 0
  // Track last index in output that contributed to visible width
  let lastVisibleOutIndex = -1
  for (let i = 0; i < text.length;) {
    const ch = text[i]
    if (ch === '\x1B' && text[i + 1] === '[') {
      // Copy the entire CSI sequence
      let j = i + 2
      while (j < text.length && /[0-9;]/.test(text[j])) j++
      if (j < text.length) {
        // Include final command byte
        out += text.slice(i, j + 1)
        i = j + 1
        continue
      }
      // Malformed sequence; stop processing further
      break
    }
    // Handle code points
    const code = text.codePointAt(i) as number
    const cp = String.fromCodePoint(code)
    const w = wcwidth(cp)
    if (width + w > maxWidth) {
      // If we're at the edge and the next character in the source is a closing bracket
      // for a selected token, prefer ending with the bracket to avoid awkward truncation.
      const nextCode = text.codePointAt(i) as number
      const nextChar = String.fromCodePoint(nextCode)
      if (nextChar === ']' && lastVisibleOutIndex >= 0) {
        out = `${out.slice(0, lastVisibleOutIndex)}]`
      }
      break
    }
    out += cp
    width += w
    if (w > 0)
      lastVisibleOutIndex = out.length
    i += cp.length
  }
  return out
}

// Render single-line input when the prompt is already written (shell mode)
export function renderSingleLineShell(
  stdout: NodeJS.WriteStream,
  input: string,
  options: AutoSuggestOptions,
  visiblePromptLastLen: number,
  cursorColumn: number,
  showInline: boolean,
  inlineSuggestion: string,
  reverseStatus: string,
  prevInputLength: number,
): void {
  const inputStartColumn = visiblePromptLastLen + 1
  const renderedSingle = options.syntaxHighlight
    ? renderHighlighted(input, options.syntaxColors, options.highlightColor)
    : input
  // Move to start of input, clear to end of line, and write input
  stdout.write(`\x1B[${inputStartColumn}G\x1B[K${renderedSingle}\x1B[0m`)
  if (reverseStatus) {
    const dim = options.highlightColor ?? '\x1B[90m'
    stdout.write(` ${dim}${reverseStatus}\x1B[0m`)
  }

  if (showInline && inlineSuggestion) {
    const cols = process.stdout.columns ?? 80
    // compute used width on the last line: prompt + input + optional space+status
    let used = visiblePromptLastLen + displayWidth(input)
    if (reverseStatus)
      used += 1 + displayWidth(reverseStatus)
    const available = Math.max(0, cols - used)
    if (available > 0) {
      const truncated = truncateToWidth(inlineSuggestion, available)
      if (truncated) {
        const dim = options.suggestionColor ?? '\x1B[90m'
        stdout.write(`${dim}${truncated}\x1B[0m`)
      }
    }
  }
  // Clear any remaining characters from previous input
  if (prevInputLength > input.length) {
    const remaining = prevInputLength - input.length
    stdout.write(' '.repeat(remaining))
    stdout.write(`\x1B[${cursorColumn}G`)
  }
  // Explicitly set cursor position after updates
  stdout.write(`\x1B[${cursorColumn}G`)
}

// Render single-line input with prompt (isolated mode)
export function renderSingleLineIsolated(
  stdout: NodeJS.WriteStream,
  prompt: string,
  input: string,
  options: AutoSuggestOptions,
  visiblePromptLastLen: number,
  cursorColumn: number,
  showInline: boolean,
  inlineSuggestion: string,
  reverseStatus?: string,
): void {
  const renderedSingle = options.syntaxHighlight
    ? renderHighlighted(input, options.syntaxColors, options.highlightColor)
    : input
  // 1) Clear current line and write prompt
  stdout.write(`\r\x1B[2K${prompt}`)
  // 2) Move to start of input area (after prompt), clear to end, then write input
  const inputStartColumn = visiblePromptLastLen + 1
  stdout.write(`\x1B[${inputStartColumn}G\x1B[K${renderedSingle}\x1B[0m`)
  if (reverseStatus) {
    const dim = options.highlightColor ?? '\x1B[90m'
    stdout.write(` ${dim}${reverseStatus}\x1B[0m`)
  }
  if (showInline && inlineSuggestion) {
    const cols = process.stdout.columns ?? 80
    let used = visiblePromptLastLen + displayWidth(input)
    if (reverseStatus)
      used += 1 + displayWidth(reverseStatus)
    const available = Math.max(0, cols - used)
    if (available > 0) {
      const truncated = truncateToWidth(inlineSuggestion, available)
      if (truncated) {
        const dim = options.suggestionColor ?? '\x1B[90m'
        stdout.write(`${dim}${truncated}\x1B[0m`)
      }
    }
  }
  stdout.write(`\x1B[${cursorColumn}G`)
}

// Render multi-line input with continuation prompts and position cursor
export function renderMultiLineIsolated(
  stdout: NodeJS.WriteStream,
  prompt: string,
  input: string,
  continuationPrompt: string,
  options: AutoSuggestOptions,
  cursorPosition: number,
  visiblePromptLastLen: number,
  reverseStatus: string,
): void {
  const lines = input.split('\n')
  const visibleContLen = visibleLength(continuationPrompt)
  const firstLineRendered = options.syntaxHighlight
    ? renderHighlighted(lines[0], options.syntaxColors, options.highlightColor)
    : lines[0]
  // Clear current line, then write first line (prompt + input)
  stdout.write(`\r\x1B[2K${prompt}${firstLineRendered}\x1B[0m`)
  if (reverseStatus) {
    const dim = options.highlightColor ?? '\x1B[90m'
    stdout.write(` ${dim}${reverseStatus}\x1B[0m`)
  }
  for (let i = 1; i < lines.length; i++) {
    const rendered = options.syntaxHighlight ? renderHighlighted(lines[i], options.syntaxColors, options.highlightColor) : lines[i]
    stdout.write(`\n\x1B[2K${continuationPrompt}${rendered}\x1B[0m`)
  }
  // Compute target cursor row/col
  let remaining = cursorPosition
  let lineIndex = 0
  for (let i = 0; i < lines.length; i++) {
    const len = lines[i].length
    if (remaining <= len) {
      lineIndex = i
      break
    }
    remaining -= (len + 1)
    lineIndex = i + 1
  }
  const colInLine = remaining
  const totalLines = lines.length
  const linesUp = (totalLines - 1) - lineIndex
  if (linesUp > 0)
    stdout.write(`\x1B[${linesUp}A`)
  const baseLen = lineIndex === 0 ? visiblePromptLastLen : visibleContLen
  const targetCol = baseLen + colInLine + 1
  stdout.write(`\x1B[${targetCol}G`)
}

export function renderSuggestionList(
  stdout: NodeJS.WriteStream,
  suggestions: string[],
  selectedIndex: number,
  options: AutoSuggestOptions,
  hadSuggestionsLastRender: boolean,
): boolean {
  if (suggestions.length > 0) {
    const reset = '\x1B[0m'
    // Selected item style: inverted colors for clarity (match grouped style)
    const selectedBg = '\x1B[47m' // white background
    const selectedFg = '\x1B[30m' // black text
    const cols = process.stdout.columns ?? 80

    const items = suggestions.slice(0, options.maxSuggestions ?? 10)
    const lines = items.map((s, i) => {
      const label = truncateAnsiToWidth(s, cols)
      if (i === selectedIndex)
        return `${selectedFg}${selectedBg}${label}${reset}`
      return label
    })

    // Save cursor, clear previous render blocks (both flat and grouped), then print the new block
    stdout.write(`\x1B[s`)
    if (lastGroupedRenderHeight > 0) {
      for (let i = 0; i < lastGroupedRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastGroupedRenderHeight}A`)
      lastGroupedRenderHeight = 0
    }
    if (lastFlatRenderHeight > 0) {
      for (let i = 0; i < lastFlatRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastFlatRenderHeight}A`)
    }

    // Write new block below current line, one suggestion per line
    for (const line of lines)
      stdout.write(`\n\x1B[2K${line}`)
    stdout.write(`\x1B[0m`)
    stdout.write(`\x1B[u`)

    lastFlatRenderHeight = lines.length
    return true
  }
  else if (hadSuggestionsLastRender) {
    stdout.write(`\x1B[s`)
    // Clear both blocks if any remnants exist
    if (lastGroupedRenderHeight > 0) {
      for (let i = 0; i < lastGroupedRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastGroupedRenderHeight}A`)
      lastGroupedRenderHeight = 0
    }
    if (lastFlatRenderHeight > 0) {
      for (let i = 0; i < lastFlatRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastFlatRenderHeight}A`)
      lastFlatRenderHeight = 0
    }
    else {
      stdout.write(`\n\x1B[2K`)
    }
    stdout.write(`\x1B[u`)
    return false
  }
  return false
}

/**
 * Render grouped suggestion lists with headers. Backward-compatible helper
 * that mirrors the API of renderSuggestionList but takes grouped data and a
 * single selectedIndex across all items (headers are not selectable).
 */
export function renderGroupedSuggestionList(
  stdout: NodeJS.WriteStream,
  groups: Array<{ title: string, items: Array<string | { text: string }> }>,
  selectedIndex: number,
  options: AutoSuggestOptions,
  hadSuggestionsLastRender: boolean,
): boolean {
  // Normalize/merge duplicate groups defensively (e.g., repeated 'binaries')
  const normalizeTitle = (t: string) => (t || '').trim().toLowerCase()
  const getText = (v: string | { text: string }) => typeof v === 'string' ? v : v.text
  const mergedGroups: Array<{ title: string, items: Array<string | { text: string }> }> = []
  const indexByNorm = new Map<string, number>()
  for (const g of groups) {
    const norm = normalizeTitle(g.title)
    const existingIdx = indexByNorm.get(norm)
    if (existingIdx === undefined) {
      // Copy and dedupe items for a new group
      const seen = new Set<string>()
      const items: Array<string | { text: string }> = []
      for (const it of (g.items || [])) {
        const key = getText(it)
        if (!key)
          continue
        if (!seen.has(key)) {
          seen.add(key)
          items.push(it)
        }
      }
      mergedGroups.push({ title: (g.title || '').trim(), items })
      indexByNorm.set(norm, mergedGroups.length - 1)
    }
    else {
      // Merge into existing with dedupe
      const existing = mergedGroups[existingIdx]
      const seen = new Set(existing.items.map(getText))
      for (const it of (g.items || [])) {
        const key = getText(it)
        if (!key)
          continue
        if (!seen.has(key)) {
          seen.add(key)
          existing.items.push(it)
        }
      }
    }
  }

  // Build per-group labels upfront from merged groups
  const labelsByGroup: string[][] = mergedGroups.map(g => g.items.map(getText))
  const nonEmptyGroupIndexes: number[] = []
  for (let i = 0; i < labelsByGroup.length; i++) {
    if (labelsByGroup[i].length > 0)
      nonEmptyGroupIndexes.push(i)
  }

  // Nothing to render
  if (nonEmptyGroupIndexes.length === 0) {
    if (hadSuggestionsLastRender) {
      stdout.write(`\x1B[s`)
      stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[u`)
    }
    return false
  }

  // Sort items within each group for a stable alphabetical layout
  for (let gi = 0; gi < labelsByGroup.length; gi++)
    labelsByGroup[gi] = labelsByGroup[gi].slice().sort((a, b) => a.localeCompare(b))

  // Build flattened view over ALL items (no maxSuggestions cap in grouped mode)
  const flat: Array<{ group: number, idx: number, label: string }> = []
  for (let gi = 0; gi < mergedGroups.length; gi++) {
    const labels = labelsByGroup[gi]
    for (let i = 0; i < labels.length; i++)
      flat.push({ group: gi, idx: i, label: labels[i] })
  }

  if (flat.length > 0) {
    // const _reset = '\x1B[0m'
    const selectedBg = '\x1B[47m' // white background
    const selectedFg = '\x1B[30m' // black text

    // Build multi-line output: header per group, items in columns under it
    let out = ''
    let seen = 0
    const cols = process.stdout.columns ?? 80
    const canMeasureRows = !!(process.stdout.isTTY && typeof (process.stdout as any).rows === 'number')
    const rowsAvail = canMeasureRows ? Math.max(0, ((process.stdout as any).rows as number) - 3) : 0
    const gap = 2
    let producedLines = 0
    let truncated = false

    for (let gi = 0; gi < mergedGroups.length; gi++) {
      if (truncated)
        break
      const g = mergedGroups[gi]
      const labels = labelsByGroup[gi]
      if (labels.length <= 0)
        continue

      // Header: UPPERCASE, styled italic and dim, with trailing colon
      const italic = '\x1B[3m'
      const dim = '\x1B[2m'
      const reset = '\x1B[0m'
      const header = `\n\x1B[2K${dim}${italic}${g.title.toUpperCase()}:${reset}`

      // If adding the header would exceed available rows, mark truncated
      if (rowsAvail > 0 && producedLines + 1 > rowsAvail) {
        truncated = true
        break
      }
      out += header
      producedLines += 1

      // Uniform column width based on max label display width
      let maxLen = 0
      for (const s of labels)
        maxLen = Math.max(maxLen, displayWidth(s))
      const colWidth = Math.max(1, maxLen + 1) // +1 minimal spacing inside cell
      const columns = Math.max(1, Math.floor((cols) / (colWidth + gap)))
      const rows = Math.max(1, Math.ceil(labels.length / columns))

      for (let r = 0; r < rows; r++) {
        if (rowsAvail > 0 && producedLines + 1 > rowsAvail) {
          truncated = true
          break
        }
        let line = '\n\x1B[2K'
        for (let c = 0; c < columns; c++) {
          const idx = r * columns + c
          if (idx >= labels.length)
            break
          const label = labels[idx]
          const isSelected = seen === selectedIndex
          // Do not bracket selected; keep plain label
          const shown = label
          const padLen = Math.max(0, colWidth - displayWidth(shown))
          const cellContent = `${shown}${' '.repeat(padLen)}`
          if (isSelected) {
            line += `${selectedFg}${selectedBg}${cellContent}${reset}`
          }
          else {
            // Non-selected items should not be dimmed
            line += `${cellContent}`
          }
          // gap between columns
          if (c < columns - 1)
            line += ' '.repeat(gap)
          seen++
        }
        out += line
        producedLines += 1
      }
    }

    // If truncated due to lack of vertical space, append an indicator line
    if (truncated && canMeasureRows) {
      if (rowsAvail === 0 || producedLines < rowsAvail) {
        out += `\n\x1B[2K... more`
        producedLines += 1
      }
    }

    if (!out) {
      // Should not happen if flat.length > 0, but guard anyway
      return false
    }

    // Ensure content fits terminal width per line (ANSI-aware)
    const lines = out.split('\n').map(l => truncateAnsiToWidth(l, cols))

    // Clear the previous render blocks completely (both grouped and flat)
    stdout.write(`\x1B[s`)
    if (lastGroupedRenderHeight > 0) {
      for (let i = 0; i < lastGroupedRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      // Move cursor back up
      stdout.write(`\x1B[${lastGroupedRenderHeight}A`)
      lastGroupedRenderHeight = 0
    }
    if (lastFlatRenderHeight > 0) {
      for (let i = 0; i < lastFlatRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastFlatRenderHeight}A`)
      lastFlatRenderHeight = 0
    }

    // Write the new block
    stdout.write(lines.join('\n'))
    stdout.write('\x1B[0m')
    stdout.write(`\x1B[u`)

    // Store height for next render: count non-empty lines we printed below the prompt
    lastGroupedRenderHeight = lines.reduce((acc, l) => acc + (l.length > 0 ? 1 : 0), 0)
    return true
  }
  else if (hadSuggestionsLastRender) {
    stdout.write(`\x1B[s`)
    // Clear both blocks if any remnants exist
    if (lastFlatRenderHeight > 0) {
      for (let i = 0; i < lastFlatRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastFlatRenderHeight}A`)
      lastFlatRenderHeight = 0
    }
    if (lastGroupedRenderHeight > 0) {
      for (let i = 0; i < lastGroupedRenderHeight; i++)
        stdout.write(`\n\x1B[2K`)
      stdout.write(`\x1B[${lastGroupedRenderHeight}A`)
      lastGroupedRenderHeight = 0
    }
    else {
      stdout.write(`\n\x1B[2K`)
    }
    stdout.write(`\x1B[u`)
    return false
  }
  return false
}
