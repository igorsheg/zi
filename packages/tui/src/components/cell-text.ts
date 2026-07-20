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
