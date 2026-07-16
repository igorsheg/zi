const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

export function truncateToCells(text: string, maxWidth: number): string {
  if (maxWidth <= 0) return ""
  if (textWidth(text) <= maxWidth) return text
  if (maxWidth <= 3) return ".".repeat(maxWidth)

  let result = ""
  let width = 0
  const target = maxWidth - 3
  for (const { segment } of graphemes.segment(text)) {
    const segmentWidth = graphemeWidth(segment)
    if (width + segmentWidth > target) break
    result += segment
    width += segmentWidth
  }
  return `${result}...`
}

function textWidth(text: string): number {
  let width = 0
  for (const { segment } of graphemes.segment(text)) width += graphemeWidth(segment)
  return width
}

function graphemeWidth(segment: string): number {
  if (/^[\p{Control}\p{Mark}\p{Default_Ignorable_Code_Point}]+$/u.test(segment)) return 0
  if (/\p{Extended_Pictographic}/u.test(segment) || /^\p{Regional_Indicator}{2}$/u.test(segment)) return 2
  const codePoint = segment.codePointAt(0) ?? 0
  return isWideCodePoint(codePoint) ? 2 : 1
}

function isWideCodePoint(codePoint: number): boolean {
  return (
    codePoint >= 0x1100 &&
    (codePoint <= 0x115f ||
      codePoint === 0x2329 ||
      codePoint === 0x232a ||
      (codePoint >= 0x2e80 && codePoint <= 0xa4cf && codePoint !== 0x303f) ||
      (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
      (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
      (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
      (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
      (codePoint >= 0xff00 && codePoint <= 0xff60) ||
      (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
      (codePoint >= 0x20000 && codePoint <= 0x3fffd))
  )
}
