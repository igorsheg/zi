export function splitTextLines(text: string): string[] {
  const lines = text.split("\n")
  if (text.endsWith("\n")) lines.pop()
  return lines
}

export function countTextLines(text: string): number {
  if (!text) return 0
  let lines = text.endsWith("\n") ? 0 : 1
  for (let index = 0; index < text.length; index++) {
    if (text.charCodeAt(index) === 10) lines++
  }
  return lines
}
