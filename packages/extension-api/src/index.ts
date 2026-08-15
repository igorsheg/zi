export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue }
export type JsonPrimitive = null | boolean | number | string

interface SchemaAnnotations {
  readonly title?: string
  readonly description?: string
  readonly default?: JsonValue
}

export interface StringSchemaOptions extends SchemaAnnotations {
  readonly minLength?: number
  readonly maxLength?: number
  readonly pattern?: string
}

export interface NumberSchemaOptions extends SchemaAnnotations {
  readonly minimum?: number
  readonly maximum?: number
  readonly exclusiveMinimum?: number
  readonly exclusiveMaximum?: number
  readonly multipleOf?: number
}

export type IntegerSchemaOptions = NumberSchemaOptions

export interface ArraySchemaOptions extends SchemaAnnotations {
  readonly minItems?: number
  readonly maxItems?: number
  readonly uniqueItems?: boolean
}

export interface ObjectSchemaOptions extends SchemaAnnotations {
  readonly additionalProperties?: boolean
  readonly minProperties?: number
  readonly maxProperties?: number
}

declare const staticType: unique symbol

export interface TSchema<T = unknown> {
  readonly [key: string]: unknown
  readonly [staticType]?: T
}

export type Static<T extends TSchema> = T extends TSchema<infer Value> ? Value : never

export interface TString extends TSchema<string>, StringSchemaOptions {
  readonly type: "string"
}

export interface TNumber extends TSchema<number>, NumberSchemaOptions {
  readonly type: "number"
}

export interface TInteger extends TSchema<number>, IntegerSchemaOptions {
  readonly type: "integer"
}

export interface TBoolean extends TSchema<boolean>, SchemaAnnotations {
  readonly type: "boolean"
}

export interface TLiteral<T extends JsonPrimitive> extends TSchema<T>, SchemaAnnotations {
  readonly type: "null" | "boolean" | "number" | "string"
  readonly const: T
}

export interface TArray<TItems extends TSchema> extends TSchema<readonly Static<TItems>[]>, ArraySchemaOptions {
  readonly type: "array"
  readonly items: TItems
}

export type TOptional<T extends TSchema> = T & { readonly "~optional": true }

export type SchemaProperties = Readonly<Record<string, TSchema>>
type OptionalPropertyKeys<TProperties extends SchemaProperties> = {
  [Key in keyof TProperties]: TProperties[Key] extends { readonly "~optional": true } ? Key : never
}[keyof TProperties]
type RequiredPropertyKeys<TProperties extends SchemaProperties> = Exclude<
  keyof TProperties,
  OptionalPropertyKeys<TProperties>
>
type ObjectStatic<TProperties extends SchemaProperties> = {
  readonly [Key in RequiredPropertyKeys<TProperties>]: Static<TProperties[Key]>
} & {
  readonly [Key in OptionalPropertyKeys<TProperties>]?: Static<TProperties[Key]>
}

export interface TObject<TProperties extends SchemaProperties = SchemaProperties>
  extends TSchema<ObjectStatic<TProperties>>, ObjectSchemaOptions {
  readonly type: "object"
  readonly properties: SchemaProperties
  readonly required?: readonly string[]
}

const optionalKey = "~optional"

function string(options: StringSchemaOptions = {}): TString {
  return Object.freeze({ ...options, type: "string" as const })
}

function number(options: NumberSchemaOptions = {}): TNumber {
  return Object.freeze({ ...options, type: "number" as const })
}

function integer(options: IntegerSchemaOptions = {}): TInteger {
  return Object.freeze({ ...options, type: "integer" as const })
}

function boolean(options: SchemaAnnotations = {}): TBoolean {
  return Object.freeze({ ...options, type: "boolean" as const })
}

function literal<T extends JsonPrimitive>(value: T, options: SchemaAnnotations = {}): TLiteral<T> {
  return Object.freeze({ ...options, type: primitiveType(value), const: value })
}

function primitiveType(value: JsonPrimitive): TLiteral<JsonPrimitive>["type"] {
  if (value === null) return "null"
  switch (typeof value) {
    case "string":
      return "string"
    case "number":
      return "number"
    case "boolean":
      return "boolean"
    default:
      throw new Error("Literal values must be JSON primitives")
  }
}

function array<TItems extends TSchema>(items: TItems, options: ArraySchemaOptions = {}): TArray<TItems> {
  return Object.freeze({ ...options, type: "array" as const, items })
}

function optional<T extends TSchema>(schema: T): TOptional<T> {
  return Object.freeze({ ...schema, [optionalKey]: true as const })
}

function object<TProperties extends SchemaProperties>(
  properties: TProperties,
  options: ObjectSchemaOptions = {}
): TObject<TProperties> {
  const admitted: Record<string, TSchema> = {}
  const required: string[] = []
  for (const [name, schema] of Object.entries(properties)) {
    const { [optionalKey]: isOptional, ...property } = schema
    admitted[name] = Object.freeze(property)
    if (!isOptional) required.push(name)
  }
  return Object.freeze({
    ...options,
    type: "object" as const,
    properties: Object.freeze(admitted),
    ...(required.length > 0 ? { required: Object.freeze(required) } : {})
  })
}

export const Schema = Object.freeze({ string, number, integer, boolean, literal, array, optional, object })

export type ExtensionMode = "interactive" | "text" | "json" | "rpc" | "embedded"

export type ExtensionSession =
  | { readonly type: "memory"; readonly id: string }
  | { readonly type: "journal"; readonly id: string; readonly file: string }

export interface ExtensionContext {
  readonly mode: ExtensionMode
  readonly cwd: string
  readonly session: ExtensionSession
}

export type ExtensionStartReason = "startup" | "reload" | "new" | "resume" | "fork"
export type ExtensionShutdownReason = "quit" | "reload" | "new" | "resume" | "fork"

export type ExtensionLifecycleEvent =
  | { readonly type: "session_start"; readonly reason: ExtensionStartReason }
  | { readonly type: "session_shutdown"; readonly reason: ExtensionShutdownReason }

export type ExtensionStartEvent = Extract<ExtensionLifecycleEvent, { type: "session_start" }>
export type ExtensionShutdownEvent = Extract<ExtensionLifecycleEvent, { type: "session_shutdown" }>

export interface ExtensionAgentStartEvent {
  readonly type: "agent_start"
}

export interface ExtensionAgentSettledEvent {
  readonly type: "agent_settled"
}

export type ExtensionEvent = ExtensionLifecycleEvent | ExtensionAgentStartEvent | ExtensionAgentSettledEvent

export interface ExtensionTextContent {
  readonly type: "text"
  readonly text: string
}

export interface ExtensionImageContent {
  readonly type: "image"
  readonly mimeType: string
  readonly data: string
}

export interface ExtensionCustomEntry {
  readonly id: string
  readonly timestamp: string
  readonly customType: string
  readonly data?: JsonValue
}

export interface ExtensionCustomMessage {
  readonly customType: string
  readonly content: string | readonly (ExtensionTextContent | ExtensionImageContent)[]
  readonly display: boolean
  readonly details?: JsonValue
}

export type ExtensionMessageDelivery = "append" | "trigger_turn" | "steer" | "follow_up" | "next_turn"

export interface ExtensionCommandContext extends ExtensionContext {
  readonly signal: AbortSignal
}

export interface ExtensionCommandDefinition {
  readonly name: string
  readonly description: string
  readonly argumentHint?: string
  execute(arguments_: string, context: ExtensionCommandContext): void | string | Promise<void | string>
}

export interface ExtensionToolContext extends ExtensionContext {
  readonly signal: AbortSignal
  reportProgress(message: string): void
}

interface ExtensionToolDefinitionBase<TParameters extends TObject> {
  readonly name: string
  readonly label?: string
  readonly description: string
  readonly active?: boolean
  readonly timeoutMs?: number
  readonly parameters: TParameters
}

export type ExtensionToolDefinition<
  TParameters extends TObject = TObject,
  TOutputSchema extends TSchema | undefined = undefined
> = ExtensionToolDefinitionBase<TParameters> &
  (TOutputSchema extends TSchema
    ? {
        readonly outputSchema: TOutputSchema
        execute(
          parameters: Static<TParameters>,
          context: ExtensionToolContext
        ): Static<TOutputSchema> | Promise<Static<TOutputSchema>>
      }
    : {
        readonly outputSchema?: never
        execute(parameters: Static<TParameters>, context: ExtensionToolContext): string | Promise<string>
      })

export type ExtensionThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"

export interface ExtensionSubagentProfile {
  readonly name: string
  readonly description: string
  readonly instructions: string
  readonly model?: string
  readonly thinking?: ExtensionThinkingLevel
}

export type ExtensionSubagentLifecycle = "idle" | "queued" | "running" | "interrupting" | "closing" | "exited"

export interface ExtensionSubagentCompletion {
  readonly workCycle: number
  readonly status: "completed" | "failed" | "cancelled"
  readonly text: string
  readonly originalBytes: number
  readonly omittedBytes: number
  readonly truncated: boolean
  readonly durationMs: number
  readonly reason?: string
  readonly error?: string
}

export interface ExtensionSubagentSnapshot {
  readonly name: string
  readonly lifecycle: ExtensionSubagentLifecycle
  readonly workCycle?: number
  readonly capturedWorkCycle?: number
  readonly task?: string
  readonly elapsedMs?: number
  readonly resultReady: boolean
  readonly completion?: ExtensionSubagentCompletion
}

export interface ExtensionSubagentInterruptSettlement {
  readonly result: "interrupted" | "already_idle"
  readonly snapshot: ExtensionSubagentSnapshot
}

export interface ExtensionSubagentAPI {
  listProfiles(): Promise<readonly ExtensionSubagentProfile[]>
  spawn(profile: string, name: string, prompt: string, signal?: AbortSignal): Promise<string>
  send(name: string, text: string): Promise<void>
  continue(name: string, text: string): Promise<"started_turn" | "follow_up">
  wait(
    names: readonly string[],
    timeoutMs?: number,
    signal?: AbortSignal
  ): Promise<readonly ExtensionSubagentSnapshot[]>
  interrupt(name: string): Promise<ExtensionSubagentInterruptSettlement>
  close(name: string): Promise<ExtensionSubagentSnapshot>
  list(): Promise<readonly ExtensionSubagentSnapshot[]>
}

export interface ExtensionAPI {
  readonly subagents?: ExtensionSubagentAPI
  on(
    event: "session_start",
    handler: (event: ExtensionStartEvent, context: ExtensionContext) => void | Promise<void>
  ): void
  on(
    event: "session_shutdown",
    handler: (event: ExtensionShutdownEvent, context: ExtensionContext) => void | Promise<void>
  ): void
  on(
    event: "agent_start",
    handler: (event: ExtensionAgentStartEvent, context: ExtensionContext) => void | Promise<void>
  ): void
  on(
    event: "agent_settled",
    handler: (event: ExtensionAgentSettledEvent, context: ExtensionContext) => void | Promise<void>
  ): void
  registerCommand(command: ExtensionCommandDefinition): void
  registerTool<TParameters extends TObject, TOutputSchema extends TSchema | undefined = undefined>(
    tool: ExtensionToolDefinition<TParameters, TOutputSchema>
  ): void
  getActiveTools(): Promise<readonly string[]>
  setActiveTools(names: readonly string[]): Promise<void>
  registerSubagentProfile(profile: ExtensionSubagentProfile): void
  getSessionEntries(customType: string): Promise<readonly ExtensionCustomEntry[]>
  appendEntry(customType: string, data?: JsonValue): Promise<ExtensionCustomEntry>
  sendMessage(message: ExtensionCustomMessage, delivery: ExtensionMessageDelivery): Promise<void>
}

export type ExtensionFactory = (zi: ExtensionAPI) => void | Promise<void>
