import type { AuthEvent, AuthInteraction, AuthPrompt, Credential, Models } from "@earendil-works/pi-ai"

import type { FileCredentialStore } from "./credential-store.js"

export type AuthenticationMethodType = "oauth" | "api_key"
export type AuthenticationPrompt = AuthPrompt
export type AuthenticationEvent = AuthEvent

export interface AuthenticationMethod {
  readonly providerId: string
  readonly providerName: string
  readonly type: AuthenticationMethodType
  readonly name: string
}

export interface AuthenticationInteraction {
  prompt(prompt: AuthPrompt): Promise<string>
  notify(event: AuthEvent): void
}

interface AuthenticationSettlement {
  readonly promise: Promise<void>
  resolve(): void
}

type AuthenticationState =
  | { readonly type: "idle" }
  | {
      readonly type: "logging_in"
      readonly operationId: number
      readonly providerId: string
      readonly method: AuthenticationMethodType
      readonly controller: AbortController
      readonly settled: AuthenticationSettlement
    }
  | {
      readonly type: "logging_out"
      readonly operationId: number
      readonly providerId: string
      readonly settled: AuthenticationSettlement
    }
  | { readonly type: "disposed" }

export class Authentication {
  readonly #models: Models
  readonly #credentials: FileCredentialStore
  #state: AuthenticationState = { type: "idle" }
  #nextOperationId = 0
  #disposal: Promise<void> = Promise.resolve()

  constructor(models: Models, credentials: FileCredentialStore) {
    this.#models = models
    this.#credentials = credentials
  }

  get isIdle(): boolean {
    return this.#state.type === "idle"
  }

  waitForIdle(): Promise<void> {
    switch (this.#state.type) {
      case "idle":
        return Promise.resolve()
      case "disposed":
        return this.#disposal
      case "logging_in":
      case "logging_out":
        return this.#state.settled.promise
      default:
        return assertNever(this.#state)
    }
  }

  methods(): readonly AuthenticationMethod[] {
    this.#assertNotDisposed()
    const methods: AuthenticationMethod[] = []
    const providers = this.#models.getProviders()
    if (providers.length > MAX_PROVIDERS) throw new Error(`Authentication provider count exceeds ${MAX_PROVIDERS}`)
    for (const provider of providers) {
      assertBoundedText("Provider id", provider.id, MAX_PROVIDER_ID_LENGTH)
      assertBoundedText("Provider name", provider.name, MAX_PRESENTATION_TEXT_LENGTH)
      if (provider.auth.oauth) {
        methods.push({
          providerId: provider.id,
          providerName: provider.name,
          type: "oauth",
          name: boundedText("Authentication method name", provider.auth.oauth.name, MAX_PRESENTATION_TEXT_LENGTH)
        })
      }
      if (provider.auth.apiKey?.login) {
        methods.push({
          providerId: provider.id,
          providerName: provider.name,
          type: "api_key",
          name: boundedText("Authentication method name", provider.auth.apiKey.name, MAX_PRESENTATION_TEXT_LENGTH)
        })
      }
    }
    return Object.freeze(
      methods
        .toSorted(
          (left, right) =>
            left.providerName.localeCompare(right.providerName) || methodOrder(left.type) - methodOrder(right.type)
        )
        .map(method => Object.freeze(method))
    )
  }

  stored() {
    this.#assertNotDisposed()
    return this.#credentials.list()
  }

  async login(
    providerId: string,
    type: AuthenticationMethodType,
    interaction: AuthenticationInteraction
  ): Promise<void> {
    this.#assertIdle()
    const provider = this.#models.getProvider(providerId)
    if (!provider) throw new Error(`Unknown authentication provider: ${providerId}`)
    const oauth = type === "oauth" ? provider.auth.oauth : undefined
    const apiKey = type === "api_key" ? provider.auth.apiKey : undefined
    if (!oauth && !apiKey?.login) {
      throw new Error(`${provider.name} does not support ${type === "oauth" ? "subscription" : "API-key"} login`)
    }

    const operationId = ++this.#nextOperationId
    const controller = new AbortController()
    const settled = createSettlement()
    this.#state = { type: "logging_in", operationId, providerId, method: type, controller, settled }
    let interactionCount = 0
    const admitInteraction = () => {
      this.#assertCurrentLogin(operationId)
      interactionCount++
      if (interactionCount > MAX_LOGIN_INTERACTIONS) {
        throw new Error(`Authentication interaction count exceeds ${MAX_LOGIN_INTERACTIONS}`)
      }
    }
    const callbacks: AuthInteraction = {
      signal: controller.signal,
      prompt: async (prompt: AuthPrompt) => {
        admitInteraction()
        const bounded = boundedPrompt(prompt)
        const answer = await interaction.prompt(bounded)
        this.#assertCurrentLogin(operationId)
        assertBoundedText("Authentication answer", answer, MAX_ANSWER_LENGTH)
        if (bounded.type === "select" && !bounded.options.some(option => option.id === answer)) {
          throw new Error("Authentication selection is not one of the offered options")
        }
        return answer
      },
      notify: (event: AuthEvent) => {
        admitInteraction()
        interaction.notify(boundedEvent(event))
      }
    }

    try {
      let credential: Credential
      if (oauth) credential = await oauth.login(callbacks)
      else if (apiKey?.login) credential = await apiKey.login(callbacks)
      else throw new Error("Authentication method disappeared during login")
      this.#assertCurrentLogin(operationId)
      if (credential.type !== type) {
        throw new Error(`Authentication method ${providerId}/${type} returned ${credential.type} credentials`)
      }
      await this.#credentials.modify(providerId, async () => {
        this.#assertCurrentLogin(operationId)
        return credential
      })
    } finally {
      if (this.#state.type === "logging_in" && this.#state.operationId === operationId) {
        this.#state = { type: "idle" }
      }
      settled.resolve()
    }
  }

  async logout(providerId: string): Promise<void> {
    this.#assertIdle()
    const operationId = ++this.#nextOperationId
    const settled = createSettlement()
    this.#state = { type: "logging_out", operationId, providerId, settled }
    try {
      await this.#credentials.delete(providerId)
    } finally {
      if (this.#state.type === "logging_out" && this.#state.operationId === operationId) {
        this.#state = { type: "idle" }
      }
      settled.resolve()
    }
  }

  cancel(): Promise<void> {
    switch (this.#state.type) {
      case "idle":
      case "disposed":
        return Promise.resolve()
      case "logging_in":
        this.#state.controller.abort()
        return this.#state.settled.promise
      case "logging_out":
        return this.#state.settled.promise
      default:
        return assertNever(this.#state)
    }
  }

  async dispose(): Promise<void> {
    const state = this.#state
    if (state.type === "disposed") {
      await this.#disposal
      return
    }
    let settled: Promise<void> = Promise.resolve()
    if (state.type === "logging_in") {
      state.controller.abort()
      settled = state.settled.promise
    } else if (state.type === "logging_out") {
      settled = state.settled.promise
    }
    this.#state = { type: "disposed" }
    this.#disposal = settled
    await settled
  }

  #assertNotDisposed(): void {
    if (this.#state.type === "disposed") throw new Error("Authentication is disposed")
  }

  #assertIdle(): void {
    if (this.#state.type === "disposed") throw new Error("Authentication is disposed")
    if (this.#state.type !== "idle") throw new Error("Another authentication operation is active")
  }

  #assertCurrentLogin(operationId: number): void {
    if (
      this.#state.type !== "logging_in" ||
      this.#state.operationId !== operationId ||
      this.#state.controller.signal.aborted
    ) {
      throw new Error("Authentication login was cancelled or superseded")
    }
  }
}

const MAX_PROVIDERS = 256
const MAX_PROVIDER_ID_LENGTH = 128
const MAX_PRESENTATION_TEXT_LENGTH = 8_192
const MAX_LOGIN_INTERACTIONS = 128
const MAX_SELECT_OPTIONS = 128
const MAX_ANSWER_LENGTH = 65_536

function boundedPrompt(prompt: AuthPrompt): AuthPrompt {
  const message = boundedText("Authentication prompt", prompt.message, MAX_PRESENTATION_TEXT_LENGTH)
  const signal = prompt.signal ? { signal: prompt.signal } : {}
  switch (prompt.type) {
    case "text":
    case "secret":
    case "manual_code":
      return Object.freeze({
        type: prompt.type,
        message,
        ...(prompt.placeholder
          ? { placeholder: boundedText("Authentication placeholder", prompt.placeholder, MAX_PRESENTATION_TEXT_LENGTH) }
          : {}),
        ...signal
      })
    case "select": {
      if (prompt.options.length > MAX_SELECT_OPTIONS) {
        throw new Error(`Authentication option count exceeds ${MAX_SELECT_OPTIONS}`)
      }
      const options = prompt.options.map(option =>
        Object.freeze({
          id: boundedText("Authentication option id", option.id, MAX_PROVIDER_ID_LENGTH),
          label: boundedText("Authentication option label", option.label, MAX_PRESENTATION_TEXT_LENGTH),
          ...(option.description
            ? {
                description: boundedText(
                  "Authentication option description",
                  option.description,
                  MAX_PRESENTATION_TEXT_LENGTH
                )
              }
            : {})
        })
      )
      return Object.freeze({ type: "select", message, options: Object.freeze(options), ...signal })
    }
    default:
      return assertNever(prompt)
  }
}

function boundedEvent(event: AuthEvent): AuthEvent {
  switch (event.type) {
    case "auth_url":
      return Object.freeze({
        type: "auth_url",
        url: boundedUrl("Authentication URL", event.url),
        ...(event.instructions
          ? {
              instructions: boundedText("Authentication instructions", event.instructions, MAX_PRESENTATION_TEXT_LENGTH)
            }
          : {})
      })
    case "device_code":
      return Object.freeze({
        type: "device_code",
        userCode: boundedText("Authentication device code", event.userCode, MAX_PRESENTATION_TEXT_LENGTH),
        verificationUri: boundedUrl("Authentication verification URL", event.verificationUri),
        ...(event.intervalSeconds === undefined ? {} : { intervalSeconds: event.intervalSeconds }),
        ...(event.expiresInSeconds === undefined ? {} : { expiresInSeconds: event.expiresInSeconds })
      })
    case "progress":
      return Object.freeze({
        type: "progress",
        message: boundedText("Authentication progress", event.message, MAX_PRESENTATION_TEXT_LENGTH)
      })
    case "info":
      return Object.freeze({
        type: "info",
        message: boundedText("Authentication info", event.message, MAX_PRESENTATION_TEXT_LENGTH),
        ...(event.links
          ? {
              links: Object.freeze(
                event.links.map(item =>
                  Object.freeze({
                    url: boundedUrl("Authentication info URL", item.url),
                    ...(item.label
                      ? { label: boundedText("Authentication info label", item.label, MAX_PRESENTATION_TEXT_LENGTH) }
                      : {})
                  })
                )
              )
            }
          : {})
      })
    default:
      return assertNever(event)
  }
}

function boundedUrl(label: string, value: string): string {
  assertBoundedText(label, value, MAX_PRESENTATION_TEXT_LENGTH)
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0
    if (codePoint <= 31 || codePoint === 127) throw new Error(`${label} contains control characters`)
  }
  const protocol = new URL(value).protocol
  if (protocol !== "http:" && protocol !== "https:") throw new Error(`${label} must use http or https`)
  return value
}

function boundedText(label: string, value: string, maximum: number): string {
  assertBoundedText(label, value, maximum)
  return value
}

function assertBoundedText(label: string, value: string, maximum: number): void {
  if (typeof value !== "string" || value.length > maximum) throw new Error(`${label} exceeds ${maximum} characters`)
}

function createSettlement(): AuthenticationSettlement {
  let resolvePromise!: () => void
  const promise = new Promise<void>(resolve => {
    resolvePromise = resolve
  })
  return { promise, resolve: resolvePromise }
}

function assertNever(value: never): never {
  throw new Error(`Unhandled authentication state: ${String(value)}`)
}

function methodOrder(type: AuthenticationMethodType): number {
  return type === "oauth" ? 0 : 1
}
