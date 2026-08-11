import stringWidth from "string-width"

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

// OpenTUI 0.4.5 expands tabs to this indicator in native text buffers.
export const openTuiTabIndicator = "  "
export const openTuiTabWidth = stringWidth(openTuiTabIndicator)

export function truncateToCells(text: string, maxWidth: number): string {
  if (maxWidth <= 0) return ""
  if (textWidth(text) <= maxWidth) return text
  if (maxWidth <= 3) return ".".repeat(maxWidth)

  let result = ""
  let width = 0
  const target = maxWidth - 3
  for (const { segment } of graphemes.segment(text)) {
    const segmentWidth = cellWidth(segment)
    if (width + segmentWidth > target) break
    result += segment
    width += segmentWidth
  }
  return `${result}...`
}

export function truncateMiddleToCells(text: string, maxWidth: number): string {
  if (maxWidth <= 0) return ""
  if (textWidth(text) <= maxWidth) return text
  if (maxWidth <= 3) return ".".repeat(maxWidth)

  const parts = [...graphemes.segment(text)]
  const contentWidth = maxWidth - 3
  const headTarget = Math.floor(contentWidth / 2)
  let head = ""
  let headWidth = 0
  let headEnd = 0
  while (headEnd < parts.length) {
    const segment = parts[headEnd]!.segment
    const width = cellWidth(segment)
    if (headWidth + width > headTarget) break
    head += segment
    headWidth += width
    headEnd++
  }

  let tail = ""
  let tailWidth = 0
  for (let index = parts.length - 1; index >= headEnd; index--) {
    const segment = parts[index]!.segment
    const width = cellWidth(segment)
    if (headWidth + tailWidth + width > contentWidth) break
    tail = segment + tail
    tailWidth += width
  }
  return `${head}...${tail}`
}

export interface CellLineWindow {
  readonly lines: readonly string[]
  readonly hasMore: boolean
}

export function wrapToCells(text: string, maxWidth: number): string[] {
  return [...wrappedLines(text, maxWidth)]
}

export function wrapHeadToCells(text: string, maxWidth: number, maxLines: number): CellLineWindow {
  if (maxLines <= 0) {
    const iterator = wrappedLines(text, maxWidth)
    return { lines: [], hasMore: !iterator.next().done }
  }

  const lines: string[] = []
  for (const line of wrappedLines(text, maxWidth)) {
    if (lines.length === maxLines) return { lines, hasMore: true }
    lines.push(line)
  }
  return { lines, hasMore: false }
}

export function wrapTailToCells(text: string, maxWidth: number, maxLines: number): CellLineWindow {
  if (maxLines <= 0) {
    const iterator = wrappedLines(text, maxWidth)
    return { lines: [], hasMore: !iterator.next().done }
  }

  const lines: string[] = []
  let count = 0
  let next = 0
  for (const line of wrappedLines(text, maxWidth)) {
    count++
    if (lines.length < maxLines) {
      lines.push(line)
    } else {
      lines[next] = line
      next = (next + 1) % maxLines
    }
  }
  if (count <= maxLines) return { lines, hasMore: false }
  return { lines: [...lines.slice(next), ...lines.slice(0, next)], hasMore: true }
}

export function textWidth(text: string): number {
  let width = 0
  for (const { segment } of graphemes.segment(text)) width += cellWidth(segment)
  return width
}

/** OpenTUI edit-buffer width: terminal cells, with every newline occupying one offset. */
export function promptTextWidth(text: string): number {
  let width = 0
  for (const { segment } of graphemes.segment(text)) width += segment === "\n" ? 1 : cellWidth(segment)
  return width
}

export function promptTextIndex(text: string, offset: number): number {
  if (offset <= 0) return 0
  let width = 0
  for (const part of graphemes.segment(text)) {
    const next = width + promptTextWidth(part.segment)
    if (next > offset) return part.index
    width = next
  }
  return text.length
}

export function promptTextSlice(text: string, start = 0, end = promptTextWidth(text)): string {
  return text.slice(promptTextIndex(text, start), promptTextIndex(text, end))
}

export function promptTextOffsetIsBoundary(text: string, offset: number): boolean {
  if (!Number.isInteger(offset) || offset < 0) return false
  let width = 0
  if (offset === 0) return true
  for (const { segment } of graphemes.segment(text)) {
    width += promptTextWidth(segment)
    if (width === offset) return true
    if (width > offset) return false
  }
  return false
}

function* wrappedLines(text: string, maxWidth: number): Generator<string> {
  if (maxWidth <= 0) return
  if (text.length === 0) {
    yield ""
    return
  }

  let line = ""
  let width = 0
  for (const { segment } of graphemes.segment(text)) {
    const segmentWidth = cellWidth(segment)
    if (width > 0 && width + segmentWidth > maxWidth) {
      yield line
      line = ""
      width = 0
    }
    line += segment
    width += segmentWidth
  }
  yield line
}

function cellWidth(segment: string): number {
  return segment === "\t" ? openTuiTabWidth : stringWidth(segment)
}
