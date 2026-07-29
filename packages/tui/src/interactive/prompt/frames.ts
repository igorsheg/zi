import type {
  AgentSession,
  AuthenticationMethod,
  ModelChoice,
  ProjectFileSearchResult,
  ProjectTrustSelection,
  SessionInfo,
  SlashCommand,
  SettingsScope,
  StoredCredential
} from "@with-zi/coding-agent"

import { glyphs } from "../../glyphs.js"
import { sameModel } from "./model-choices.js"
import type { PickerFrame, PickerStackRow } from "./picker.js"
import type { EditableSetting, EditableSettingValue } from "./state.js"

export const projectFilePickerHeight = 7

export const promptPickerFrameIds = {
  commands: "commands",
  files: "files",
  models: "models",
  authProviders: "auth-providers",
  authMethods: "auth-methods",
  authOptions: "auth-options",
  logoutProviders: "logout-providers",
  codexSettings: "codex-settings",
  codexSettingValues: "codex-setting-values",
  settingsScopes: "settings-scopes",
  settings: "settings",
  settingValues: "setting-values",
  sessions: "sessions",
  projectTrust: "project-trust"
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

export function fileFrame(result: ProjectFileSearchResult, query: string, previousSelectedId?: string): PickerFrame {
  const rows = result.matches.map(match => ({
    id: `${match.type}:${match.path}`,
    label: `@${match.path}${match.type === "directory" ? "/" : ""}`,
    ...(match.type === "directory" ? { detail: "[directory]" } : {}),
    searchText: match.path
  }))
  const selectedId = rows.some(row => row.id === previousSelectedId) ? previousSelectedId : undefined
  return {
    id: promptPickerFrameIds.files,
    title: "",
    filter: "none",
    height: projectFilePickerHeight,
    rows,
    ...(selectedId ? { selectedId } : {}),
    ...(result.truncated ? { footer: `Search limited; refine @${query}` } : {})
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

export function sessionFrame(
  sessions: readonly SessionInfo[],
  currentPath: string | undefined,
  options: { readonly emptyText?: string; readonly invalid?: number; readonly omitted?: number } = {}
): PickerFrame {
  const selected = currentPath && sessions.some(session => session.path === currentPath) ? currentPath : undefined
  const notices = [
    options.invalid ? `${options.invalid} invalid` : "",
    options.omitted ? `${options.omitted} older omitted` : ""
  ].filter(Boolean)
  return {
    id: promptPickerFrameIds.sessions,
    title: "Resume session",
    filter: "fuzzy",
    emptyText: options.emptyText ?? "No saved sessions",
    rows: sessions.map(session => ({
      id: session.path,
      label: session.firstMessage || "Empty session",
      detail: `[${sessionDate(session.modifiedAt)}]`,
      ...(session.path === currentPath ? { metadata: glyphs.check } : {}),
      searchText: `${session.id} ${session.cwd} ${session.firstMessage}`
    })),
    ...(selected ? { selectedId: selected } : {}),
    ...(notices.length > 0 ? { footer: notices.join(" · ") } : {})
  }
}

export type ProjectTrustSelectionId = "untrusted-session" | "trusted-session" | "trusted-saved" | "untrusted-saved"

export function projectTrustFrame(
  cwd: string,
  selectedId: ProjectTrustSelectionId = "untrusted-session",
  disabled = false
): PickerFrame {
  return {
    id: promptPickerFrameIds.projectTrust,
    title: "Project trust",
    hint: "Project .zi settings, prompts, skills, themes, and executable extensions are currently ignored.",
    footer: disabled ? "Applying project trust…" : cwd,
    filter: "none",
    disabled,
    selectedId,
    rows: [
      {
        id: "untrusted-session",
        label: "Do not trust (this session)",
        metadata: "Keep all project .zi configuration disabled",
        searchText: "do not trust session"
      },
      {
        id: "trusted-session",
        label: "Trust (this session)",
        metadata: "Enable project .zi configuration until this session is replaced",
        searchText: "trust session"
      },
      {
        id: "trusted-saved",
        label: "Trust and remember",
        metadata: "Enable project .zi configuration and save this folder decision",
        searchText: "trust remember save"
      },
      {
        id: "untrusted-saved",
        label: "Do not trust and remember",
        metadata: "Keep project .zi configuration disabled and save this folder decision",
        searchText: "do not trust remember save"
      }
    ]
  }
}

export function projectTrustSelection(
  id: string
): { readonly id: ProjectTrustSelectionId; readonly selection: ProjectTrustSelection } | undefined {
  switch (id) {
    case "untrusted-session":
      return { id, selection: { type: "untrusted", persistence: "session" } }
    case "trusted-session":
      return { id, selection: { type: "trusted", persistence: "session" } }
    case "trusted-saved":
      return { id, selection: { type: "trusted", persistence: "saved" } }
    case "untrusted-saved":
      return { id, selection: { type: "untrusted", persistence: "saved" } }
    default:
      return undefined
  }
}

export function codexSettingsFrame(session: AgentSession): PickerFrame {
  const enabled = session.settingsManager.get().codexFastMode
  return {
    id: promptPickerFrameIds.codexSettings,
    title: "OpenAI Codex settings",
    filter: "fuzzy",
    rows: [
      {
        id: "fast-mode",
        label: "Fast mode",
        detail: `[${settingValueLabel(enabled)}]`,
        metadata: enabled ? "Low verbosity · priority service tier" : "Provider-default verbosity and service tier",
        searchText: `fast mode fast-mode ${enabled ? "on enabled low priority" : "off disabled default"}`
      }
    ]
  }
}

export function codexFastModeValuesFrame(session: AgentSession): PickerFrame {
  const saved = session.settingsManager.getGlobal().codexFastMode
  const effective = session.settingsManager.get().codexFastMode
  return {
    id: promptPickerFrameIds.codexSettingValues,
    title: "Fast mode · OpenAI Codex",
    hint: "On sends low text verbosity and the priority service tier. Off sends neither.",
    filter: "fuzzy",
    rows: [true, false].map(value => settingValueRow(value, saved, effective)),
    selectedId: settingValueId(effective),
    ...(session.settingsManager.getProject().codexFastMode !== undefined
      ? { footer: `Project settings keep Fast mode ${settingValueLabel(effective)}.` }
      : {})
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
      settingRow(session, scope, "defaultThinkingLevel", "Thinking level", scoped.defaultThinkingLevel),
      settingRow(session, scope, "steeringMode", "Steering mode", scoped.steeringMode),
      settingRow(session, scope, "followUpMode", "Follow-up mode", scoped.followUpMode),
      settingRow(session, scope, "compactionEnabled", "Automatic compaction", scoped.compactionEnabled),
      settingRow(session, scope, "retryEnabled", "Automatic retry", scoped.retryEnabled)
    ]
  }
}

export function settingValuesFrame(session: AgentSession, scope: SettingsScope, setting: EditableSetting): PickerFrame {
  const scoped = scope === "global" ? session.settingsManager.getGlobal() : session.settingsManager.getProject()
  const saved = scoped[setting]
  const effective = effectiveSetting(session, setting)
  const values: readonly EditableSettingValue[] =
    setting === "defaultThinkingLevel"
      ? session.getSupportedThinkingLevels()
      : setting === "compactionEnabled" || setting === "retryEnabled"
        ? [true, false]
        : ["one-at-a-time", "all"]
  const selected = values.find(value => value === saved) ?? effective
  const selectedId = settingValueId(selected)
  return {
    id: promptPickerFrameIds.settingValues,
    title: `${settingLabel(setting)} · ${scopeLabel(scope)}`,
    filter: "fuzzy",
    rows: values.map(value => settingValueRow(value, saved, effective)),
    selectedId,
    ...(scope === "global" && session.settingsManager.getProject()[setting] !== undefined
      ? { hint: `Project override keeps the effective value at ${settingValueLabel(effective)}.` }
      : {})
  }
}

export function settingLabel(setting: EditableSetting): string {
  switch (setting) {
    case "defaultThinkingLevel":
      return "Thinking level"
    case "steeringMode":
      return "Steering mode"
    case "followUpMode":
      return "Follow-up mode"
    case "compactionEnabled":
      return "Automatic compaction"
    case "retryEnabled":
      return "Automatic retry"
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
    id: settingValueId(value),
    label: settingValueLabel(value),
    ...(value === saved ? { detail: "[saved]" } : {}),
    ...(value === effective ? { metadata: glyphs.check } : {}),
    searchText: `${settingValueLabel(value)} ${thinkingDescription(value)}`
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
    detail: `[${saved === undefined ? "inherited" : settingValueLabel(saved)}]`,
    metadata: shadowed
      ? `Effective: ${settingValueLabel(effective)} (project override)`
      : `Effective: ${settingValueLabel(effective)}`,
    searchText: `${label} ${setting} ${saved ?? "inherited"} ${effective}`
  }
}

function effectiveSetting(session: AgentSession, setting: EditableSetting): EditableSettingValue {
  switch (setting) {
    case "defaultThinkingLevel":
      return session.thinkingLevel
    case "steeringMode":
      return session.steeringMode
    case "followUpMode":
      return session.followUpMode
    case "compactionEnabled":
      return session.settingsManager.get().compactionEnabled
    case "retryEnabled":
      return session.settingsManager.get().retryEnabled
    default:
      return assertNever(setting)
  }
}

function sessionDate(timestamp: string): string {
  return timestamp.slice(0, 16).replace("T", " ")
}

function scopeLabel(scope: SettingsScope): string {
  return scope === "global" ? "Global" : "Project"
}

function settingValueId(value: EditableSettingValue): string {
  return typeof value === "boolean" ? String(value) : value
}

function settingValueLabel(value: EditableSettingValue): string {
  return typeof value === "boolean" ? (value ? "On" : "Off") : value
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
    case true:
      return "compact before the model context fills"
    case false:
      return "do not compact automatically"
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
