import type {
  AgentSession,
  AuthenticationMethod,
  ImageContent,
  ModelChoice,
  QueueMode,
  SettingsScope,
  StoredCredential,
  ThinkingLevel
} from "@openzi/coding-agent"

export type PromptFeedback =
  | { readonly type: "none" }
  | { readonly type: "status"; readonly message: string }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "auth_link"; readonly requestId: number; readonly message: string; readonly url: string }

export type EditableSetting = "thinkingLevel" | "steeringMode" | "followUpMode"
export type EditableSettingValue = ThinkingLevel | QueueMode

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

export interface PromptState {
  readonly feedback: PromptFeedback
  readonly images: readonly ImageContent[]
  readonly workflow: PromptWorkflow
  readonly inputEdit: { readonly revision: number; readonly text: string }
}

export const initialPromptState: PromptState = {
  feedback: { type: "none" },
  images: [],
  workflow: { type: "idle" },
  inputEdit: { revision: 0, text: "" }
}

export function promptInputIsSecret(workflow: PromptWorkflow): boolean {
  return workflow.type === "auth_prompt" && workflow.promptType === "secret"
}
