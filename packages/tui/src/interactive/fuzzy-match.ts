export interface FuzzyMatch {
  readonly matches: boolean
  readonly score: number
}

// Ported from pi-tui fuzzy matching at the repository pin in docs/reference-pins.md.
export function fuzzyMatch(query: string, text: string): FuzzyMatch {
  const queryLower = query.toLowerCase()
  const textLower = text.toLowerCase()

  const matchQuery = (normalizedQuery: string): FuzzyMatch => {
    if (normalizedQuery.length === 0) return { matches: true, score: 0 }
    if (normalizedQuery.length > textLower.length) return { matches: false, score: 0 }

    let queryIndex = 0
    let score = 0
    let lastMatchIndex = -1
    let consecutiveMatches = 0

    for (let index = 0; index < textLower.length && queryIndex < normalizedQuery.length; index++) {
      if (textLower[index] !== normalizedQuery[queryIndex]) continue
      const wordBoundary = index === 0 || /[\s\-_./:]/.test(textLower[index - 1] ?? "")
      if (lastMatchIndex === index - 1) {
        consecutiveMatches++
        score -= consecutiveMatches * 5
      } else {
        consecutiveMatches = 0
        if (lastMatchIndex >= 0) score += (index - lastMatchIndex - 1) * 2
      }
      if (wordBoundary) score -= 10
      score += index * 0.1
      lastMatchIndex = index
      queryIndex++
    }

    if (queryIndex < normalizedQuery.length) return { matches: false, score: 0 }
    if (normalizedQuery === textLower) score -= 100
    return { matches: true, score }
  }

  const direct = matchQuery(queryLower)
  if (direct.matches) return direct

  const alphaNumeric = queryLower.match(/^(?<letters>[a-z]+)(?<digits>[0-9]+)$/)
  const numericAlpha = queryLower.match(/^(?<digits>[0-9]+)(?<letters>[a-z]+)$/)
  const swapped = alphaNumeric
    ? `${alphaNumeric.groups?.digits ?? ""}${alphaNumeric.groups?.letters ?? ""}`
    : numericAlpha
      ? `${numericAlpha.groups?.letters ?? ""}${numericAlpha.groups?.digits ?? ""}`
      : ""
  if (!swapped) return direct

  const match = matchQuery(swapped)
  return match.matches ? { matches: true, score: match.score + 5 } : direct
}
