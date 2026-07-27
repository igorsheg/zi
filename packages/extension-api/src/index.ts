import { Type, type Static, type TSchema } from "typebox"

export type { Static, TSchema } from "typebox"

export const Schema = Object.freeze({
  object: Type.Object,
  string: Type.String,
  number: Type.Number,
  integer: Type.Integer,
  boolean: Type.Boolean,
  array: Type.Array,
  literal: Type.Literal,
  optional: Type.Optional
})

export type ExtensionStartReason = "startup" | "reload" | "new" | "resume" | "fork"
export type ExtensionShutdownReason = "quit" | "reload" | "new" | "resume" | "fork"

export type ExtensionLifecycleEvent =
  | { readonly type: "session_start"; readonly reason: ExtensionStartReason }
  | { readonly type: "session_shutdown"; readonly reason: ExtensionShutdownReason }

export type ExtensionStartEvent = Extract<ExtensionLifecycleEvent, { type: "session_start" }>
export type ExtensionShutdownEvent = Extract<ExtensionLifecycleEvent, { type: "session_shutdown" }>

export interface ExtensionToolContext {
  readonly signal: AbortSignal
}

export interface ExtensionToolDefinition<TParameters extends TSchema = TSchema> {
  readonly name: string
  readonly label?: string
  readonly description: string
  readonly parameters: TParameters
  execute(parameters: Static<TParameters>, context: ExtensionToolContext): string | Promise<string>
}

export interface ExtensionAPI {
  on(event: "session_start", handler: (event: ExtensionStartEvent) => void | Promise<void>): void
  on(event: "session_shutdown", handler: (event: ExtensionShutdownEvent) => void | Promise<void>): void
  registerTool<TParameters extends TSchema>(tool: ExtensionToolDefinition<TParameters>): void
}

export type ExtensionFactory = (zi: ExtensionAPI) => void | Promise<void>
