export const maxToolErrorScalars = 4_096

export function boundToolText(value: string, limit = maxToolErrorScalars): string {
  const normalized = value.replace(/\r\n?/g, "\n")
  let safe = ""
  for (const character of normalized) {
    const code = character.codePointAt(0) ?? 0
    if (code === 0x09 || code === 0x0a || (code >= 0x20 && (code < 0x7f || code > 0x9f))) safe += character
  }
  const scalars = Array.from(safe)
  return scalars.length <= limit ? safe : `${scalars.slice(0, limit - 1).join("")}…`
}

export function isBoundedToolText(value: unknown, limit = maxToolErrorScalars): value is string {
  return typeof value === "string" && Array.from(value).length <= limit
}
