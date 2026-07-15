import type { AuthenticationMethod, BuiltinSlashCommand, ModelChoice, StoredCredential } from "@openzi/coding-agent"

import { glyphs } from "../glyphs.js"
import { sameModel } from "./model-selector.js"
import type { PickerFrame } from "./stores/picker-stack.js"

export const promptPickerFrameIds = {
  commands: "commands",
  models: "models",
  authProviders: "auth-providers",
  authMethods: "auth-methods",
  authOptions: "auth-options",
  logoutProviders: "logout-providers"
} as const

export function commandFrame(commands: readonly BuiltinSlashCommand[]): PickerFrame {
  return {
    id: promptPickerFrameIds.commands,
    title: "",
    filter: "none",
    rows: commands.map(command => ({
      id: command.name,
      label: `/${command.name}`,
      ...(command.argumentHint ? { detail: command.argumentHint } : {}),
      metadata: command.description,
      searchText: `${command.name} ${command.description} ${command.argumentHint ?? ""}`
    }))
  }
}

export function authProviderFrame(methods: readonly AuthenticationMethod[]): PickerFrame {
  const providers = new Map<string, AuthenticationMethod>()
  for (const method of methods) if (!providers.has(method.providerId)) providers.set(method.providerId, method)
  return {
    id: promptPickerFrameIds.authProviders,
    title: "Log in",
    filter: "fuzzy",
    emptyText: "No matching providers",
    rows: [...providers.values()].map(method => ({
      id: method.providerId,
      label: method.providerName,
      detail: `[${method.providerId}]`,
      searchText: `${method.providerId} ${method.providerName}`
    }))
  }
}

export function authMethodFrame(methods: readonly AuthenticationMethod[]): PickerFrame {
  return {
    id: promptPickerFrameIds.authMethods,
    title: methods[0]?.providerName ?? "Login method",
    filter: "fuzzy",
    emptyText: "No matching login methods",
    rows: methods.map(method => ({
      id: authenticationMethodId(method),
      label: method.name,
      detail: method.type === "oauth" ? "[subscription]" : "[API key]",
      searchText: `${method.name} ${method.type}`
    }))
  }
}

export function authenticationMethodId(method: AuthenticationMethod): string {
  return `${method.providerId}:${method.type}`
}

export function authOptionFrame(
  options: readonly { readonly id: string; readonly label: string; readonly description?: string }[]
): PickerFrame {
  return {
    id: promptPickerFrameIds.authOptions,
    title: "Choose",
    filter: "fuzzy",
    emptyText: "No matching options",
    rows: options.map(option => ({
      id: option.id,
      label: option.label,
      ...(option.description ? { metadata: option.description } : {}),
      searchText: `${option.label} ${option.description ?? ""}`
    }))
  }
}

export function logoutFrame(credentials: readonly StoredCredential[]): PickerFrame {
  return {
    id: promptPickerFrameIds.logoutProviders,
    title: "Log out",
    filter: "fuzzy",
    emptyText: "No matching stored credentials",
    rows: credentials.map(credential => ({
      id: credential.providerId,
      label: credential.providerId,
      detail: credential.type === "oauth" ? "[subscription]" : "[API key]",
      searchText: credential.providerId
    }))
  }
}

export function modelFrame(
  choices: readonly ModelChoice[],
  current: ModelChoice["model"] | undefined,
  emptyText = "No matching models"
): PickerFrame {
  return {
    id: promptPickerFrameIds.models,
    title: "Models",
    hint: "Only showing models from configured providers. Use /login to add providers.",
    filter: "fuzzy",
    emptyText,
    rows: choices.map(choice => ({
      id: modelChoiceId(choice),
      label: choice.model.id,
      detail: `[${choice.model.provider}]`,
      ...(sameModel(choice.model, current) ? { metadata: glyphs.check } : {}),
      searchText: modelSearchText(choice)
    })),
    ...(current && choices.some(choice => sameModel(choice.model, current)) ? { selectedId: modelId(current) } : {})
  }
}

export function modelChoiceId(choice: ModelChoice): string {
  return modelId(choice.model)
}

function modelSearchText(choice: ModelChoice): string {
  const { id, name, provider } = choice.model
  return `${provider} ${provider}/${id} ${provider} ${id}${name ? ` ${name}` : ""}`
}

function modelId(model: ModelChoice["model"]): string {
  return `${model.provider}/${model.id}`
}
