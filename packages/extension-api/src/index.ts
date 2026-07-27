export type ExtensionStartReason = "startup" | "reload" | "new" | "resume" | "fork"
export type ExtensionShutdownReason = "quit" | "reload" | "new" | "resume" | "fork"

export type ExtensionLifecycleEvent =
  | { readonly type: "session_start"; readonly reason: ExtensionStartReason }
  | { readonly type: "session_shutdown"; readonly reason: ExtensionShutdownReason }

export type ExtensionStartEvent = Extract<ExtensionLifecycleEvent, { type: "session_start" }>
export type ExtensionShutdownEvent = Extract<ExtensionLifecycleEvent, { type: "session_shutdown" }>

export interface ExtensionAPI {
  on(event: "session_start", handler: (event: ExtensionStartEvent) => void | Promise<void>): void
  on(event: "session_shutdown", handler: (event: ExtensionShutdownEvent) => void | Promise<void>): void
}

export type ExtensionFactory = (zi: ExtensionAPI) => void | Promise<void>
