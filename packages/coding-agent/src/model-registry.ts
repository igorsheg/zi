import type { Api, Model, Models } from "@earendil-works/pi-ai"

export class ModelRegistry {
  constructor(readonly models: Models) {}

  get(provider: string, modelId: string): Model<Api> | undefined {
    return this.models.getModel(provider, modelId)
  }

  find(reference: string): Model<Api> | undefined {
    const slash = reference.indexOf("/")
    if (slash > 0) return this.get(reference.slice(0, slash), reference.slice(slash + 1))
    const matches = this.list().filter((model) => model.id === reference)
    return matches.length === 1 ? matches[0] : undefined
  }

  list(): readonly Model<Api>[] {
    return this.models.getModels()
  }

  async isConfigured(model: Model<Api>): Promise<boolean> {
    return (await this.models.getAuth(model)) !== undefined
  }
}
