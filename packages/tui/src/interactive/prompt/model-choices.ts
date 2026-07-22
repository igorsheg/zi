import type { ModelChoice } from "@zi/coding-agent"

export function configuredModelChoices(
  choices: readonly ModelChoice[],
  current: ModelChoice["model"] | undefined
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

export function sameModel(left: ModelChoice["model"], right: ModelChoice["model"] | undefined): boolean {
  return Boolean(right && left.provider === right.provider && left.id === right.id)
}
