import type {
  AgentSession,
  AuthenticationMethod,
  ImageContent,
  ModelChoice,
  ProjectTrustSelection,
  QueueMode,
  SettingsScope,
  SessionInfo,
  StoredCredential,
  ThinkingLevel
} from "@with-zi/coding-agent"

export type PromptFeedback =
  | { readonly type: "none" }
  | { readonly type: "status"; readonly message: string }
  | { readonly type: "warning"; readonly message: string }
  | { readonly type: "copy_warning"; readonly message: string }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "auth_link"; readonly requestId: number; readonly message: string; readonly url: string }

export type EditableSetting =
  | "defaultThinkingLevel"
  | "steeringMode"
  | "followUpMode"
  | "compactionEnabled"
  | "retryEnabled"
export type EditableSettingValue = ThinkingLevel | QueueMode | boolean

export type PromptWorkflow =
  | { readonly type: "idle" }
  | { readonly type: "loading_models"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_model"
      readonly operationId: number
      readonly session: AgentSession
      readonly choices: readonly ModelChoice[]
    }
  | { readonly type: "selecting_model"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_auth_provider"
      readonly operationId: number
      readonly session: AgentSession
      readonly methods: readonly AuthenticationMethod[]
    }
  | {
      readonly type: "choosing_auth_method"
      readonly operationId: number
      readonly session: AgentSession
      readonly methods: readonly AuthenticationMethod[]
    }
  | {
      readonly type: "authenticating"
      readonly operationId: number
      readonly session: AgentSession
      readonly providerId: string
    }
  | {
      readonly type: "auth_prompt"
      readonly operationId: number
      readonly session: AgentSession
      readonly providerId: string
      readonly promptType: "text" | "secret" | "manual_code"
    }
  | {
      readonly type: "choosing_auth_option"
      readonly operationId: number
      readonly session: AgentSession
      readonly providerId: string
      readonly options: readonly { readonly id: string; readonly label: string; readonly description?: string }[]
    }
  | { readonly type: "loading_logout"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_logout"
      readonly operationId: number
      readonly session: AgentSession
      readonly credentials: readonly StoredCredential[]
    }
  | {
      readonly type: "logging_out"
      readonly operationId: number
      readonly session: AgentSession
      readonly providerId: string
    }
  | { readonly type: "compacting"; readonly operationId: number; readonly session: AgentSession }
  | { readonly type: "starting_session"; readonly operationId: number; readonly session: AgentSession }
  | { readonly type: "loading_sessions"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_session"
      readonly operationId: number
      readonly session: AgentSession
      readonly sessions: readonly SessionInfo[]
    }
  | { readonly type: "resuming_session"; readonly operationId: number; readonly session: AgentSession }
  | { readonly type: "cancelling_session"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_project_trust"
      readonly operationId: number
      readonly session: AgentSession
      readonly cwd: string
    }
  | {
      readonly type: "saving_project_trust"
      readonly operationId: number
      readonly session: AgentSession
      readonly cwd: string
      readonly selection: ProjectTrustSelection
    }
  | { readonly type: "choosing_settings_scope"; readonly operationId: number; readonly session: AgentSession }
  | {
      readonly type: "choosing_setting"
      readonly operationId: number
      readonly session: AgentSession
      readonly scope: SettingsScope
    }
  | {
      readonly type: "choosing_setting_value"
      readonly operationId: number
      readonly session: AgentSession
      readonly scope: SettingsScope
      readonly setting: EditableSetting
    }

export type PromptInputEdit =
  | { readonly type: "replace"; readonly revision: number; readonly text: string; readonly cursorOffset: number }
  | {
      readonly type: "range"
      readonly revision: number
      readonly startOffset: number
      readonly endOffset: number
      readonly replacement: string
      readonly cursorOffset: number
    }

export interface PromptState {
  readonly feedback: PromptFeedback
  readonly images: readonly ImageContent[]
  readonly workflow: PromptWorkflow
  readonly inputEdit: PromptInputEdit
}

export const initialPromptState: PromptState = {
  feedback: { type: "none" },
  images: [],
  workflow: { type: "idle" },
  inputEdit: { type: "replace", revision: 0, text: "", cursorOffset: 0 }
}

export function promptInputIsSecret(workflow: PromptWorkflow): boolean {
  return workflow.type === "auth_prompt" && workflow.promptType === "secret"
}
