import type {
  AgentSession,
  AuthenticationMethod,
  ModelChoice,
  SlashCommand,
  SettingsScope,
  StoredCredential
} from "@openzi/coding-agent"

import { glyphs } from "../../glyphs.js"
import { sameModel } from "./model-choices.js"
import type { PickerFrame, PickerStackRow } from "./picker.js"
import type { EditableSetting, EditableSettingValue } from "./state.js"

export const promptPickerFrameIds = {
  commands: "commands",
  models: "models",
  authProviders: "auth-providers",
  authMethods: "auth-methods",
  authOptions: "auth-options",
  logoutProviders: "logout-providers",
  settingsScopes: "settings-scopes",
  settings: "settings",
  settingValues: "setting-values"
} as const

export function commandFrame(commands: readonly SlashCommand[]): PickerFrame {
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

export function settingsScopeFrame(): PickerFrame {
  return {
    id: promptPickerFrameIds.settingsScopes,
    title: "Settings scope",
    filter: "fuzzy",
    rows: [
      {
        id: "global",
        label: "Global",
        metadata: "Applies across projects unless a project value overrides it",
        searchText: "global all projects"
      },
      {
        id: "project",
        label: "Project",
        metadata: "Applies only to the current working directory",
        searchText: "project current working directory"
      }
    ]
  }
}

export function settingsFrame(session: AgentSession, scope: SettingsScope): PickerFrame {
  const scoped = scope === "global" ? session.settingsManager.getGlobal() : session.settingsManager.getProject()
  return {
    id: promptPickerFrameIds.settings,
    title: `Settings · ${scopeLabel(scope)}`,
    filter: "fuzzy",
    rows: [
      settingRow(session, scope, "thinkingLevel", "Thinking level", scoped.thinkingLevel),
      settingRow(session, scope, "steeringMode", "Steering mode", scoped.steeringMode),
      settingRow(session, scope, "followUpMode", "Follow-up mode", scoped.followUpMode)
    ]
  }
}

export function settingValuesFrame(session: AgentSession, scope: SettingsScope, setting: EditableSetting): PickerFrame {
  const scoped = scope === "global" ? session.settingsManager.getGlobal() : session.settingsManager.getProject()
  const saved = scoped[setting]
  const effective = effectiveSetting(session, setting)
  const values =
    setting === "thinkingLevel" ? session.getSupportedThinkingLevels() : (["one-at-a-time", "all"] as const)
  const selectedId = values.find(value => value === saved) ?? effective
  return {
    id: promptPickerFrameIds.settingValues,
    title: `${settingLabel(setting)} · ${scopeLabel(scope)}`,
    filter: "fuzzy",
    rows: values.map(value => settingValueRow(value, saved, effective)),
    selectedId,
    ...(scope === "global" && session.settingsManager.getProject()[setting] !== undefined
      ? { hint: `Project override keeps the effective value at ${effective}.` }
      : {})
  }
}

export function settingLabel(setting: EditableSetting): string {
  switch (setting) {
    case "thinkingLevel":
      return "Thinking level"
    case "steeringMode":
      return "Steering mode"
    case "followUpMode":
      return "Follow-up mode"
    default:
      return assertNever(setting)
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

function settingValueRow(
  value: EditableSettingValue,
  saved: EditableSettingValue | undefined,
  effective: EditableSettingValue
): PickerStackRow {
  return {
    id: value,
    label: value,
    ...(value === saved ? { detail: "[saved]" } : {}),
    ...(value === effective ? { metadata: glyphs.check } : {}),
    searchText: `${value} ${thinkingDescription(value)}`
  }
}

function settingRow(
  session: AgentSession,
  scope: SettingsScope,
  setting: EditableSetting,
  label: string,
  saved: EditableSettingValue | undefined
): PickerStackRow {
  const effective = effectiveSetting(session, setting)
  const shadowed = scope === "global" && session.settingsManager.getProject()[setting] !== undefined
  return {
    id: setting,
    label,
    detail: `[${saved ?? "inherited"}]`,
    metadata: shadowed ? `Effective: ${effective} (project override)` : `Effective: ${effective}`,
    searchText: `${label} ${setting} ${saved ?? "inherited"} ${effective}`
  }
}

function effectiveSetting(session: AgentSession, setting: EditableSetting): EditableSettingValue {
  switch (setting) {
    case "thinkingLevel":
      return session.thinkingLevel
    case "steeringMode":
      return session.steeringMode
    case "followUpMode":
      return session.followUpMode
    default:
      return assertNever(setting)
  }
}

function scopeLabel(scope: SettingsScope): string {
  return scope === "global" ? "Global" : "Project"
}

function thinkingDescription(value: EditableSettingValue): string {
  switch (value) {
    case "off":
      return "no reasoning"
    case "minimal":
      return "minimal reasoning"
    case "low":
      return "low reasoning"
    case "medium":
      return "medium reasoning"
    case "high":
      return "high reasoning"
    case "xhigh":
      return "extra high reasoning"
    case "max":
      return "maximum reasoning"
    case "all":
      return "batch all queued messages"
    case "one-at-a-time":
      return "deliver one queued message at a time"
    default:
      return assertNever(value)
  }
}

function modelSearchText(choice: ModelChoice): string {
  const { id, name, provider } = choice.model
  return `${provider} ${provider}/${id} ${provider} ${id}${name ? ` ${name}` : ""}`
}

function modelId(model: ModelChoice["model"]): string {
  return `${model.provider}/${model.id}`
}

function assertNever(value: never): never {
  throw new Error(`Unexpected settings value: ${String(value)}`)
}
