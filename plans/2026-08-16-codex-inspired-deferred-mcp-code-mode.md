# Add Codex-inspired deferred MCP tools through Code Mode

Research basis: OpenAI Codex `a95a6fe333c276623ef172f9f7825ac2790be184`, Grok Build `d6a22a1aed70b58d30a0f82a1a2a76ce1301631e`, DeepSeek Harness `47f943859bef60e4160492346772ded9b24f765a`, and OpenCode `4643e65ad6334de3e4e68dedc201d5fbb828c9fe`.

Upstream evidence is concentrated in Codex `codex-rs/codex-mcp/src/connection_manager.rs` and `codex-rs/core/src/mcp_tool_exposure.rs`; Grok Build `crates/codegen/xai-grok-shell/src/session/managed_mcp.rs` and `mcp_dispatcher.rs`; DeepSeek Harness `packages/mcp/mcp-client/src/connection.ts` and `tools.ts`; and OpenCode `packages/opencode/src/mcp/index.ts`, `packages/opencode/test/mcp/session-recovery.test.ts`, and its pinned SDK patch. These are provenance, not dependencies.

## Goal

Add native MCP client support without placing every remote tool definition in the provider request. Zi connects admitted MCP servers, retains their bounded tool catalogs outside model context, and exposes four stable Code Mode operations: search, describe, call, and status.

The first acceptance path is one trusted project stdio server. A model uses `zi.mcp_search` and `zi.mcp_describe` to select a tool, calls it through `zi.mcp_call`, sees the bounded result, reloads configuration without restarting Zi, and leaves no child process after session disposal.

The design adopts Codex's decision to withhold deferred tool definitions from the initial provider tool list and its connection-set ownership, Grok's explicit lifecycle and trust gate, and DeepSeek's serialized catalog synchronization, stale-generation fences, and fresh-client reconnect supervisor. The constant-size Code Mode search/describe/call/status facade is Zi-specific. Zi also deliberately differs from OpenCode by never replaying a failed session-bound POST because an external tool effect may already have happened.

## Product contract

MCP is executable configuration. Global MCP settings are user-admitted; project MCP settings are excluded until Zi admits the project `.zi` directory through its existing trust owner. Enabling a server means its tools may be called by the model through Code Mode. This program does not add a separate approval system.

The complete MCP catalog never enters the system prompt or the `code` tool description. Code Mode describes only four fixed operations, so provider-visible schema cost stays constant as configured servers add tools.

A normal interaction is:

```ts
const matches = await zi.mcp_search({ query: "search GitHub source", limit: 5 })
const selected = matches[0]
if (!selected) return "No matching MCP tool"

return { selected, contract: await zi.mcp_describe({ server: selected.server, tool: selected.tool }) }
```

After the model sees the selected contract:

```ts
return await zi.mcp_call({ server: "github", tool: "search_code", arguments: { query: "McpHost repo:with-zi/zi" } })
```

Code Mode may compose known MCP calls with ordinary Zi tools, loops, filtering, `Promise.allSettled`, `scratch`, and bounded program state. A call still crosses the normal Zi tool seam, so tracing, cancellation, deadlines, argument bounds, and tool progress remain visible.

## Decisions

| Question                             | Decision                                                                                         |
| ------------------------------------ | ------------------------------------------------------------------------------------------------ |
| Where does MCP live?                 | `packages/coding-agent`; the terminal is only a projection.                                      |
| What owns connections?               | One root-session `McpHost`.                                                                      |
| What does the provider see?          | The existing `code` tool, not discovered MCP tools.                                              |
| What does Code Mode see?             | `mcp_search`, `mcp_describe`, `mcp_call`, and `mcp_status`.                                      |
| Which transports ship first?         | stdio and Streamable HTTP.                                                                       |
| Which MCP capabilities ship first?   | Tools and `tools/list_changed` only.                                                             |
| How are tools identified?            | Configured server key plus raw MCP tool name.                                                    |
| Are remote schemas compiled locally? | No. Zi validates bounded JSON and the server owns domain-schema validation.                      |
| Are failed calls retried?            | Never; a timed-out or disconnected call may already have caused an external effect.              |
| Does connection loss retry?          | A terminal connection generation retries with a bounded fresh-client policy; calls never replay. |
| Are catalogs persisted?              | No. Resume reconnects and rediscovers from current admitted configuration.                       |
| Do subagents inherit MCP?            | Not in this program; inheritance waits for the root agent-team owner to settle.                  |

Capability ownership and projection remain separate:

| Projection                            | Initial contract                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Native coding-agent capability        | `McpHost.search`, `describe`, `call`, `snapshot`, `reload`, `subscribe`, and `dispose`                 |
| Direct provider tools                 | None                                                                                                   |
| Code Mode                             | Four stable adapters: `mcp_search`, `mcp_describe`, `mcp_call`, and `mcp_status`                       |
| User command/TUI                      | Bounded startup and reload diagnostics only; no management screen or parser                            |
| RPC and other external clients        | Session status snapshots and `mcp_server_changed`; no RPC method that bypasses the session tool policy |
| Later optional direct tool activation | A separate adapter over `McpHost`, not a second MCP client                                             |

## What this program does not do

- No MCP prompts, resources, roots, sampling, elicitation, tasks, or Apps.
- No legacy SSE fallback or WebSocket transport.
- No OAuth, dynamic client registration, browser callback, or credential store.
- No Claude, Cursor, `.mcp.json`, or other product-compatibility discovery.
- No dynamic provider-visible MCP tools and no `mcp_activate` operation.
- No direct `mcp_search` or `mcp_call` provider tools in `direct-and-code` mode.
- No MCP-specific picker, modal, add/remove CLI, or arbitrary terminal UI.
- No automatic system-prompt injection of server instructions.
- No subagent-specific server definitions or inherited parent connections.
- No full binary image, audio, or embedded-resource delivery through Code Mode.

These are exclusions, not an implied roadmap. Each adds a separate trust, lifecycle, or presentation contract and requires its own evidence.

## Current seam

`CodeMode.createTool()` currently receives one catalog and emits a TypeScript declaration for every admitted tool in the `code` tool description. `AgentSession.#applyActiveTools()` uses the same underlying catalog for direct provider tools and Code Mode. Passing every discovered MCP tool through that path would only translate context cost from JSON schemas into TypeScript declarations.

The implementation therefore adds one narrow internal construction seam rather than a generic capability registry:

```ts
interface AgentSessionInternals {
  readonly codeOnlyTools?: readonly AgentTool[]
  readonly mcpHost?: McpHost
}

function createAgentSessionWithProcessTreeTracker(
  options: CreateAgentSessionOptions,
  processTree: AgentSessionProcessTree,
  internals?: AgentSessionInternals
): Promise<CreateAgentSessionResult>
```

The exported `CreateAgentSessionOptions` and `createAgentSession()` SDK contract do not change. The production runtime is the only initial MCP constructor and passes root-owned internals through the package-private session factory. `options.tools` keeps its current meaning: direct when the surface is `direct-and-code`, and available through Code Mode whenever Code Mode exists. Internal `codeOnlyTools` are never placed directly in `Agent.state.tools`; they are appended only when constructing the `code` tool.

```ts
const reservedNames = new Set([...baseTools, ...agentTools, ...codeOnlyTools].map(tool => tool.name))
const directTools = admitExtensionTools([...baseTools, ...agentTools], extensionHost, activeExtensions, reservedNames)
const codeTools = Object.freeze([...directTools, ...codeOnlyTools])
const codeTool = codeMode?.createTool(codeTools)

agent.state.tools = !codeTool ? [...directTools] : toolSurface === "code-only" ? [codeTool] : [...directTools, codeTool]
```

The system-prompt capability projection continues to inspect the underlying Code Mode catalog so `code-only` file, shell, plan, and skill guidance stays correct. MCP adds no separate system-prompt section; its complete contract is in the four declarations inside the bounded `code` tool description.

Code-only names participate in built-in collision admission even though they are not direct tools. An extension named `mcp_search`, `mcp_describe`, `mcp_call`, or `mcp_status` receives the normal reserved-name diagnostic and is not admitted. A runtime-supplied base tool collision rejects session construction with a bounded configuration error rather than shadowing the native adapter. The final Code Mode uniqueness check remains a backstop. The program reserves these exact names, not the whole `mcp_` prefix.

`codeOnlyTools` remains an internal construction input. Extensions do not gain a new visibility flag in this program, and Zi does not introduce a general tool-exposure framework before another concrete capability needs it.

## Owner map

| Owner                  | Authoritative state and resources                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `SettingsManager`      | Admitted global/project MCP configuration layers and deterministic server-name precedence                                                   |
| `McpHost`              | Resolved server plans, server states, SDK clients, transports, catalog generations, reconnect timers, calls, status snapshots, and shutdown |
| Internal server record | One configured identity, connection generation, catalog, refresh state, and reconnect budget                                                |
| `AgentSession`         | Code-only tool admission, session event projection, reload admission, and root ownership of host disposal                                   |
| `CodeMode`             | Program execution, nested-call scheduling, Code Mode JSON, progress trace, and worker lifecycle                                             |
| `OwnedStdioTransport`  | One stdio child process, JSONL protocol streams, stderr tail, process-tree scope, and bounded close                                         |
| MCP server             | Domain validation and external side effects after `tools/call` is admitted                                                                  |

`McpHost` is the deep module. Callers search, describe, call, inspect, reload, and dispose. They do not access SDK clients, transport handles, catalog maps, timers, or server records.

## Configuration

Settings gain a server map:

```ts
export type McpServerConfig = McpDisabledServerConfig | McpStdioServerConfig | McpHttpServerConfig

export interface McpDisabledServerConfig {
  readonly enabled: false
}

export interface McpServerBaseConfig {
  readonly enabled?: true
  readonly required?: boolean
  readonly startupTimeoutMs?: number
  readonly toolTimeoutMs?: number
}

export interface McpStdioServerConfig extends McpServerBaseConfig {
  readonly transport: "stdio"
  readonly command: readonly string[]
  readonly cwd?: string
  readonly environment?: Readonly<Record<string, string>>
  readonly environmentFrom?: readonly string[]
}

export interface McpHttpServerConfig extends McpServerBaseConfig {
  readonly transport: "streamable-http"
  readonly url: string
  readonly headers?: Readonly<Record<string, string>>
  readonly headerEnvironment?: Readonly<Record<string, string>>
}

export interface AgentSettings {
  readonly mcpServers?: Readonly<Record<string, McpServerConfig>>
}
```

Example:

```json
{
  "mcpServers": {
    "github": {
      "transport": "stdio",
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "environmentFrom": ["GITHUB_TOKEN"],
      "startupTimeoutMs": 30000,
      "toolTimeoutMs": 60000
    },
    "internal-search": {
      "transport": "streamable-http",
      "url": "https://mcp.example.com/mcp",
      "headerEnvironment": { "Authorization": "INTERNAL_MCP_AUTHORIZATION" }
    }
  }
}
```

Global, project, and runtime override maps merge by configured server name. A higher layer replaces the complete lower-layer server definition; fields do not deep-merge. `{ "enabled": false }` disables that effective name without repeating or deleting the lower definition. Project entries participate only when project configuration is trusted.

`packages/coding-agent/src/mcp/config.ts` validates the external JSON shape through compiled TypeBox guards and performs cross-field, byte-length, URL, header, command, environment, and count checks beside the MCP domain. `SettingsManager` delegates the field to that owner instead of adding another inline record validator.

Resolution produces an immutable `McpLoadPlan`. It:

- resolves stdio cwd relative to `ZiPaths.cwd`;
- resolves a bare executable once against the captured startup environment and platform `PATH`/`PATHEXT`;
- constructs a scrubbed baseline environment and then applies explicit `environment` and `environmentFrom` values;
- resolves `headerEnvironment` values without placing secrets in snapshots or diagnostics;
- accepts only `http:` and `https:` Streamable HTTP URLs and rejects embedded URL credentials;
- records source-attributed, bounded diagnostics without retaining secret values.

The stdio baseline admits `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, and bounded `LC_*` entries on POSIX. Windows admits `PATH`, `PATHEXT`, `SystemRoot`, `ComSpec`, `TEMP`, `TMP`, `USERPROFILE`, `APPDATA`, and `LOCALAPPDATA`. Options such as `NODE_OPTIONS`, package-manager configuration, cloud credentials, and unrelated secrets require explicit configuration.

The environment is captured when the root runtime is constructed. MCP owners and reconnect attempts do not reread `process.env` or `process.cwd`.

## Bounds

```ts
export const maxMcpServers = 16
export const maxMcpStdioServers = 4
export const maxMcpStartupConcurrency = 4
export const defaultMcpStartupTimeoutMs = 30_000
export const maxMcpStartupTimeoutMs = 2 * 60_000
export const maxMcpInitialSettlementMs = 2 * 60_000
export const defaultMcpToolTimeoutMs = 60_000
export const maxMcpToolTimeoutMs = 60 * 60_000
export const maxMcpReconnectAttempts = 5
export const maxMcpProtocolMessageBytes = 1024 * 1024
export const maxMcpHttpHeaderBytes = 64 * 1024
export const maxMcpSseLineBytes = 64 * 1024
export const maxMcpSseEventBytes = 1024 * 1024
export const minMcpSseRetryMs = 100
export const maxMcpSseRetryMs = 5_000
export const maxMcpSseRetries = 2
export const maxMcpCatalogPages = 32
export const maxMcpCatalogRefreshConcurrency = 4
export const maxMcpToolsPerServer = 256
export const maxMcpTools = 512
export const maxMcpCatalogBytes = 2 * 1024 * 1024
export const maxMcpCatalogCandidateBytes = 2 * 1024 * 1024
export const maxMcpToolSchemaBytes = 32 * 1024
export const maxMcpSearchResults = 8
export const maxMcpConcurrentCalls = 16
export const maxMcpArgumentsBytes = 256 * 1024
export const maxMcpCallValueBytes = 256 * 1024
export const maxMcpStderrBytes = 50 * 1024
export const maxMcpDiagnostics = 64
```

Four stdio servers add four process scopes beyond the workload named by the existing process-tree budget. This program raises `maxTrackedProcessScopes` from 20 to 24 and updates its ownership comment. A combined structural test admits the existing maxima plus four MCP scopes and rejects the twenty-fifth scope. Remote servers count toward the MCP server total but own no process scope.

Startup is bounded twice: each server has an absolute startup deadline, and the host gives all initial work a fixed two-minute settlement window. Startup concurrency is four. A required server that cannot become ready on its initial attempt rejects root runtime creation after cleanup instead of entering reconnect backoff. Optional failures may enter bounded backoff, publish explicit snapshots, and leave Zi usable.

A tool-call deadline is absolute. MCP progress may update the current nested Code Mode trace but never resets or extends the deadline.

Pagination rejects a repeated or over-bound cursor before fetching it. Page, per-server tool, host tool, schema, and aggregate encoded-byte limits are enforced while building the candidate, before it can replace a live catalog. At most four catalog fetches run concurrently, and candidates share a separate 2 MiB host reservation so simultaneous refreshes cannot multiply retained uncommitted data by the server count.

## Host and server state

The host lifecycle is separate from each connection state:

```ts
type McpHostState =
  | { readonly type: "constructed" }
  | { readonly type: "starting"; readonly controller: AbortController; readonly settled: Promise<void> }
  | { readonly type: "running" }
  | { readonly type: "reloading"; readonly operationId: number; readonly settled: Promise<McpReloadResult> }
  | { readonly type: "stopping"; readonly settled: Promise<void> }
  | { readonly type: "stopped" }
```

`start` is admitted only from `constructed`; successful bounded startup enters `running`, while a required failure cleans up and enters `stopped` before rejecting. `reload` is admitted only from `running` and always settles back to `running` unless disposal supersedes it. Search, describe, status, and calls may use unchanged ready servers while the host is `reloading`. `dispose` supersedes every non-terminal state, rejects new work, and returns the same stopping settlement to concurrent callers.

```ts
type McpCatalogRefreshState =
  { readonly type: "idle" } | { readonly type: "refreshing"; readonly operationId: number; readonly rerun: boolean }

type McpServerState =
  | { readonly type: "disabled"; readonly plan: McpResolvedServer }
  | {
      readonly type: "starting"
      readonly generation: number
      readonly plan: McpResolvedServer
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | {
      readonly type: "ready"
      readonly generation: number
      readonly plan: McpResolvedServer
      readonly client: Client
      readonly transport: McpTransportOwner
      readonly catalog: readonly McpToolDescriptor[]
      readonly refresh: McpCatalogRefreshState
      readonly connectedAt: number
    }
  | {
      readonly type: "backoff"
      readonly generation: number
      readonly plan: McpResolvedServer
      readonly previousCatalog: readonly McpToolDescriptor[]
      readonly attempt: number
      readonly retryAt: number
      readonly timer: ReturnType<typeof setTimeout>
    }
  | { readonly type: "failed"; readonly generation: number; readonly plan: McpResolvedServer; readonly message: string }
  | {
      readonly type: "stopping"
      readonly generation: number
      readonly plan: McpResolvedServer
      readonly settled: Promise<void>
    }
  | { readonly type: "stopped" }
```

Allowed transitions:

```text
load disabled config             -> disabled
enabled config                   -> starting
starting success                 -> ready
starting failure                 -> backoff | failed
starting cancellation            -> stopping -> stopped
ready list_changed               -> ready(refreshing) -> ready(idle)
ready terminal generation loss   -> backoff
backoff timer                    -> starting
backoff budget exhausted         -> failed
ready/disabled/failed/backoff    -> stopping -> stopped
stopped                          -> starting | disabled
```

A completion may commit only when its configured name, generation, and operation ID still match the authoritative record. Stale connect, refresh, close, timer, progress, and call completions are ignored after releasing resources they created.

`backoff.previousCatalog` supports comparison and diagnostics but is not searchable or callable. A disconnected server is unavailable immediately; Zi does not leave callable tools registered merely to preserve cache shape.

## Startup, reload, and reconnection

`McpHost.start(plan)` admits all server records before starting effects. Enabled servers start through the bounded concurrency owner. One server failure cannot corrupt another server's state.

Every connection generation creates a fresh SDK `Client`. Initialization awaits both the MCP handshake and the complete initial bounded `tools/list` catalog before entering `ready`. Notification handlers are installed before initial discovery so an early `tools/list_changed` schedules one serialized rerun rather than disappearing.

Catalog and call operations use the public low-level `Client.request()` with the SDK's exported `ListToolsResultSchema` and `CallToolResultSchema`. Zi intentionally does not use the `listTools()` and `callTool()` conveniences in SDK 1.30.0 because they cache tool metadata and compile advertised output schemas. Low-level requests preserve protocol-shape validation without importing remote domain schemas into a second validation owner.

`McpHost.reload(plan)` runs only through the idle `AgentSession.reload()` operation:

- unchanged resolved definitions keep their live clients and reconnect budgets;
- removed or newly disabled definitions stop;
- added definitions start;
- changed definitions stop their old generation before starting the replacement, preventing overlapping local processes;
- malformed candidate settings retain the previous MCP host plan and return diagnostics;
- a valid changed definition whose replacement fails remains explicitly failed rather than pretending the old configuration still applies.

Catalog refresh fetches and validates a complete candidate without mutating the current catalog. Fetch or validation failure leaves the ready generation and previous catalog intact and records a bounded diagnostic. Successful validation replaces the catalog in one assignment and emits one semantic server-changed notification.

A terminal connection-generation failure never retries an interrupted `tools/call`. Stdio process exit is terminal. For Streamable HTTP, the SDK owns bounded resumable SSE stream recovery for standalone GET and event-ID-bearing request-response streams; it resumes through GET plus `Last-Event-ID` and never replays the POST. SSE `onerror` records diagnostics but does not pretend that SDK `onclose` reported remote loss. A terminal initialize, list, or call request failure such as an invalidated HTTP session retires the current generation only after returning that call failure, then enters host backoff without replay.

Backoff creates fresh clients. Timers are unref'd, one timer belongs to one server state, and disposal clears it. A connection that remains ready for the maximum backoff interval resets the outage attempt budget; a crash loop exhausts after five attempts and becomes failed until reload.

## Transport ownership

Zi depends on an exact catalog-pinned `@modelcontextprotocol/sdk` version, initially `1.30.0`. The SDK owns MCP protocol types, client negotiation, Streamable HTTP behavior, and exported result-schema validation. Zi does not implement a second JSON-RPC client.

The SDK's standard stdio transport manages its immediate child with bounded TERM/KILL escalation, but that child and its descendants remain outside Zi's `ProcessTreeTracker` ownership. Zi therefore does not use it. `packages/coding-agent/src/mcp/stdio-transport.ts` implements the SDK `Transport` interface over `spawnOwnedProcess({ type: "raw" })`:

- stdin carries bounded JSONL requests;
- stdout carries bounded UTF-8 JSONL protocol records and no diagnostics;
- stderr feeds one bounded tail for status diagnostics;
- the existing `ProcessTreeTracker` owns descendants and process-group termination;
- malformed framing, non-UTF-8 input, stdout overflow, process exit, or containment failure closes that generation;
- graceful close ends stdin and waits boundedly before terminating the process tree;
- forced cleanup remains with the process owner.

The adapter may reuse public SDK framing primitives where they preserve these bounds, but it does not reach through private SDK fields or patch installed source.

Streamable HTTP uses `StreamableHTTPClientTransport` with a public SDK fetch hook. The hook bounds total headers and finite non-SSE response bodies before handing decoded protocol data to the client. Long-lived SSE responses instead pass through an owned incremental transform that bounds each line and event, preserves backpressure, and rewrites any server `retry:` value into the 100–5,000 ms interval before the SDK parser sees it. This closes SDK 1.30.0's unbounded server-provided retry-delay seam.

Explicit HTTP close belongs to the server generation. The SDK's resumable SSE policy is limited to two attempts, now with transformed bounded delay; host reconnection is reserved for terminal request/session evidence, not every SSE error. If the pinned SDK cannot supply its fetch and retry controls through supported hooks, Streamable HTTP does not ship until a separate owned transport is designed; Zi does not patch globals or SDK private state. No retry wrapper replays POST requests.

The owned fetch hook publishes typed transport evidence rather than requiring message parsing. Network failure and HTTP 404, 410, or 5xx retire the generation after the current operation fails; 401 and 403 become failed status until reload; an MCP JSON-RPC application error fails only its operation. This classification can be narrowed by protocol tests, but unknown errors fail the operation and do not trigger speculative reconnect or replay.

## Catalog and search

A descriptor preserves raw protocol identity:

```ts
export interface McpToolDescriptor {
  readonly server: string
  readonly name: string
  readonly description: string
  readonly inputSchema: SessionJson
  readonly outputSchema?: SessionJson
}
```

The configured server name and raw MCP name are never reconstructed from a display or qualified name. Duplicate raw names in one server catalog reject the candidate. Tools whose advertised execution metadata requires MCP task-based execution are omitted with a bounded diagnostic because tasks are outside this program; they can never be described or called through the facade. Execution metadata is validated while constructing the candidate, and supported values need not be retained after admission. Tool names, descriptions, and schemas are bounded before publication.

`McpHost` does not retain a second mutable search index. At most 512 descriptors are scanned directly. Search normalizes ASCII case and ranks exact name, name token, server, then description token matches with deterministic server/name tie-breaking. It does not call a model, embed text, access the network, or mutate selection.

Search returns compact identity and clipped description only:

```ts
interface McpToolMatch {
  readonly server: string
  readonly tool: string
  readonly description: string
}
```

`mcp_describe` returns one full bounded descriptor. This prevents one broad query from copying eight complete schemas into model context. A Code Mode cell can search and describe its selected result in one execution.

Only ready servers participate in search, describe, or call. `mcp_status` is the explicit path for disabled, starting, backoff, and failed evidence.

## Code Mode operations

`packages/coding-agent/src/mcp/tools.ts` constructs four `CodeModeCapableTool` values closed over one host. They are supplied through `codeOnlyTools`.

```ts
mcp_search(input: {
  query: string
  server?: string
  limit?: number
}): Promise<readonly McpToolMatch[]>

mcp_describe(input: {
  server: string
  tool: string
}): Promise<McpToolDescriptor>

mcp_call(input: {
  server: string
  tool: string
  arguments: Record<string, CodeModeJson>
}): Promise<McpCallValue>

mcp_status(input: {
  server?: string
}): Promise<readonly McpServerSnapshot[]>
```

Inputs use TypeBox object schemas and the normal Pi argument validator. Search query, identity, argument encoding, and result encoding have domain byte bounds beyond schema shape checks.

The four operations have no direct model-visible projection in `direct-and-code`. A model invokes them through a `code` cell. In global `code-only`, they join the same Code Mode catalog as all other Zi operations.

The model can leave intermediate results inside the code realm or `scratch`; only returned/logged values enter the provider-visible code result. Durable `state` remains subject to Code Mode's existing 256 KiB commit bound and is not an MCP catalog cache.

## Calls and results

`McpHost.call(server, tool, arguments, signal, onProgress)` captures the ready generation and exact descriptor before admission. It rejects unknown, unavailable, stale, over-bound, over-concurrency, or cancelled calls before `tools/call` starts.

The host retains at most 16 active call records, each containing call ID, server name, connection generation, deadline, controller, and a reason state: `active`, `caller_cancelled`, `deadline_exceeded`, `generation_lost`, `server_replaced`, or `host_disposed`. Admission inserts the record before starting the SDK effect. Signal, timer, reload, and disposal paths transition the local reason before aborting the SDK request, allowing trace details to distinguish cancellation from timeout even when the SDK reports both as request-timeout errors. Every settlement removes exactly that record; settled calls are not retained.

The outer `mcp_call` schema validates that arguments are a bounded JSON object. This program deliberately does not compile arbitrary untrusted MCP JSON Schema inside Zi. The selected MCP server remains the domain validator for its advertised input and output schemas. Zi preserves those schemas for model inspection and validates only the protocol result shape through the SDK's exported result schemas.

A call forwards the invocation `AbortSignal` and an absolute timeout to the SDK. Progress messages are reduced to bounded text for the current nested Code Mode call and never reset the deadline. Cancellation transitions the local reason, stops waiting, and lets the SDK send `notifications/cancelled` when supported, but Zi does not claim that a remote side effect was rolled back.

`isError: true` becomes a failed nested Zi call with bounded server text. Transport error, timeout, cancellation, and MCP application error remain distinct details for tracing even when their model-facing message is concise.

The first result projection retains:

- bounded text content blocks;
- bounded JSON `structuredContent`;
- metadata placeholders for image, audio, resource, resource-link, or unsupported blocks.

Binary payloads and embedded resource bodies are discarded before the value crosses into Code Mode. The placeholder includes type and MIME type when present, never base64 data. Aggregate encoded value is limited to 256 KiB. Text truncation says how many bytes were omitted; there is no unbounded spill file in this program.

The `CodeModeToolContract` returns the decoded `McpCallValue` to the program while the normal `AgentToolResult` renders a concise JSON/text projection and `McpToolDetails` for the nested trace.

## Status and diagnostics

```ts
export type McpServerSnapshot =
  | { readonly name: string; readonly status: "disabled" }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "starting" }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "ready"; readonly tools: number }
  | {
      readonly name: string
      readonly transport: McpTransport
      readonly status: "backoff"
      readonly attempt: number
      readonly retryAt: number
      readonly message: string
    }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "failed"; readonly message: string }
  | { readonly name: string; readonly transport: McpTransport; readonly status: "stopping" }
```

Snapshots never include commands, environment values, URLs with query strings, headers, or credentials. Messages are bounded and scrubbed at their source.

`McpHost.subscribe()` emits one server name after an authoritative status or catalog transition. `AgentSession` translates that to `mcp_server_changed`; in-process clients query the current snapshot rather than receiving copied catalog data in every event.

`AgentSession.mcpHostSnapshot` follows the existing extension snapshot pattern. `RpcSessionState` gains a bounded `mcp` snapshot included in the initial `ready` result, so transitions that occurred before RPC subscription are observable. On `mcp_server_changed`, `RpcMode` reads the authoritative snapshot and emits one `mcp_status` notification containing that bounded projection. RPC does not expose search, describe, or call methods that bypass Code Mode.

CLI modes write initial MCP warnings to stderr without contaminating JSON or RPC stdout. Interactive mode shows the first startup failure plus an omitted count using the existing bounded notification path. Reload returns an `McpReloadResult` so the current reload notification can report the first MCP failure beside settings, resources, and extensions.

There is no dedicated MCP screen in this program. `mcp_status` gives the model operational evidence, while session snapshots and events give embedding/RPC clients a stable future seam.

## Session ownership and disposal

When Code Mode is enabled, the production root runtime resolves the plan, creates `McpHost`, and passes it to the root `AgentSession` as an owned resource. The four facade tools are created once and passed as `codeOnlyTools`. Runtime construction owns the host until session construction succeeds; every failure path disposes the candidate host before disposing the shared process tracker. Ownership transfers exactly once to the returned root session.

When Code Mode is disabled, MCP configuration is inert and no server, secret reference, client, or process is resolved; the runtime reports one bounded warning that MCP requires Code Mode.

The host is not persisted. A resumed session creates a new host from current admitted settings and current captured environment. Existing conversation history retains prior Code Mode source and bounded results; it does not claim that an old external server is still available.

This program does not pass the host or facade tools into child-session construction. That avoids duplicate server processes and avoids inventing lifetime rules while the root agent-team control plane is changing. A later inheritance design must distinguish root ownership from borrowed child access and must stop child work before root host disposal.

`AgentSession.dispose()` stops admitting new MCP calls, aborts active host operations, clears reconnect timers, closes transports, and waits within the existing session settlement path. `waitForIdle()` includes host settlement. Only the root session that received the owned host disposes it; Code Mode, tools, clients, and UI projections never do.

The root process tracker remains last. `McpHost.dispose()` requests its owned stdio scopes to settle, while final process-tracker disposal remains the containment backstop for a server that violates graceful close.

## Runtime invariants

`packages/coding-agent/src/mcp/invariant.ts` observes owner-local facts:

- one configured name has at most one live connection generation;
- a generation publishes at most one ready client and one active catalog;
- only the current ready generation admits a call;
- catalog refresh replaces all descriptors or none;
- reconnect attempt and generation identities are monotonic;
- active stdio, total server, catalog item, catalog byte, and diagnostic counts never exceed their production bounds;
- stopped host implies no live client, transport, reconnect timer, refresh, or active call remains;
- each owned stdio process scope is disposed exactly once.

Diagnostics do not replace unconditional config validation, protocol validation, bounds, identity checks, or cleanup.

## File-tree change

```diff
 package.json                                  # pin MCP SDK in the workspace catalog
 packages/coding-agent/package.json            # add exact catalog dependency
 packages/coding-agent/src/
+├── mcp/
+│   ├── config.ts                             # settings validation, precedence, env/path resolution
+│   ├── host.ts                               # server state, catalogs, calls, reload, reconnect, disposal
+│   ├── stdio-transport.ts                    # SDK transport over OwnedProcess
+│   ├── http-transport.ts                     # bounded fetch and incremental SSE retry transform
+│   ├── tools.ts                              # four Code Mode facade tools and result projection
+│   └── invariant.ts                          # owner-local lifecycle diagnostics
 ├── agent-session.ts                          # owned host, code-only tools, events, reload, settlement
 ├── sdk.ts                                    # codeOnlyTools construction seam
 ├── runtime.ts                                # resolve plan and construct owned host
 ├── runtime-options.ts                        # snapshot in-memory MCP overrides through settings
 ├── settings-manager.ts                       # merge mcpServers by configured name
 ├── guards.ts                                 # shared primitive guards only where repeated
 ├── code-mode/code-mode.ts                    # direct catalog plus code-only catalog
 ├── processes/process-tree.ts                 # raise the combined scope bound from 20 to 24
 ├── rpc/protocol.ts                           # initial MCP snapshot and status notification
 ├── rpc/rpc-mode.ts                           # project authoritative host status into RPC
 ├── system-prompt.ts                          # derive capabilities from Code Mode catalog
 └── index.ts                                  # deliberate status/config types only

 packages/coding-agent/test/
+├── mcp-config.test.ts
+├── mcp-host.test.ts
+├── mcp-code-mode.test.ts
+├── mcp-rpc.test.ts
+└── fixtures/mcp-server.ts

 packages/cli/src/run.ts                       # bounded initial diagnostics on stderr
 packages/tui/src/interactive/interactive-mode.ts # first startup diagnostic only
 packages/tui/src/interactive/prompt/store.ts  # reload diagnostic projection
 docs/
+├── mcp.md                                    # configure and use MCP through Code Mode
 ├── index.md                                  # manual link
 └── settings.md                               # mcpServers field and trust warning
```

No new workspace package is introduced. MCP is a universal coding-agent capability, not a terminal feature or an extension API.

## Structural tests

Tests use real protocol fixtures at the transport edge and ordinary `AgentSession`/Code Mode interfaces above it. They do not mock SDK internals or assert implementation call counts.

Required behavior:

- global/project/runtime server precedence replaces whole definitions by name;
- public `CreateAgentSessionOptions` remains unchanged and internal code-only names cannot collide with runtime or extension tools;
- untrusted project MCP configuration never resolves secrets or spawns a process;
- malformed URLs, commands, headers, env references, timeouts, names, and over-capacity maps fail at admission;
- bare executable resolution works on POSIX and Windows path conventions;
- stdio initializes, lists, searches, describes, calls, reports progress, and shuts down with descendants;
- startup or session-construction failure disposes the not-yet-transferred host before the process tracker;
- Streamable HTTP initializes and calls with resolved non-secret headers;
- required startup failure rejects runtime creation; optional failure produces a usable session and diagnostic;
- repeated cursors, too many pages/tools, oversized schemas/catalogs, duplicate names, malformed protocol data, and stdout overflow fail the candidate without partial publication;
- task-required tools are omitted with diagnostics and cannot be described or called;
- extension startup, reload, and `setActiveTools()` collisions with exact native MCP facade names produce bounded diagnostics rather than breaking Code Mode reconstruction;
- `tools/list_changed` performs fetch-before-swap and a failed refresh retains the prior ready catalog;
- stale connect, close, refresh, call, timer, and reload completion cannot mutate a newer generation;
- stdio exit and terminal HTTP request/session failure never replay a tool call and start at most one host reconnect timer;
- Streamable HTTP SSE errors use two SDK recovery attempts, server retry values are clamped to bounded delay, request-response streams resume without POST replay, and none masquerade as remote `onclose` events;
- reconnect exhaustion removes server availability and reload can recover it;
- cancellation and timeout settle the nested Code Mode call and do not extend on progress;
- result text and structured content stay within bounds; binary blocks become metadata placeholders;
- secrets never appear in snapshots, diagnostics, traces, RPC state, or stderr projections;
- RPC `ready` includes current MCP status and later authoritative transitions emit bounded `mcp_status` notifications;
- the combined existing process workload plus four MCP stdio scopes fits 24 scopes and the next scope is rejected;
- disposal clears every timer, listener, client, call, and owned process scope within bounds.

The context-efficiency acceptance test creates one server with one tool and one with the maximum catalog, then asserts that the provider-visible direct tool list and `code` tool description are byte-identical. Search and describe results may differ only after the model invokes them.

The exposure acceptance test in `direct-and-code` verifies that `mcp_search`, `mcp_describe`, `mcp_call`, and `mcp_status` are absent from `Agent.state.tools`, present on `zi.*` inside a code cell, and visible as nested calls in Code Mode trace details.

## Implementation slices

### Slice 1: one stdio tool through Code Mode

Write the context-efficiency and exposure tests first. Add `codeOnlyTools`, the minimal config parser, one owned stdio transport, `McpHost` startup/disposal, and the four facade tools. Prove this complete path with a real fixture:

```text
trusted project settings -> root runtime -> stdio initialize/tools/list
-> code cell mcp_search + mcp_describe -> next code cell mcp_call
-> bounded result and nested trace -> session dispose -> process tree empty
```

Only one server and one connection generation are needed to make this slice pass, but the final configured identity and state union are used from the start. No temporary extension implementation or provider-visible MCP tool backend is introduced.

### Slice 2: bounded catalogs and live replacement

Add pagination, all catalog/schema/count byte bounds, deterministic search ranking, duplicate rejection, `tools/list_changed`, serialized rerun, atomic replacement, and stale refresh tests. Add multiple-server isolation and optional/required startup behavior.

### Slice 3: Streamable HTTP, reload, and recovery

Add the HTTP transport, header environment resolution, the bounded SSE line/event/retry transform, two-attempt SDK SSE recovery, host fresh-client recovery after terminal request/session evidence, status snapshots/events, settings reload reconciliation, and initial/reload diagnostic projections. Test no POST replay across timeout, invalidated sessions, terminal fetch errors, oversized SSE events, extreme server retry values, request-response stream resume, SSE retry exhaustion, and reload.

### Slice 4: failure and shutdown matrix

Inject failure at spawn, initialize, each catalog page, refresh, call progress, call result, stdio exit, HTTP terminal request, SSE recovery, reconnect, reload, graceful shutdown, and forced process-tree cleanup. Verify no stale publication, partial catalog, secret leakage, timer leak, scope leak, or unbounded retained output.

### Slice 5: compiled release and public contract

Add `docs/mcp.md`, settings reference, and manual navigation after behavior settles. Build the standalone executable and npm package, inspect the tarball, and run one packaged stdio fixture so SDK imports, worker paths, and native process ownership are proven outside the source workspace.

## Verification

Targeted checks during implementation:

```sh
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/mcp-config.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/mcp-host.test.ts
bun test --preload ./test/isolate-zi-home.ts packages/coding-agent/test/mcp-code-mode.test.ts
bun run --filter @with-zi/coding-agent typecheck
```

At slice boundaries:

```sh
bun run --filter @with-zi/coding-agent test
bun run --filter @with-zi/tui test
bun run --filter @with-zi/cli test
```

Before completion:

```sh
bun run check
bun run build
bun run package:npm
```

Packaged acceptance runs the built executable against the real stdio fixture with an isolated `ZI_AGENT_DIR`, confirms that only `code` is provider-visible in `code-only`, performs one MCP search/describe/call, and confirms no server descendant remains after exit.

## Acceptance

The program is complete when:

- admitted stdio and Streamable HTTP servers are usable through Code Mode;
- provider-visible tool description size is independent of discovered MCP catalog size;
- no discovered MCP tool becomes a direct provider tool;
- every external input, catalog, result, retry, process, diagnostic, and shutdown wait has a production bound;
- project MCP commands cannot start before project trust;
- connection loss never replays a tool call;
- catalog refresh is atomic and stale generations cannot publish;
- settings reload reconciles server generations without restarting Zi;
- text, JSON, RPC, and interactive modes share the same authoritative host and status events;
- session disposal leaves no MCP client, timer, listener, active call, or child process;
- the compiled standalone and npm package pass the end-to-end stdio acceptance path.
