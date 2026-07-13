export interface PromptResources {
  systemPrompt?: string
  appendSystemPrompt: readonly string[]
  contextFiles: readonly string[]
}

export interface ResourceLoader {
  reload(): Promise<void>
  get(): PromptResources
}

export class DefaultResourceLoader implements ResourceLoader {
  #resources: PromptResources

  constructor(resources: Partial<PromptResources> = {}) {
    this.#resources = {
      appendSystemPrompt: resources.appendSystemPrompt ?? [],
      contextFiles: resources.contextFiles ?? [],
      ...(resources.systemPrompt === undefined ? {} : { systemPrompt: resources.systemPrompt }),
    }
  }

  async reload(): Promise<void> {}

  get(): PromptResources {
    return this.#resources
  }
}
