import type { Api, Model, Models, ModelsRefreshOptions, ModelsRefreshResult } from "@earendil-works/pi-ai"

const maxConfigurationLookups = 4

export class ModelRegistry {
  readonly #providerConfiguration = new Map<string, Promise<boolean>>()
  readonly #configurationWaiters: Array<() => void> = []
  #activeConfigurationLookups = 0

  constructor(readonly models: Models) {}

  get(provider: string, modelId: string): Model<Api> | undefined {
    return this.models.getModel(provider, modelId)
  }

  find(reference: string): Model<Api> | undefined {
    const slash = reference.indexOf("/")
    if (slash > 0) return this.get(reference.slice(0, slash), reference.slice(slash + 1))
    const matches = this.list().filter(model => model.id === reference)
    return matches.length === 1 ? matches[0] : undefined
  }

  list(): readonly Model<Api>[] {
    return this.models.getModels()
  }

  refresh(options?: ModelsRefreshOptions): Promise<ModelsRefreshResult> {
    return this.models.refresh(options)
  }

  isConfigured(model: Model<Api>): Promise<boolean> {
    const current = this.#providerConfiguration.get(model.provider)
    if (current) return current

    const lookup = this.#lookupConfiguration(model)
    this.#providerConfiguration.set(model.provider, lookup)
    void lookup.then(
      () => this.#clearProviderLookup(model.provider, lookup),
      () => this.#clearProviderLookup(model.provider, lookup)
    )
    return lookup
  }

  async resolveConfiguration(models: readonly Model<Api>[]): Promise<readonly boolean[]> {
    const providers = new Map<string, { model: Model<Api>; indexes: number[] }>()
    for (const [index, model] of models.entries()) {
      const group = providers.get(model.provider)
      if (group) group.indexes.push(index)
      else providers.set(model.provider, { model, indexes: [index] })
    }

    const groups = [...providers.values()]
    const configured = Array.from({ length: models.length }, () => false)
    await Promise.all(
      groups.map(async group => {
        const available = await this.isConfigured(group.model)
        for (const index of group.indexes) configured[index] = available
      })
    )
    return configured
  }

  async #lookupConfiguration(model: Model<Api>): Promise<boolean> {
    await this.#acquireConfigurationSlot()
    try {
      return (await this.models.getAuth(model)) !== undefined
    } finally {
      this.#releaseConfigurationSlot()
    }
  }

  async #acquireConfigurationSlot(): Promise<void> {
    if (this.#activeConfigurationLookups >= maxConfigurationLookups) {
      await new Promise<void>(resolve => this.#configurationWaiters.push(resolve))
      return
    }
    this.#activeConfigurationLookups++
  }

  #releaseConfigurationSlot(): void {
    const next = this.#configurationWaiters.shift()
    if (next) next()
    else this.#activeConfigurationLookups--
  }

  #clearProviderLookup(provider: string, lookup: Promise<boolean>): void {
    if (this.#providerConfiguration.get(provider) === lookup) this.#providerConfiguration.delete(provider)
  }
}
