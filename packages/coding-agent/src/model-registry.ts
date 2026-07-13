import type { Api, Model, Models } from "@earendil-works/pi-ai"

export class ModelRegistry {
  constructor(readonly models: Models) {}

  get(provider: string, modelId: string): Model<Api> | undefined {
    return this.models.getModel(provider, modelId)
  }

  list(): readonly Model<Api>[] {
    return this.models.getModels()
  }

  async isConfigured(model: Model<Api>): Promise<boolean> {
    return (await this.models.getAuth(model)) !== undefined
  }
}
