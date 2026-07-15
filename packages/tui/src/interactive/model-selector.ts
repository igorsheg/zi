import type { ModelChoice } from "@openzi/coding-agent"

export function configuredModelChoices(
  choices: readonly ModelChoice[],
  current: ModelChoice["model"]
): readonly ModelChoice[] {
  return choices
    .filter(choice => choice.configured)
    .toSorted((left, right) => {
      const leftCurrent = sameModel(left.model, current)
      const rightCurrent = sameModel(right.model, current)
      if (leftCurrent !== rightCurrent) return leftCurrent ? -1 : 1
      return left.model.provider.localeCompare(right.model.provider)
    })
}

export function exactModelChoice(reference: string, choices: readonly ModelChoice[]): ModelChoice | undefined {
  const normalized = reference.trim().toLowerCase()
  if (!normalized) return undefined

  const canonical = choices.filter(choice => `${choice.model.provider}/${choice.model.id}`.toLowerCase() === normalized)
  if (canonical.length === 1) return canonical[0]
  if (canonical.length > 1) return undefined

  const slash = reference.indexOf("/")
  if (slash !== -1) {
    const provider = reference.slice(0, slash).trim().toLowerCase()
    const id = reference
      .slice(slash + 1)
      .trim()
      .toLowerCase()
    if (provider && id) {
      const qualified = choices.filter(
        choice => choice.model.provider.toLowerCase() === provider && choice.model.id.toLowerCase() === id
      )
      if (qualified.length === 1) return qualified[0]
      if (qualified.length > 1) return undefined
    }
  }

  const byId = choices.filter(choice => choice.model.id.toLowerCase() === normalized)
  return byId.length === 1 ? byId[0] : undefined
}

export function filterModelChoices(choices: readonly ModelChoice[], query: string): readonly ModelChoice[] {
  const tokens = query
    .trim()
    .split(/[\s/]+/)
    .filter(token => token.length > 0)
  if (tokens.length === 0) return choices

  return choices
    .map((choice, index) => {
      const text = modelSearchText(choice)
      let score = 0
      for (const token of tokens) {
        const match = fuzzyMatch(token, text)
        if (!match.matches) return undefined
        score += match.score
      }
      return { choice, index, score }
    })
    .filter(result => result !== undefined)
    .toSorted((left, right) => left.score - right.score || left.index - right.index)
    .map(result => result.choice)
}

export function sameModel(left: ModelChoice["model"], right: ModelChoice["model"]): boolean {
  return left.provider === right.provider && left.id === right.id
}

// Ported from pi-tui fuzzy matching at the repository pin in docs/reference-pins.md.
function fuzzyMatch(query: string, text: string): { matches: boolean; score: number } {
  const queryLower = query.toLowerCase()
  const textLower = text.toLowerCase()

  const matchQuery = (normalizedQuery: string): { matches: boolean; score: number } => {
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

function modelSearchText(choice: ModelChoice): string {
  const { id, name, provider } = choice.model
  return `${provider} ${provider}/${id} ${provider} ${id}${name ? ` ${name}` : ""}`
}
