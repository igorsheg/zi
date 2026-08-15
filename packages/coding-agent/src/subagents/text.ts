export function clipUtf8(
  text: string,
  maxBytes: number
): { readonly text: string; readonly originalBytes: number; readonly omittedBytes: number } {
  const encoded = Buffer.from(text)
  const originalBytes = encoded.byteLength
  if (originalBytes <= maxBytes) return { text, originalBytes, omittedBytes: 0 }
  let end = Math.max(0, Math.min(maxBytes, originalBytes))
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) end--
  return { text: encoded.subarray(0, end).toString("utf8"), originalBytes, omittedBytes: originalBytes - end }
}
