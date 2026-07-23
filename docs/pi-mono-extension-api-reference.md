## Scope and revision

Inspected:

- **Current pi-mono:** `fc85bdd8`, 2026-07-23, `v0.81.1-26-gfc85bdd8`
- **Zi’s pinned reference:** `0e6909f0`, 2026-07-13, `v0.80.6`

This inventories the extension-author contract exposed through `ExtensionAPI`, callback contexts, reachable objects, rendering/tool contracts, and extension-host exports. It excludes unrelated coding-agent SDK exports and the full transitive APIs of `pi-ai` and `pi-tui`.

Primary sources:

- [`packages/coding-agent/src/core/extensions/types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts)
- [`packages/coding-agent/src/core/extensions/loader.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/loader.ts)
- [`packages/coding-agent/src/core/extensions/runner.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/runner.ts)
- [`packages/coding-agent/src/core/extensions/index.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/index.ts)
- [`packages/coding-agent/docs/extensions.md`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md)
- [Zi-pinned `types.ts` at `0e6909f0`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/extensions/types.ts)

# 1. Loading and execution model

_Source: [`loader.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/loader.ts), [`extensions.md`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md), and [`types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts)._

An extension is a trusted TypeScript/JavaScript module:

```ts
type ExtensionFactory = (pi: ExtensionAPI) => void | Promise<void>
```

Supported forms:

```ts
type InlineExtension = ExtensionFactory | { name: string; factory: ExtensionFactory; hidden?: boolean }
```

Discovery sources:

- `$HOME/.pi/agent/extensions/*.ts`
- `$HOME/.pi/agent/extensions/*/index.ts`
- `<cwd>/.pi/extensions/*.ts`
- `<cwd>/.pi/extensions/*/index.ts`
- `settings.json` extension paths
- installed npm/git Pi packages
- CLI `--extension` / `-e`
- SDK inline extensions

Project extensions load only after project trust. Extensions run in-process with normal Node.js permissions and are **not sandboxed**.

# 2. `ExtensionAPI`

_Source: [`ExtensionAPI` in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L1174-L1410) and its concrete construction in [`loader.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/loader.ts)._

## Event subscription

```ts
pi.on(event, handler)
```

The complete event catalog has 33 events:

### Startup and resources

1. `project_trust`
2. `resources_discover`

### Session lifecycle

3. `session_start`
4. `session_info_changed`
5. `session_before_switch`
6. `session_before_fork`
7. `session_before_compact`
8. `session_compact`
9. `session_shutdown`
10. `session_before_tree`
11. `session_tree`

### Provider and context

12. `context`
13. `before_provider_request`
14. `before_provider_headers`
15. `after_provider_response`

### Agent lifecycle

16. `before_agent_start`
17. `agent_start`
18. `agent_end`
19. `agent_settled`
20. `turn_start`
21. `turn_end`

### Messages and tool execution

22. `message_start`
23. `message_update`
24. `message_end`
25. `tool_execution_start`
26. `tool_execution_update`
27. `tool_execution_end`

### Model state

28. `model_select`
29. `thinking_level_select`

### Admission and interception

30. `tool_call`
31. `tool_result`
32. `user_bash`
33. `input`

## Registration

```ts
pi.registerTool(tool)
pi.registerCommand(name, options)
pi.registerShortcut(shortcut, options)
pi.registerFlag(name, options)
pi.getFlag(name)

pi.registerMessageRenderer(customType, renderer)
pi.registerEntryRenderer(customType, renderer)

pi.registerProvider(name, config)
pi.registerProvider(provider) // current HEAD
pi.unregisterProvider(name)
```

## Session and message actions

```ts
pi.sendMessage(message, options?)
pi.sendUserMessage(content, options?)
pi.appendEntry(customType, data?)

pi.setSessionName(name)
pi.getSessionName()
pi.setLabel(entryId, label)
```

`sendMessage()` accepts:

- `customType`
- `content`
- `display`
- `details`
- `triggerTurn?`
- `deliverAs?: "steer" | "followUp" | "nextTurn"`

`sendUserMessage()` accepts text or text/image content and:

```ts
deliverAs?: "steer" | "followUp"
```

`appendEntry()` persists extension data without adding it to provider context.

## Process, tools, commands, and models

```ts
pi.exec(command, args, {
  signal?,
  timeout?,
  cwd?
})

pi.getActiveTools()
pi.getAllTools()
pi.setActiveTools(names)
pi.getCommands()

pi.setModel(model)
pi.getThinkingLevel()
pi.setThinkingLevel(level)
```

`exec()` returns:

```ts
{
  stdout: string
  stderr: string
  code: number
  killed: boolean
}
```

## Inter-extension communication

```ts
pi.events.emit(channel, data)
pi.events.on(channel, handler) // returns unsubscribe
```

This is an untyped process-local event bus.

# 3. Event payloads and interception results

_Source: event and result declarations in [`types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L510-L1120), with dispatch and chaining behavior in [`runner.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/runner.ts)._

## Startup and resources

### `project_trust`

Payload:

```ts
{
  type: "project_trust"
  cwd: string
}
```

Uses the restricted `ProjectTrustContext`, not ordinary `ExtensionContext`.

Result:

```ts
{
  trusted: "yes" | "no" | "undecided"
  remember?: boolean
}
```

### `resources_discover`

```ts
{
  type: "resources_discover"
  cwd: string
  reason: "startup" | "reload"
}
```

Result:

```ts
{
  skillPaths?: string[]
  promptPaths?: string[]
  themePaths?: string[]
}
```

## Session events

### `session_start`

```ts
{
  reason: "startup" | "reload" | "new" | "resume" | "fork"
  previousSessionFile?: string
}
```

### `session_info_changed`

```ts
{
  name: string | undefined
}
```

### `session_before_switch`

```ts
{
  reason: "new" | "resume"
  targetSessionFile?: string
}
```

Result: `{ cancel?: boolean }`.

### `session_before_fork`

```ts
{
  entryId: string
  position: "before" | "at"
}
```

Result:

```ts
{
  cancel?: boolean
  skipConversationRestore?: boolean
}
```

### `session_before_compact`

```ts
{
  preparation: CompactionPreparation
  branchEntries: SessionEntry[]
  customInstructions?: string
  reason: "manual" | "threshold" | "overflow"
  willRetry: boolean
  signal: AbortSignal
}
```

Result:

```ts
{
  cancel?: boolean
  compaction?: CompactionResult
}
```

### `session_compact`

```ts
{
  compactionEntry: CompactionEntry
  fromExtension: boolean
  reason: "manual" | "threshold" | "overflow"
  willRetry: boolean
}
```

### `session_shutdown`

```ts
{
  reason: "quit" | "reload" | "new" | "resume" | "fork"
  targetSessionFile?: string
}
```

### `session_before_tree`

Provides:

- target entry
- old leaf
- common ancestor
- entries to summarize
- whether the user requested a summary
- custom/replace instructions
- optional label
- cancellation signal

Result can:

- cancel navigation
- provide a complete summary
- override summary instructions
- override replacement behavior
- override the summary label

### `session_tree`

```ts
{
  newLeafId: string | null
  oldLeafId: string | null
  summaryEntry?: BranchSummaryEntry
  fromExtension?: boolean
}
```

## Provider and context events

### `context`

Payload: mutable/provider-bound `AgentMessage[]`.

Result:

```ts
{ messages?: AgentMessage[] }
```

### `before_provider_request`

```ts
{
  payload: unknown
}
```

The returned value replaces the provider payload.

### `before_provider_headers`

```ts
{
  headers: Record<string, string | null>
}
```

Handlers mutate headers in place; `null` deletes a header.

### `after_provider_response`

```ts
{
  status: number
  headers: Record<string, string>
}
```

## Agent events

### `before_agent_start`

```ts
{
  prompt: string
  images?: ImageContent[]
  systemPrompt: string
  systemPromptOptions: BuildSystemPromptOptions
}
```

Result:

```ts
{
  message?: CustomMessage
  systemPrompt?: string
}
```

Multiple system-prompt results are chained.

### `agent_start`

No additional fields.

### `agent_end`

```ts
{ messages: AgentMessage[] }
```

### `agent_settled`

No additional fields. This fires only after retry, compaction, and queued continuation have settled.

### `turn_start`

```ts
{
  turnIndex: number
  timestamp: number
}
```

### `turn_end`

```ts
{
  turnIndex: number
  message: AgentMessage
  toolResults: ToolResultMessage[]
}
```

## Message and execution events

### `message_start`

```ts
{
  message: AgentMessage
}
```

### `message_update`

```ts
{
  message: AgentMessage
  assistantMessageEvent: AssistantMessageEvent
}
```

### `message_end`

```ts
{
  message: AgentMessage
}
```

Result may replace the finalized message, but must preserve its role.

### `tool_execution_start`

```ts
{
  toolCallId: string
  toolName: string
  args: any
}
```

### `tool_execution_update`

```ts
{
  toolCallId: string
  toolName: string
  args: any
  partialResult: any
}
```

### `tool_execution_end`

```ts
{
  toolCallId: string
  toolName: string
  result: any
  isError: boolean
}
```

## Model events

### `model_select`

```ts
{
  model: Model
  previousModel?: Model
  source: "set" | "cycle" | "restore"
}
```

### `thinking_level_select`

```ts
{
  level: ThinkingLevel
  previousLevel: ThinkingLevel
}
```

## Admission events

### `input`

```ts
{
  text: string
  images?: ImageContent[]
  source: "interactive" | "rpc" | "extension"
  streamingBehavior?: "steer" | "followUp"
}
```

Result:

```ts
| { action: "continue" }
| { action: "transform"; text: string; images?: ImageContent[] }
| { action: "handled" }
```

### `tool_call`

Common fields:

```ts
{
  toolCallId: string
  toolName: string
  input: Record<string, unknown>
}
```

Built-ins have typed variants for:

- `bash`
- `read`
- `edit`
- `write`
- `grep`
- `find`
- `ls`

Handlers may mutate `input` in place. Pi does not revalidate it afterward.

Result:

```ts
{
  block?: boolean
  reason?: string
}
```

### `tool_result`

Common fields:

```ts
{
  toolCallId: string
  toolName: string
  input: Record<string, unknown>
  content: Array<TextContent | ImageContent>
  details: unknown
  isError: boolean
  usage?: Usage // current HEAD
}
```

Result can replace:

- `content`
- `details`
- `isError`
- `usage` in current HEAD

Type guards:

```ts
isToolCallEventType()
isBashToolResult()
isReadToolResult()
isEditToolResult()
isWriteToolResult()
isGrepToolResult()
isFindToolResult()
isLsToolResult()
```

### `user_bash`

```ts
{
  command: string
  excludeFromContext: boolean
  cwd: string
}
```

Result can provide:

- custom `BashOperations`, or
- a complete replacement `BashResult`.

# 4. `ExtensionContext`

_Source: [`ExtensionContext` in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L305-L344) and context construction in [`runner.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/runner.ts)._

Every ordinary event handler and tool execution receives:

```ts
interface ExtensionContext {
  ui: ExtensionUIContext
  mode: "tui" | "rpc" | "json" | "print"
  hasUI: boolean
  cwd: string

  sessionManager: ReadonlySessionManager
  modelRegistry: ModelRegistry
  model: Model | undefined
  thinkingLevel?: ThinkingLevel // current HEAD

  signal: AbortSignal | undefined

  isIdle(): boolean
  isProjectTrusted(): boolean
  abort(): void
  hasPendingMessages(): boolean
  shutdown(): void

  getContextUsage(): { tokens: number | null; contextWindow: number; percent: number | null } | undefined

  compact(options?): void
  getSystemPrompt(): string
}
```

`compact()` options:

```ts
{
  customInstructions?: string
  onComplete?: (result: CompactionResult) => void
  onError?: (error: Error) => void
}
```

# 5. `ExtensionCommandContext`

_Source: [`ExtensionCommandContext` and `ReplacedSessionContext` in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L346-L398), with replacement and stale-context behavior in [`runner.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/runner.ts) and [`extensions.md`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md)._

Command handlers receive everything in `ExtensionContext`, plus:

```ts
getSystemPromptOptions(): BuildSystemPromptOptions
waitForIdle(): Promise<void>

newSession(options?): Promise<{ cancelled: boolean }>
fork(entryId, options?): Promise<{ cancelled: boolean }>
navigateTree(targetId, options?): Promise<{ cancelled: boolean }>
switchSession(sessionPath, options?): Promise<{ cancelled: boolean }>
reload(): Promise<void>
```

## `newSession()`

Options:

```ts
{
  parentSession?: string
  setup?: (sessionManager: SessionManager) => Promise<void>
  withSession?: (ctx: ReplacedSessionContext) => Promise<void>
}
```

## `fork()`

Options:

```ts
{
  position?: "before" | "at"
  withSession?: (ctx: ReplacedSessionContext) => Promise<void>
}
```

## `navigateTree()`

Options:

```ts
{
  summarize?: boolean
  customInstructions?: string
  replaceInstructions?: boolean
  label?: string
}
```

## `switchSession()`

Options:

```ts
{
  withSession?: (ctx: ReplacedSessionContext) => Promise<void>
}
```

`ReplacedSessionContext` adds awaited versions of:

```ts
sendMessage(...)
sendUserMessage(...)
```

Old `pi` and command-context objects become stale after replacement or reload.

# 6. `ExtensionUIContext`

_Source: [`ExtensionUIContext` in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L129-L282), [custom UI documentation](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md), and [`Theme`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/modes/interactive/theme/theme.ts)._

## Dialogs

```ts
select(title, options, { signal?, timeout? }?)
confirm(title, message, { signal?, timeout? }?)
input(title, placeholder?, { signal?, timeout? }?)
editor(title, prefill?)
notify(message, "info" | "warning" | "error"?)
```

## Terminal and editor

```ts
onTerminalInput(handler) // returns unsubscribe

pasteToEditor(text)
setEditorText(text)
getEditorText()

addAutocompleteProvider(factory)

setEditorComponent(factory | undefined)
getEditorComponent()
```

A terminal input handler may return:

```ts
{ consume?: boolean; data?: string } | undefined
```

## Status and working presentation

```ts
setStatus(key, text | undefined)
setWorkingMessage(message?)
setWorkingVisible(visible)
setWorkingIndicator({ frames?, intervalMs? }?)
setHiddenThinkingLabel(label?)
```

## Widgets and chrome

```ts
setWidget(key, string[] | componentFactory | undefined, {
  placement?: "aboveEditor" | "belowEditor"
}?)

setFooter(factory | undefined)
setHeader(factory | undefined)
setTitle(title)
```

Footer factories receive `ReadonlyFooterDataProvider`:

```ts
getGitBranch()
getExtensionStatuses()
getAvailableProviderCount()
onBranchChange(callback)
```

_Source: [`footer-data-provider.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/footer-data-provider.ts)._

## Custom focused UI

```ts
custom<T>(factory, {
  overlay?: boolean
  overlayOptions?: OverlayOptions | (() => OverlayOptions)
  onHandle?: (handle: OverlayHandle) => void
}?): Promise<T>
```

The factory receives:

- Pi TUI instance
- theme
- keybindings
- `done(result)` callback

It returns a Pi TUI `Component` with optional `dispose()`.

## Theme and transcript controls

```ts
readonly theme: Theme

getAllThemes()
getTheme(name)
setTheme(nameOrTheme)

getToolsExpanded()
setToolsExpanded(expanded)
```

`Theme` exposes:

```ts
fg()
bg()
bold()
italic()
underline()
strikethrough()
getFgAnsi()
getBgAnsi()
getColorMode()
getThinkingBorderColor()
getBashModeBorderColor()
```

## Mode support

| Mode    | UI support                                                       |
| ------- | ---------------------------------------------------------------- |
| `tui`   | Full UI and direct components                                    |
| `rpc`   | Dialogs/notifications through RPC; custom components unavailable |
| `json`  | UI methods are no-ops                                            |
| `print` | UI methods are no-ops                                            |

# 7. Custom tools

_Source: [`ToolDefinition` and rendering types in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L404-L505), [`wrapper.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/wrapper.ts), and [custom tool documentation](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md)._

```ts
interface ToolDefinition {
  name: string
  label: string
  description: string
  promptSnippet?: string
  promptGuidelines?: string[]
  parameters: TypeBoxSchema

  renderShell?: "default" | "self"
  executionMode?: "sequential" | "parallel"
  prepareArguments?: (raw: unknown) => typedArguments

  execute(toolCallId, params, signal, onUpdate, ctx): Promise<AgentToolResult>

  renderCall?(args, theme, renderContext): Component
  renderResult?(result, options, theme, renderContext): Component
}
```

`ToolRenderContext` exposes:

- typed arguments
- stable tool-call ID
- `invalidate()`
- prior component
- per-row mutable state
- cwd
- execution-started state
- arguments-complete state
- partial state
- expanded state
- image visibility
- error state

`renderResult()` receives:

```ts
{
  expanded: boolean
  isPartial: boolean
}
```

Utilities:

- `defineTool()`
- `wrapRegisteredTool()`
- `wrapRegisteredTools()`
- `withFileMutationQueue()`
- `truncateHead()`
- `truncateTail()`
- `truncateLine()`

Registering a tool with a built-in name overrides that built-in.

# 8. Commands, shortcuts, flags, and renderers

_Source: registration contracts in [`types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts), command metadata in [`slash-commands.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/slash-commands.ts), and [extension documentation](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md)._

## Commands

```ts
pi.registerCommand(name, {
  description?,
  getArgumentCompletions?(prefix),
  async handler(args, commandContext)
})
```

`pi.getCommands()` returns:

```ts
{
  name: string
  description?: string
  source: "extension" | "prompt" | "skill"
  sourceInfo: SourceInfo
}
```

## Shortcuts

```ts
pi.registerShortcut(keyId, {
  description?,
  handler(ctx)
})
```

Shortcuts use Pi TUI `KeyId` and are resolved against built-in keybindings.

## Flags

```ts
pi.registerFlag(name, {
  description?,
  type: "boolean" | "string"
  default?: boolean | string
})

pi.getFlag(name)
```

## Message renderers

```ts
pi.registerMessageRenderer(customType, (message, { expanded }, theme) => component)
```

Custom messages participate in provider context.

## Entry renderers

```ts
pi.registerEntryRenderer(customType, (entry, { expanded }, theme) => component)
```

Custom entries are durable but excluded from provider context.

# 9. Provider registration

_Source: [`ProviderConfig` and `ProviderModelConfig` in `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts#L1416-L1483), [`Provider` in `pi-ai`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/ai/src/models.ts), [`Api` in `pi-ai`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/ai/src/types.ts), and [provider documentation](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/docs/extensions.md)._

## Declarative provider

```ts
pi.registerProvider(name, {
  name?,
  baseUrl?,
  apiKey?,
  api?,
  streamSimple?,
  headers?,
  authHeader?,
  models?,
  refreshModels?, // current HEAD
  oauth?
})
```

`apiKey` supports:

- literal values
- `$ENV_VAR`
- `${ENV_VAR}`
- leading `!command`

Known API identifiers include:

- `openai-completions`
- `mistral-conversations`
- `openai-responses`
- `azure-openai-responses`
- `openai-codex-responses`
- `anthropic-messages`
- `bedrock-converse-stream`
- `google-generative-ai`
- `google-vertex`
- `pi-messages`

Arbitrary API identifiers are allowed when paired with custom stream behavior.

## Model declaration

```ts
{
  id: string
  name: string
  api?: Api
  baseUrl?: string
  reasoning: boolean
  thinkingLevelMap?: Model["thinkingLevelMap"]
  input: Array<"text" | "image">
  cost: Model["cost"]
  contextWindow: number
  maxTokens: number
  headers?: Record<string, string>
  compat?: Model["compat"]
}
```

## OAuth declaration

```ts
{
  name: string
  login(callbacks): Promise<OAuthCredentials>
  refreshToken(credentials): Promise<OAuthCredentials>
  getApiKey(credentials): string
  modifyModels?(models, credentials): Model[]
}
```

## Native provider registration—current HEAD only

```ts
pi.registerProvider(provider: Provider)
```

The native `Provider` owns:

- ID and display name
- base URL and headers
- auth
- synchronous model catalog
- optional model refresh
- optional credential-based model filtering
- `stream()`
- `streamSimple()`

# 10. Reachable authoritative objects

_Source: [`ReadonlySessionManager` in `session-manager.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/session-manager.ts) and [`ModelRegistry`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/model-registry.ts)._

## `ReadonlySessionManager`

Available through `ctx.sessionManager`:

```ts
getCwd()
getSessionDir()
getSessionId()
getSessionFile()
getLeafId()
getLeafEntry()
getEntry(id)
getLabel(id)
getBranch(fromId?)
buildContextEntries()
getHeader()
getEntries()
getTree()
getSessionName()
```

This exposes the complete durable session entry/tree model to extensions.

## `ModelRegistry`

Current reachable surface:

```ts
refresh()
getError()
getAll()
getAvailable()
find(provider, modelId)
hasConfiguredAuth(model)
getApiKeyAndHeaders(model)
getProviderAuthStatus(provider)
getProvider(provider)
getProviderDisplayName(provider)
getProviderAuth(provider)
getApiKeyForProvider(provider)
isUsingOAuth(model)
registerProvider(...)
unregisterProvider(...)
getRegisteredProviderConfig(provider)
getRegisteredNativeProvider(provider)
getRegisteredProviderIds()
```

# 11. Extension-host and helper exports

_Source: package exports in [`packages/coding-agent/src/index.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/index.ts), extension exports in [`core/extensions/index.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/index.ts), and host behavior in [`runner.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/runner.ts)._

The package root exports host-side machinery for SDK integrations:

- `createExtensionRuntime`
- `discoverAndLoadExtensions`
- `ExtensionRunner`
- `wrapRegisteredTool`
- `wrapRegisteredTools`
- `createEventBus`
- `defineTool`
- all tool-event type guards

`ExtensionRunner` publicly exposes:

- core/context binding
- command-context binding
- UI/mode binding
- extension paths
- registered tools
- flags and flag values
- shortcuts and diagnostics
- commands and diagnostics
- message/entry renderers
- active tools
- error subscription
- stale-runtime invalidation
- ordinary and command context creation
- generic event emission
- specialized chained emissions for input, context, provider payloads/headers, tools, messages, resources, and agent startup

Public TUI helpers intended for extensions include:

- `CustomEditor`
- `ExtensionEditorComponent`
- `ExtensionInputComponent`
- `ExtensionSelectorComponent`
- `ToolExecutionComponent`
- `AssistantMessageComponent`
- `UserMessageComponent`
- `CustomMessageComponent`
- `BranchSummaryMessageComponent`
- `CompactionSummaryMessageComponent`
- selector/dialog/footer/header primitives
- `renderDiff`
- `truncateToVisualLines`
- `keyHint`, `rawKeyHint`, `keyText`
- `Theme`
- `highlightCode`
- `getLanguageFromPath`
- Markdown/select/settings theme helpers

# 12. Node graph—adjacency list

_This graph is synthesized from the extension types, loader, runner, session owner, model registry, and mode integrations linked above._

```text
Extension source
  -> project trust
  -> discovery
  -> TypeScript/JavaScript loader
  -> ExtensionFactory

ExtensionFactory
  -> ExtensionAPI
  -> registrations
  -> initial provider-registration queue

ExtensionAPI
  -> event subscriptions
  -> tool registry
  -> command registry
  -> shortcut registry
  -> flag registry
  -> message renderer registry
  -> entry renderer registry
  -> provider registry
  -> inter-extension EventBus
  -> session/model/tool actions

Event subscription
  -> ExtensionEvent
  -> ExtensionContext
  -> optional interception result

project_trust
  -> ProjectTrustContext
  -> trust decision
  -> project extension/resource admission

resources_discover
  -> skill paths
  -> prompt paths
  -> theme paths
  -> ResourceLoader

ExtensionContext
  -> ExtensionUIContext
  -> ReadonlySessionManager
  -> ModelRegistry
  -> current model
  -> current abort signal
  -> run/queue state
  -> context usage
  -> compaction
  -> effective system prompt

ExtensionCommandContext
  -> ExtensionContext
  -> waitForIdle
  -> newSession
  -> fork
  -> navigateTree
  -> switchSession
  -> reload

newSession / fork / switchSession
  -> session replacement
  -> stale old context
  -> ReplacedSessionContext
  -> awaited sendMessage/sendUserMessage

ExtensionUIContext
  -> dialogs
  -> notifications
  -> terminal input
  -> editor
  -> autocomplete
  -> widgets
  -> header/footer/title
  -> working presentation
  -> custom focused component
  -> themes
  -> tool expansion

Custom UI
  -> pi-tui TUI
  -> pi-tui Component
  -> Theme
  -> KeybindingsManager
  -> OverlayHandle

registerTool
  -> ToolDefinition
  -> TypeBox parameter schema
  -> Agent tool catalog
  -> system-prompt snippets/guidelines
  -> model tool call

model tool call
  -> tool_call event
  -> argument mutation/blocking
  -> ToolDefinition.execute
  -> ExtensionContext
  -> partial updates
  -> AgentToolResult
  -> tool_result event
  -> result replacement
  -> tool_execution_* lifecycle
  -> session persistence
  -> provider context

ToolDefinition rendering
  -> renderCall
  -> renderResult
  -> ToolRenderContext
  -> pi-tui Component
  -> transcript

registerCommand
  -> slash-command catalog
  -> argument completion
  -> ExtensionCommandContext
  -> session/model/UI operations

sendMessage
  -> CustomMessage
  -> session journal
  -> provider context
  -> optional MessageRenderer
  -> transcript

appendEntry
  -> CustomEntry
  -> session journal
  -X provider context
  -> optional EntryRenderer
  -> transcript

setSessionName / setLabel
  -> SessionManager
  -> session_info_changed / session tree
  -> selectors and navigation

context event
  -> live AgentMessage[]
  -> provider context replacement

before_agent_start
  -> prompt/system-prompt transformation
  -> agent run

before_provider_request
  -> serialized provider payload replacement

before_provider_headers
  -> provider headers mutation

after_provider_response
  -> provider response observation

registerProvider
  -> ModelRegistry
  -> provider authentication
  -> model catalog
  -> model selector
  -> stream implementation

setModel / setThinkingLevel
  -> AgentSession
  -> model_select / thinking_level_select
  -> persistence
  -> subsequent provider requests

pi.events
  -> named channel
  -> other extensions

LoadExtensionsResult
  -> loaded Extension records
  -> load errors
  -> shared ExtensionRuntime
  -> ExtensionRunner

ExtensionRunner
  -> AgentSession integration
  -> mode-specific UI context
  -> event ordering/chaining
  -> error isolation
  -> stale-runtime rejection
```

## Differences from Zi’s `0e6909f0` pin

_Source comparison: [pinned `types.ts`](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/extensions/types.ts) versus [current `types.ts`](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/extensions/types.ts), plus the corresponding [pinned](https://github.com/badlogic/pi-mono/blob/0e6909f050eeb15e8f6c05185511f3788357ddb3/packages/coding-agent/src/core/model-registry.ts) and [current](https://github.com/badlogic/pi-mono/blob/fc85bdd88be93b1e9a6b6bcfa41c684282ec79cc/packages/coding-agent/src/core/model-registry.ts) model registries._

Current HEAD adds:

- `ExtensionContext.thinkingLevel`
- tool-result `usage`
- branch-summary-result `usage`
- native `registerProvider(provider: Provider)`
- dynamic `ProviderConfig.refreshModels()`
- deprecated OAuth `usesCallbackServer`
- hidden inline/loaded extensions
- additional native-provider lookup methods on `ModelRegistry`

Everything else above is already present at Zi’s pinned extension reference.

The central architectural fact is that Pi’s extension contract is not narrow: it exposes session trees, models, provider transport, mutable preflight events, shell execution, direct TUI components, keybindings, and session replacement. It is effectively a privileged in-process coding-agent SDK.
