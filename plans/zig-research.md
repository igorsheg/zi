# Unified AI Model Layer and Coding Harness Specification

**Status:** Draft 0.1
**Target:** Zig 0.16.0
**Scope:** A provider-independent model library and a coding harness built on top of it

## 1. Purpose

This document specifies a Zig-native foundation for building a coding harness that can use multiple AI providers and models through one interface.

The design follows one rule:

> Use pi as the behavioral specification and ZigAI as the Zig implementation model.

This means:

- [`earendil-works/pi/packages/ai`](https://github.com/earendil-works/pi/tree/main/packages/ai) defines the required behavior: provider collections, model lookup, normalized messages, streaming tool calls, reasoning, usage, context persistence, and cross-provider handoff.
- [`Kludex/zigai`](https://github.com/Kludex/zigai) informs the Zig representation: small erased interfaces, tagged unions, borrowed request data, arena-owned results, synchronous borrowed stream events, explicit model profiles, injected `std.Io`, and adapters isolated from orchestration.
- Neither project is to be ported literally. TypeScript runtime assumptions must not leak into Zig, and ZigAI's agent, graph, MCP, durable execution, realtime, and UI scope must not leak into this focused module.

## 2. Goals

The system must:

1. Let a coding harness invoke different providers and models through one model interface.
2. Keep provider authentication and catalogs separate from wire protocols.
3. Normalize text, reasoning, tool calls, tool results, usage, finish reasons, and streaming events.
4. Preserve provider state required to replay a conversation with the same provider.
5. Support explicit conversation handoff to another provider or model.
6. Make ownership and lifetimes visible and bounded.
7. Pass `std.Io` and allocators explicitly.
8. Allow deterministic model and transport fakes without network access.
9. Make adding a provider local: a new provider must not require edits to the harness or a central provider switch.
10. Keep the model library useful without the coding harness.

## 3. Non-goals for version 1

Version 1 will not include:

- Embeddings
- Image generation
- Speech or audio generation
- Video
- Provider-hosted file APIs
- Provider-managed tools such as web search or code execution
- MCP
- Agent graphs
- Durable workflow engines
- Multi-agent delegation
- Automatic tool-schema derivation from arbitrary Zig functions
- A universal model catalog downloaded from a central service
- Transparent fallback between models after stream output has been delivered

Image input may be included because it is directly useful to a coding harness. Other media can be added only when a concrete harness requirement exists.

## 4. Ubiquitous language

The following terms are normative.

### Model

A concrete inference target. It accepts a provider-neutral request and produces a provider-neutral response. A model has an identity and a profile.

Examples: `openai/gpt-5`, `anthropic/claude-sonnet-4`, `local/qwen3`.

### Model identity

The stable pair of `ProviderId` and `ModelId` used for lookup, persistence, diagnostics, and policy.

### Model profile

A declaration of the features and settings a model adapter guarantees. The harness uses it to reject unsupported requests before network I/O.

### Provider

The runtime owner of authentication, endpoint configuration, model discovery, model-specific compatibility, and construction of models.

A provider is not a wire protocol.

### Wire protocol

The request, response, and streaming format used by one or more providers.

Examples: OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, Gemini GenerateContent.

### Adapter

An implementation that translates between the provider-neutral model contract and one wire protocol.

### Registry

A collection of providers that resolves a model identity to a model. The registry does not perform inference itself.

### Canonical history

The provider-neutral conversation owned by a session. It is the source used to prepare each model request and to persist the session.

### Provider state

Opaque, owner-qualified data required to replay a response through a particular provider or protocol. Normal harness logic must not interpret it.

Examples include Anthropic thinking signatures, Gemini thought signatures, or OpenAI response identifiers.

### Handoff

Preparing canonical history for a model other than the model that produced some of it. Handoff may remove foreign provider state but must preserve portable conversation meaning.

### Harness

The owner of the coding loop: session history, model invocation, tool dispatch, limits, retries, and termination.

### Tool

A local operation exposed to a model through a JSON Schema definition and executed by the harness.

### Run

One bounded harness invocation, beginning with user input and ending with a final model response, cancellation, failure, or a configured limit.

## 5. Design principles

### 5.1 The model seam is the primary interface

The harness depends on `Model`, not on OpenAI, Anthropic, HTTP, or a provider enum.

### 5.2 Provider and protocol are separate

Several providers may share one protocol adapter. OpenAI, Groq, OpenRouter, and Ollama may all use an OpenAI-compatible adapter while retaining distinct authentication, endpoints, catalogs, and profiles.

### 5.3 Runtime erasure only at real seams

Runtime vtables are appropriate for models, providers, transports, tools, and test doubles because multiple implementations exist at runtime.

Wire codecs should normally use comptime composition because a concrete model's protocol is known when it is constructed. Do not add a second runtime vtable when `HttpModel(Codec)` can select the codec at compile time.

### 5.4 Requests borrow; owners own

Request values contain borrowed slices. Leaf message values do not store allocators.

Completed responses, sessions, and parsed persistence documents have one named owner and one `deinit` boundary.

### 5.5 Stream events are borrowed

Stream event payloads remain valid only during the synchronous sink callback. Consumers copy only data they need to retain.

### 5.6 Preserve meaning, not wire shapes

The canonical model must not be OpenAI's `role/content` schema or Anthropic's content block schema. Adapters translate at the wire edge.

### 5.7 Reject unsupported requests before I/O

The model profile is checked before a paid or stateful provider request begins.

### 5.8 One owner per policy

- The provider owns authentication and endpoint policy.
- The model adapter owns wire translation and provider response classification.
- The harness owns retries, tool execution, request limits, and the run deadline.
- The session owns canonical history.
- The transport owns HTTP connection behavior.

## 6. System decomposition

```text
Application
    |
    v
Harness -------------------- Tool registry
    |
    v
Model
    |
    v
Provider-built model implementation
    |
    +---- Provider configuration and model profile
    |
    +---- Comptime wire codec
    |
    v
Transport
    |
    v
Provider endpoint
```

The dependency direction is downward. Provider and protocol modules must not import the harness.

## 7. Package layout

```text
src/
  root.zig
  model.zig
  message.zig
  stream.zig
  settings.zig
  usage.zig
  failure.zig

  provider/
    Provider.zig
    Registry.zig
    auth.zig

  protocol/
    openai_responses.zig
    openai_chat.zig
    anthropic_messages.zig

  transport/
    Transport.zig
    http.zig
    sse.zig
    ndjson.zig

  harness/
    Harness.zig
    Session.zig
    Tool.zig
    persistence.zig

  testing/
    ScriptedModel.zig
    FakeTransport.zig
```

The root module should expose the model contract and provider registry. Harness types may be exposed under a `harness` namespace so applications can use the model layer independently.

## 8. Identity types

Identifiers are borrowed UTF-8 strings at runtime and owned by the configuration or registry that created them.

```zig
pub const ProviderId = []const u8;
pub const ModelId = []const u8;
pub const ProtocolId = []const u8;

pub const ModelIdentity = struct {
    provider: ProviderId,
    model: ModelId,
};
```

String identifiers are preferred over a closed enum because applications must be able to add providers and models without modifying the core module.

Empty provider and model identifiers are invalid and must be rejected during construction or persistence parsing.

## 9. Model interface

`Model` is a borrowed erased view over a concrete implementation. The concrete implementation must outlive the model and every in-flight invocation.

```zig
pub const Model = struct {
    context: *anyopaque,
    vtable: *const VTable,
    identity: ModelIdentity,
    profile: ModelProfile,

    pub const VTable = struct {
        invoke: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            request: ModelRequest,
            delivery: Delivery,
        ) ModelError!ModelResponse,
    };

    pub const Delivery = union(enum) {
        buffered,
        streaming: StreamSink,
    };
};
```

The public convenience methods are:

```zig
pub fn complete(
    self: Model,
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ModelRequest,
) ModelError!OwnedResponse;

pub fn stream(
    self: Model,
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ModelRequest,
    sink: StreamSink,
) ModelError!OwnedResponse;
```

Both methods use the same adapter operation. `complete` selects buffered delivery; `stream` selects streaming delivery.

`OwnedResponse` owns an arena and the final normalized response:

```zig
pub const ModelResponse = ResponseMessage;

pub const OwnedResponse = struct {
    arena: std.heap.ArenaAllocator,
    value: ModelResponse,

    pub fn deinit(self: *OwnedResponse) void;
};
```

The facade creates the result arena. The adapter allocates response data from that arena. Stream event data may use bounded adapter scratch memory because it is borrowed by the sink.

### 9.1 Comptime construction

Concrete implementations should not manually repeat pointer casts and vtable declarations. The model module must provide a comptime constructor:

```zig
pub fn from(
    implementation: anytype,
    identity: ModelIdentity,
    profile: ModelProfile,
) Model;
```

`Model.from` must fail at compile time unless the implementation provides the required invocation method with the exact contract.

### 9.2 Model invariants

- `identity.provider` and `identity.model` are non-empty.
- A profile that lacks `.streaming` must reject `Model.stream` before invoking the adapter.
- A response records the actual provider and model identity that produced it.
- A model implementation does not execute local tools.
- A model implementation does not retry a logical request. Retry ownership belongs to the harness.

## 10. Model profile

Use capability sets rather than a growing list of unrelated booleans.

```zig
pub const Capability = enum {
    streaming,
    tools,
    parallel_tool_calls,
    image_input,
    thinking,
};

pub const Setting = enum {
    temperature,
    top_p,
    max_output_tokens,
    stop_sequences,
    seed,
    reasoning_effort,
};

pub const ModelProfile = struct {
    capabilities: std.EnumSet(Capability) = .initEmpty(),
    settings: std.EnumSet(Setting) = .initEmpty(),
    reasoning_efforts: std.EnumSet(ReasoningEffort) = .initEmpty(),
    context_window: ?u64 = null,
    max_output_tokens: ?u64 = null,
};
```

An unknown model uses a fail-closed profile. Applications may explicitly override a discovered profile when they accept responsibility for compatibility.

Profiles describe behavior guaranteed by the configured adapter. They are not marketing metadata.

## 11. Canonical message model

Canonical history distinguishes requests from responses so invalid role/part combinations cannot be represented.

```zig
pub const Message = union(enum) {
    request: RequestMessage,
    response: ResponseMessage,
};

pub const RequestMessage = struct {
    parts: []const RequestPart,
};

pub const ResponseMessage = struct {
    parts: []const ResponsePart,
    identity: ModelIdentity,
    usage: Usage,
    finish: Finish,
};
```

### 11.1 Request parts

```zig
pub const RequestPart = union(enum) {
    user: UserContent,
    tool_result: ToolResult,
    retry_prompt: []const u8,
};
```

Instructions are request configuration, not canonical conversation history. They are carried in `ModelRequest.instructions`.

### 11.2 User content

Version 1 supports:

```zig
pub const UserContent = union(enum) {
    text: []const u8,
    image: Image,
};

pub const Image = struct {
    media_type: []const u8,
    source: union(enum) {
        bytes: []const u8,
        url: []const u8,
    },
};
```

Adapters validate media support and URL policy before network I/O.

### 11.3 Response parts

```zig
pub const ResponsePart = union(enum) {
    text: TextPart,
    thinking: ThinkingPart,
    tool_call: ToolCall,
};
```

```zig
pub const TextPart = struct {
    text: []const u8,
    provider_state: ?ProviderState = null,
};

pub const ThinkingPart = struct {
    text: []const u8,
    provider_state: ?ProviderState = null,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    provider_state: ?ProviderState = null,
};
```

A completed tool call must contain syntactically valid JSON arguments. Incomplete streamed arguments are represented only as stream deltas, never as a completed canonical `ToolCall`.

### 11.4 Tool results

```zig
pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const Content,
    outcome: enum { success, error },
};

pub const Content = union(enum) {
    text: []const u8,
    image: Image,
};
```

Tool results remain portable. A protocol adapter is responsible for translating them into its provider's required envelope.

## 12. Provider state and handoff

Provider state is structured data owned by a provider and protocol pair:

```zig
pub const ProviderState = struct {
    provider: ProviderId,
    protocol: ProtocolId,
    value: std.json.Value,
};
```

`value` must be a valid owned JSON graph when stored in a session or parsed from persistence. Arbitrary pointers and credentials are forbidden.

Normal harness logic must treat provider state as opaque.

### 12.1 Replay

An adapter may consume provider state only when:

- The state protocol matches the adapter protocol; and
- The state provider either matches the target provider or the protocol explicitly declares the state portable across providers.

Otherwise, the adapter follows the selected handoff policy.

### 12.2 Handoff policy

```zig
pub const HandoffPolicy = enum {
    reject_foreign_state,
    drop_foreign_state,
};
```

The default is `.drop_foreign_state`.

Dropping provider state must not drop portable text, thinking text, tool calls, or tool results. The canonical session is not mutated; the model-facing request view is prepared for the selected target model.

`reject_foreign_state` is intended for exact replay and debugging.

## 13. Model request and settings

```zig
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancellationToken) void;
    pub fn isCancelled(self: *const CancellationToken) bool;
};
```

`cancel` atomically and permanently changes the token to the cancelled state. `isCancelled` is safe to call from concurrent model, transport, retry, and tool operations. The caller owns the token and must keep it alive until every operation observing it has stopped.

```zig

pub const RemoteContentPolicy = struct {
    enabled: bool = false,
    allow_plain_http: bool = false,
    allowed_hosts: ?[]const []const u8 = null,
};

pub const UrlPolicy = struct {
    allowed_provider_hosts: ?[]const []const u8 = null,
    follow_provider_redirects: bool = false,
    remote_content: RemoteContentPolicy = .{},
};

pub const ModelRequest = struct {
    messages: []const Message,
    instructions: []const []const u8 = &.{},
    tools: []const ToolDefinition = &.{},
    settings: ModelSettings = .{},
    handoff: HandoffPolicy = .drop_foreign_state,
    url_policy: UrlPolicy = .{},
    failure_sink: ?FailureSink = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    cancellation: ?*const CancellationToken = null,
};
```

Settings are portable and optional:

```zig
pub const ModelSettings = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_output_tokens: ?u64 = null,
    stop_sequences: ?[]const []const u8 = null,
    seed: ?u64 = null,
    reasoning_effort: ?ReasoningEffort = null,
};
```

A non-null setting must be supported by the model profile. Unsupported settings return `error.UnsupportedSetting` before the adapter performs I/O.

Remote image URLs require `url_policy.remote_content.enabled`. HTTPS is mandatory unless its `allow_plain_http` is set, and its host allowlist is enforced when present. The transport separately enforces the provider endpoint host allowlist and provider redirect policy. A custom adapter must validate remote-content URLs before encoding them and must pass the provider portion of the policy to the transport.

Provider-specific request extensions are excluded from version 1. They may be added later only as an owner-qualified tagged union, not as `std.json.Value` merged into every request body.

## 14. Streaming contract

Streaming uses a stable indexed part lifecycle:

```zig
pub const StreamEvent = union(enum) {
    part_start: PartStart,
    part_delta: PartDelta,
    part_end: PartEnd,
    usage: Usage,
};

pub const ResponsePartStart = union(enum) {
    text,
    thinking,
    tool_call: ToolCallStart,
};

pub const ToolCallStart = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const PartStart = struct {
    index: usize,
    part: ResponsePartStart,
};

pub const PartDelta = struct {
    index: usize,
    delta: ResponsePartDelta,
};

pub const PartEnd = struct {
    index: usize,
    part: ResponsePart,
};
```

```zig
pub const ResponsePartDelta = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: ToolCallDelta,
};

pub const ToolCallDelta = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_delta: []const u8 = "",
};
```

### 14.1 Event invariants

For each part index:

1. Exactly one `part_start` is emitted. Its value identifies the part kind and may contain only the tool ID or name already known.
2. Zero or more `part_delta` events follow.
3. At most one `part_end` is emitted.
4. An index is never reused for another part.
5. Deltas for different indexes may interleave.
6. `part_end.part` contains the complete normalized part. A completed tool call has a non-empty ID and name plus syntactically valid JSON arguments.
7. The final `ModelResponse` contains the same completed parts in index order.
8. Usage events are monotonic snapshots or deltas according to one documented package-wide convention. Version 1 uses monotonic snapshots.

### 14.2 Sink lifetime

```zig
pub const StreamSinkError = error {
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

pub const StreamSink = struct {
    context: *anyopaque,
    emitFn: *const fn (*anyopaque, StreamEvent) StreamSinkError!void,
};
```

Event slices are valid only until `emitFn` returns. The sink may stop the stream by returning `error.ConsumerStopped`. Allocation and cancellation failures retain their categories. The adapter stops reading provider data and maps `ConsumerStopped` to `ModelError.StreamConsumerStopped`; `OutOfMemory` and `Cancelled` preserve their matching `ModelError` categories.

## 15. Usage and finish reasons

```zig
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
};

pub const FinishCategory = enum {
    stop,
    tool_calls,
    length,
    content_filter,
    cancelled,
    error,
    unknown,
};

pub const Finish = struct {
    category: FinishCategory,
    raw_reason: ?[]const u8 = null,
};
```

Normalized fields drive harness policy. Raw provider reasons are retained for diagnostics and forward compatibility.

Unknown usage counters may be retained as provider state or diagnostics, but must not be silently mapped onto an unrelated normalized counter.

## 16. Failure model

Adapters classify failures into stable categories:

```zig
pub const ModelError = error {
    OutOfMemory,
    Cancelled,
    TimedOut,
    UnsupportedCapability,
    UnsupportedSetting,
    InvalidRequest,
    ConnectionFailed,
    RateLimited,
    ProviderRejectedRequest,
    ProviderUnavailable,
    InvalidProviderResponse,
    StreamInterrupted,
    StreamConsumerStopped,
    HandoffRejected,
};
```

Detailed provider failure data is delivered synchronously to the optional borrowed `ModelRequest.failure_sink`:

```zig
pub const ProviderFailure = struct {
    provider: ProviderId,
    status: ?u16,
    code: ?[]const u8,
    message: []const u8,
    request_id: ?[]const u8,
    retry_after_ms: ?u64,
};

pub const FailureSink = struct {
    context: *anyopaque,
    observeFn: *const fn (*anyopaque, ProviderFailure) void,
};
```

The view is valid only during `observeFn`. One model invocation calls the sink at most once, immediately before returning its classified error. The harness supplies a sink when it needs retry metadata and copies only bounded fields it retains. Credentials and authorization headers must never be included.

The model interface must not expose mutable `lastError` state. Failure details belong to the invocation that produced them.

## 17. Provider interface

A provider is a borrowed runtime interface owned by the registry or application configuration.

```zig
pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,
    id: ProviderId,

    pub const VTable = struct {
        model: *const fn (
            context: *anyopaque,
            model_id: ModelId,
        ) ?Model,

        models: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!OwnedModelList,
    };
};

pub const ModelDescriptor = struct {
    id: ModelId,
    display_name: ?[]const u8 = null,
    profile: ModelProfile,
};

pub const OwnedModelList = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ModelDescriptor,

    pub fn deinit(self: *OwnedModelList) void;
};
```

`models` may return a static configured catalog in version 1. Dynamic discovery is optional and provider-owned.

Provider implementations must be constructible through a comptime `Provider.from` helper.

A returned `Model` is borrowed. Its `context`, identity strings, profile data, credentials, endpoint configuration, codec configuration, and transport must remain valid until every invocation using it completes. A provider therefore owns concrete model implementations in stable storage; it must never return a model view over stack-local or movable temporary state. A registry stores borrowed provider views and must not move concrete provider storage.

### 17.1 Authentication

Authentication is resolved when the concrete provider is constructed, not inside every model call.

An optional `auth` module may implement pi-like resolution with explicit precedence:

1. Credential explicitly passed to the provider constructor
2. Provider configuration
3. Credential store
4. Provider-specific environment variable

A caller that needs a different credential for one run constructs a separate provider instance. Protocol adapters receive already-resolved provider configuration. They must not read process environment variables or credential stores directly.

### 17.2 Registry

The registry:

- Owns or borrows providers according to its constructor contract.
- Rejects duplicate provider identifiers.
- Resolves `ModelIdentity` to `Model`.
- Does not perform provider fallback.
- Does not execute model requests.
- Does not contain a switch over built-in providers.

## 18. Protocol adapters

A wire adapter owns:

- Request encoding
- Authentication header placement supplied by provider configuration
- Buffered response parsing
- Stream parsing and event normalization
- Tool-call argument accumulation
- Usage normalization
- Finish-reason normalization
- Provider failure classification
- Provider-state replay and capture

A wire adapter does not own:

- Tool execution
- Harness retry policy
- Session mutation
- Model selection
- Environment lookup
- Run limits

Shared protocol code should use comptime composition:

```zig
const OpenAiModel = HttpModel(protocol.openai_chat.Codec);
```

Provider wrappers configure the shared model with endpoint, headers, model profile, and compatibility policy.

## 19. Transport

The transport is the only module that performs HTTP I/O. Its complete runtime seam is:

```zig
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const TransportRequest = struct {
    method: enum { GET, POST, PUT, DELETE },
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    url_policy: UrlPolicy = .{},
    deadline: ?std.Io.Clock.Timestamp = null,
    cancellation: ?*const CancellationToken = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
};

pub const ResponseHead = struct {
    status: u16,
    headers: []const Header,
};

pub const BodySink = struct {
    context: *anyopaque,
    startFn: *const fn (*anyopaque, ResponseHead) TransportSinkError!void,
    chunkFn: *const fn (*anyopaque, []const u8) TransportSinkError!void,
};

pub const TransportDelivery = union(enum) {
    buffered,
    streaming: BodySink,
};

pub const TransportSinkError = error {
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

pub const TransportError = error {
    OutOfMemory,
    Cancelled,
    TimedOut,
    InvalidUrl,
    UrlPolicyRejected,
    DnsFailed,
    ConnectionFailed,
    TlsFailed,
    InvalidResponse,
    ResponseTooLarge,
    ConsumerStopped,
};

pub const TransportResponse = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exchange: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            request: TransportRequest,
            delivery: TransportDelivery,
        ) TransportError!TransportResponse,
    };
};
```

Request URL, headers, and body are borrowed until `exchange` returns. `TransportResponse` headers and buffered body are allocated with the supplied allocator. In streaming mode, the returned body is empty; chunks are delivered synchronously to `BodySink` and are valid only during `chunkFn`. `ResponseHead` and its headers are valid only during `startFn`. The transport copies only bounded response headers selected by its configuration.

The transport enforces the provider endpoint portion of the URL policy, deadline, cancellation token, redirect policy, and response-size bound. Provider redirects are not followed unless `follow_provider_redirects` is true, and every redirect target is revalidated against `allowed_provider_hosts`. Remote-content policy is enforced by the adapter because the provider, rather than this transport, fetches that content.

`TransportSinkError` is limited to `OutOfMemory`, `Cancelled`, and `ConsumerStopped`. `TransportError` distinguishes allocation, cancellation, timeout, URL-policy rejection, DNS/connect/TLS failure, invalid HTTP response, response-size overflow, and consumer stop. Protocol adapters translate these categories once into `ModelError`; raw transport errors do not leak into harness policy.

The standard implementation uses Zig 0.16 `std.Io`. Tests use `FakeTransport` through the same seam.

## 20. Tool interface

A tool combines a provider-visible definition with a local executor:

```zig
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json_schema: []const u8,
};

pub const Tool = struct {
    definition: ToolDefinition,
    context: *anyopaque,
    executeFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        arguments_json: []const u8,
    ) ToolFatalError!ToolExecution,
};

pub const ToolFatalError = error {
    OutOfMemory,
    Cancelled,
    TimedOut,
};

pub const ToolExecution = union(enum) {
    success: ToolOutput,
    failure: []const u8,
};

pub const ToolOutput = struct {
    content: []const Content,
};
```

Tool names are unique within one harness run. Registration rejects an empty name, duplicates, and a parameter schema that is not a syntactically valid JSON object.

The harness dispatches only completed tool calls with syntactically valid JSON arguments. The tool owns semantic decoding and validation of its arguments in version 1.

A `.failure` execution becomes an error `ToolResult` visible to the model. `ToolFatalError` aborts the run.

For each call, the harness creates a bounded per-call arena and passes its allocator to `executeFn`. All returned slices must be static or allocated from that allocator. The harness validates output limits, deep-copies the resulting `ToolResult` into the session, and then deinitializes the per-call arena. A tool must not retain the allocator or return borrowed stack memory.

Version 1 executes multiple requested tools in call order. Bounded parallel execution may be added later without changing the model interface.

## 21. Session

`Session` is the sole owner of canonical history.

```zig
pub const Session = struct {
    // Owned canonical messages and session allocator state.

    pub fn appendRequest(... ) !void;
    pub fn appendResponse(... ) !void;
    pub fn messages(self: *const Session) []const Message;
    pub fn deinit(self: *Session) void;
};
```

Session mutation occurs only after a complete logical event:

- User input is appended before the first model request.
- A model response is appended after the adapter returns a valid normalized response.
- Tool results are appended after execution.
- A partially received response is not silently committed after interruption.

If interrupted partial output is retained, it must be represented by an explicit session record type added in a later version. Version 1 does not commit partial responses.

The session implementation may use an arena. When compaction replaces history, it must rebuild into a new arena so removed content is actually reclaimed.

## 22. Harness state machine

The harness owns an explicit run state:

```text
idle
  -> requesting_model
  -> executing_tools
  -> requesting_model
  -> completed

requesting_model -> failed
requesting_model -> cancelled
executing_tools  -> failed
executing_tools  -> cancelled
```

`executing_tools` transitions back to `requesting_model` only after every requested tool result has been appended in original call order.

### 22.1 Run algorithm

1. Validate run configuration and model capabilities.
2. Append the user request to the session.
3. Prepare a model-facing view of canonical history using the handoff policy.
4. Invoke the selected model.
5. Append the completed response to the session.
6. If the response contains no tool calls, return the final response.
7. Resolve each tool call by name.
8. Execute tools in call order.
9. Convert outputs and recoverable failures to tool results.
10. Append tool results to the session.
11. Repeat from step 3 until completion or a run limit is reached.

### 22.2 Run limits

Every run has explicit limits:

```zig
pub const RunLimits = struct {
    max_model_requests: usize = 16,
    max_tool_calls: usize = 64,
    max_tool_result_bytes: usize = 1024 * 1024,
    deadline: ?std.Io.Clock.Timestamp = null,
};
```

Limits are checked before starting the operation that would exceed them.

## 23. Retry policy

The harness is the sole owner of logical request retries.

A retry is permitted only when:

- The error category is retryable;
- No stream event has been delivered to the application;
- The retry delay is shorter than the remaining run deadline; and
- The configured attempt limit has not been reached.

The default retryable categories are:

- `ConnectionFailed`
- `RateLimited`
- `ProviderUnavailable`

`InvalidProviderResponse` is not retried by default because repeated malformed responses generally indicate an adapter or compatibility defect.

The retry policy is bounded and respects provider `retry_after_ms` when it does not exceed the remaining run deadline.

## 24. Cancellation and deadlines

A run has one monotonic deadline. Nested model and tool operations consume the remaining time; they do not restart the timeout.

Cancellation is cooperative and shared across:

- Model requests
- Streaming reads
- Retry waits
- Tool execution

An operation cancelled by the harness must be drained or joined before the run returns if it can still access run-owned memory.

## 25. Persistence

Session persistence uses a versioned JSON envelope:

```json
{ "schema": "zig-ai-session", "version": 1, "messages": [] }
```

Persistence includes:

- Canonical request and response messages
- Model identity for responses
- Usage
- Normalized and raw finish reasons
- Provider state

Persistence excludes:

- Credentials
- Provider configuration
- Function pointers
- Tool executors
- Transport state
- Allocators
- Active cancellation or deadline state

Parsing creates an owned session document. Unknown union tags are rejected. Unknown object fields may be ignored only when the schema version explicitly permits forward-compatible additions.

## 26. Testing strategy

Tests cross the same interfaces as production callers.

### 26.1 Scripted model

`ScriptedModel` implements `Model` and returns a declared sequence of normalized responses or failures. Harness tests use it instead of mocking internal functions.

Required scenarios:

- Final text response
- One tool call followed by final text
- Multiple tool calls
- Recoverable tool failure returned to the model
- Model request limit reached
- Cancellation during model invocation
- Cancellation during tool execution
- Retry before stream delivery
- No retry after stream delivery

### 26.2 Fake transport

Protocol tests use `FakeTransport` with recorded response heads and body chunks.

Each protocol adapter must be tested for:

- Request encoding
- Authentication headers
- Text streaming
- Interleaved reasoning and text
- Incremental tool arguments
- Multiple tool calls
- Usage
- Finish reasons
- Error classification
- Malformed stream data
- Cancellation

### 26.3 Cross-provider contract tests

The same normalized scenario must run against OpenAI and Anthropic adapters and produce equivalent canonical history.

A handoff test must:

1. Produce a response containing provider state with provider A.
2. Continue with provider B using `.drop_foreign_state`.
3. Verify that portable text and tool traffic remain.
4. Verify that provider A state is absent from provider B's encoded request.
5. Verify that canonical session history is unchanged.

### 26.4 Allocation tests

Owned results, persistence parsing, adapter accumulation, and session copying must be exercised with allocation-failure testing where practical.

All unit and contract tests must pass under Zig 0.16.0 with the testing allocator.

## 27. Version 1 provider scope

Version 1 should implement only enough providers to prove the seams:

1. OpenAI through either Responses or Chat Completions
2. Anthropic Messages
3. One named OpenAI-compatible provider or local endpoint

This proves:

- Two genuinely different protocols
- Protocol reuse across providers
- Provider-specific authentication
- Cross-provider handoff
- Tool-call normalization

Adding more providers before these contracts are stable is out of scope.

## 28. Acceptance criteria

Version 1 is complete when:

1. A caller can construct providers, register them, and resolve a model identity without a built-in provider switch.
2. The same harness can run an OpenAI model, an Anthropic model, and an OpenAI-compatible local model.
3. Text, thinking, tool calls, tool results, usage, and finish reasons use the same canonical types across those models.
4. Streaming tool arguments are normalized through stable indexed events.
5. The harness can complete a tool-use loop without provider-specific branches.
6. A persisted session can be parsed, resumed with the same provider, and handed off to another provider.
7. Foreign provider state is removed from the target request without mutating canonical history.
8. Requests reject unsupported settings and capabilities before transport invocation.
9. All owned values have one documented `deinit` boundary and tests report no leaks.
10. Cancellation and the run deadline reach model requests, stream reads, retry waits, and tools.
11. Protocol adapters are testable with `FakeTransport` and harness behavior is testable with `ScriptedModel`.
12. `zig build test` succeeds on Zig 0.16.0.

## 29. Implementation order

Implement in vertical slices:

### Slice 1: Model contract

- Identity
- Profile
- Messages
- Buffered model invocation
- Owned response
- Scripted model

Exit condition: a caller can run two scripted model implementations through one interface.

### Slice 2: Harness tool loop

- Session
- Tools
- Harness state machine
- Limits

Exit condition: a scripted model can request a tool and receive its result before producing final text.

### Slice 3: Streaming

- Stream sink
- Indexed part lifecycle
- Response accumulation
- Cancellation

Exit condition: scripted streaming and tool-argument accumulation satisfy the stream invariants.

### Slice 4: First real protocol

- Transport seam
- HTTP transport
- SSE
- OpenAI adapter

Exit condition: recorded OpenAI fixtures pass without network access.

### Slice 5: Second protocol and handoff

- Anthropic adapter
- Provider state
- Handoff preparation

Exit condition: cross-provider contract tests pass.

### Slice 6: Persistence and hardening

- Versioned session format
- Retry policy
- Allocation-failure tests
- Consumer example

Exit condition: every version 1 acceptance criterion passes.

## 30. Explicitly rejected designs

### Central provider enum

Rejected because adding a provider would require editing central dispatch and recompiling provider-specific branches into the harness.

### OpenAI messages as the canonical model

Rejected because reasoning signatures, rich content, provider tool protocols, and cross-provider replay do not fit without lossy or provider-specific extensions.

### Literal TypeScript port

Rejected because promises, async iterators, structural option maps, global fetch, garbage-collected ownership, and open `unknown` records do not produce a clear Zig interface.

### Full ZigAI framework extraction

Rejected because graphs, durable execution, MCP, telemetry, realtime, and UI are not required to build the model layer or coding harness.

### Allocator stored in every message

Rejected because it obscures ownership and permits related values to have unrelated lifetimes. Owners, not leaf values, hold allocators.

### Owned allocation for every stream token

Rejected because stream events are short-lived observations. Borrowed synchronous events make retention explicit and avoid per-token cleanup.

### Tool execution inside provider adapters

Rejected because tools are application operations. Providers produce tool calls; the harness decides whether and how to execute them.

## 31. Reference rule

When pi and ZigAI suggest different shapes, use this decision order:

1. Preserve pi's observable cross-provider behavior.
2. Preserve Zig's explicit ownership, error, and I/O model.
3. Keep the public model seam smaller than either implementation's total feature surface.
4. Put provider quirks in adapters or model profiles, never in harness branches.
5. Defer a feature rather than weaken the canonical types with unowned JSON or provider-specific fields.
