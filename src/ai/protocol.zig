const abort_signal_mod = @import("../zio/root.zig").abort;
const std = @import("std");

/// Known API types. Custom values supported via `.custom` variant.
pub const Api = union(enum) {
    openai_completions,
    mistral_conversations,
    openai_responses,
    azure_openai_responses,
    openai_codex_responses,
    anthropic_messages,
    bedrock_converse_stream,
    google_generative_ai,
    google_gemini_cli,
    google_vertex,
    custom: []const u8,
};

/// Known providers. Custom values supported via `.custom` variant.
pub const Provider = union(enum) {
    amazon_bedrock,
    anthropic,
    google,
    google_gemini_cli,
    google_antigravity,
    google_vertex,
    openai,
    azure_openai_responses,
    openai_codex,
    github_copilot,
    xai,
    groq,
    cerebras,
    openrouter,
    vercel_ai_gateway,
    zai,
    mistral,
    minimax,
    minimax_cn,
    huggingface,
    opencode,
    opencode_go,
    kimi_coding,
    custom: []const u8,
};

/// Thinking/reasoning levels
pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub fn thinkingLevelToString(level: ThinkingLevel) []const u8 {
    return switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

/// Token budgets for each thinking level (token-based providers only)
pub const ThinkingBudgets = struct {
    minimal: ?u64 = null,
    low: ?u64 = null,
    medium: ?u64 = null,
    high: ?u64 = null,
};

/// Cache retention preferences
pub const CacheRetention = enum {
    none,
    short,
    long,
};

/// Transport protocols for streaming
pub const Transport = enum {
    sse,
    websocket,
    auto,
};

/// Base options all providers share
pub const StreamOptions = struct {
    io: std.Io = std.Options.debug_io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    signal: abort_signal_mod.AbortSignal = abort_signal_mod.AbortSignal.none,
    api_key: ?[]const u8 = null,
    /// Preferred transport for providers that support multiple transports.
    transport: ?Transport = null,
    /// Prompt cache retention preference. Providers map this to their supported values.
    /// Default: "short".
    cache_retention: ?CacheRetention = null,
    /// Optional session identifier for providers that support session-based caching.
    session_id: ?[]const u8 = null,
    /// Maximum delay in milliseconds to wait for a retry when the server requests a long wait.
    /// Default: 60000 (60 seconds). Set to 0 to disable the cap.
    max_retry_delay_ms: ?u64 = null,
    /// Optional custom HTTP headers to include in API requests.
    headers: ?[]const Header = null,
    /// Optional metadata to include in API requests.
    metadata: ?std.json.Value = null,
    /// Optional callback for inspecting or replacing provider payloads before sending.
    /// Return null to keep the payload unchanged.
    on_payload: ?*const fn (allocator: std.mem.Allocator, payload: std.json.Value, model: *const Model, ctx: ?*anyopaque) ?std.json.Value = null,
    on_payload_ctx: ?*anyopaque = null,
};

/// HTTP header key-value pair
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// StreamOptions extended with provider-specific opaque data.
/// pi-mono source: types.ts:108
/// Mirrors TS's ProviderStreamOptions = StreamOptions & Record<string, unknown>.
pub const ProviderStreamOptions = struct {
    base: StreamOptions = .{},
    /// Provider-specific extra options (opaque).
    provider_data: ?*anyopaque = null,
};

/// Unified options with reasoning passed to streamSimple() and completeSimple()
pub const SimpleStreamOptions = struct {
    base: StreamOptions = .{},
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
};

/// Text signature metadata (v1)
pub const TextSignatureV1 = struct {
    v: u8 = 1,
    id: []const u8,
    phase: ?enum {
        commentary,
        final_answer,
    } = null,
};

/// Text content block
pub const TextContent = struct {
    text: []const u8,
    /// For OpenAI responses, message metadata (legacy id string or TextSignatureV1 JSON)
    text_signature: ?[]const u8 = null,
};

/// Thinking content block
pub const ThinkingContent = struct {
    thinking: []const u8,
    /// For OpenAI responses, the reasoning item ID
    thinking_signature: ?[]const u8 = null,
    /// When true, the thinking content was redacted by safety filters.
    /// The opaque encrypted payload is stored in `thinking_signature`.
    redacted: ?bool = null,
};

/// Image content block
pub const ImageContent = struct {
    /// Base64 encoded image data
    data: []const u8,
    /// e.g., "image/jpeg", "image/png"
    mime_type: []const u8,
};

/// Tool call content block
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Tool arguments. Should be a JSON object (Record<string, any> in pi-mono).
    arguments: std.json.Value,
    /// Google-specific: opaque signature for reusing thought context
    thought_signature: ?[]const u8 = null,
};

/// Alias matching pi-mono's AgentToolCall — a ToolCall from an AssistantMessage content block.
/// pi-mono source: packages/agent/src/types.ts:38
pub const AgentToolCall = ToolCall;

/// Usage and cost information
pub const Usage = struct {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    total_tokens: u64,
    cost: Cost,

    pub const Cost = struct {
        input: f64,
        output: f64,
        cache_read: f64,
        cache_write: f64,
        total: f64,
    };
};

/// Reasons for stopping generation
pub const StopReason = enum {
    stop,
    length,
    toolUse,
    @"error",
    aborted,
};

/// User message
pub const UserMessage = struct {
    content: UserMessageContent,
    /// Unix timestamp in milliseconds
    timestamp: i64,

    pub const UserMessageContent = union(enum) {
        text: []const u8,
        blocks: []const Block,

        pub const Block = union(enum) {
            text: TextContent,
            image: ImageContent,
        };
    };
};

pub const NormalizedFailure = struct {
    kind: Kind,
    http_status: ?u16 = null,
    provider_code: ?[]const u8 = null,
    provider_type: ?[]const u8 = null,
    retry_after_ms: ?u64 = null,

    pub const Kind = enum {
        aborted,
        context_overflow,
        rate_limited,
        transient,
        auth,
        invalid_request,
        fatal,
    };
};

/// Assistant message
pub const AssistantMessage = struct {
    content: []const AssistantContentBlock,
    api: Api,
    provider: Provider,
    model: []const u8,
    /// Provider-specific response/message identifier
    response_id: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    failure: ?NormalizedFailure = null,
    /// Unix timestamp in milliseconds
    timestamp: i64,

    pub const AssistantContentBlock = union(enum) {
        text: TextContent,
        thinking: ThinkingContent,
        tool_call: ToolCall,
    };
};

/// Tool result message
pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
    details: ?std.json.Value = null,
    presentation: ?std.json.Value = null,
    is_error: bool,
    /// Unix timestamp in milliseconds
    timestamp: i64,

    pub const ContentBlock = union(enum) {
        text: TextContent,
        image: ImageContent,
    };
};

/// Message union - tagged by role
pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

/// Tool definition
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema for parameters
    parameters: std.json.Value,
};

/// Conversation context
pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

/// Event protocol for AssistantMessageEventStream
pub const AssistantMessageEvent = union(enum) {
    start: struct { partial: AssistantMessage },
    text_start: struct { content_index: usize, partial: AssistantMessage },
    text_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    text_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    thinking_start: struct { content_index: usize, partial: AssistantMessage },
    thinking_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    thinking_end: struct { content_index: usize, content: []const u8, partial: AssistantMessage },
    toolcall_start: struct { content_index: usize, partial: AssistantMessage },
    toolcall_delta: struct { content_index: usize, delta: []const u8, partial: AssistantMessage },
    toolcall_end: struct { content_index: usize, tool_call: ToolCall, partial: AssistantMessage },
    done: struct { reason: DoneReason, message: AssistantMessage },
    @"error": struct { reason: ErrorReason, @"error": AssistantMessage },

    pub const DoneReason = enum {
        stop,
        length,
        toolUse,
    };

    pub const ErrorReason = enum {
        aborted,
        @"error",
    };
};

/// Compatibility settings for OpenAI-compatible completions APIs
pub const OpenAICompletionsCompat = struct {
    /// Whether the provider supports the `store` field.
    supports_store: ?bool = null,
    /// Whether the provider supports the `developer` role (vs `system`).
    supports_developer_role: ?bool = null,
    /// Whether the provider supports `reasoning_effort`.
    supports_reasoning_effort: ?bool = null,
    /// Optional mapping from pi-ai reasoning levels to provider/model-specific `reasoning_effort` values.
    reasoning_effort_map: ?ReasoningEffortMap = null,
    /// Whether the provider supports `stream_options: { include_usage: true }`.
    supports_usage_in_streaming: ?bool = null,
    /// Which field to use for max tokens.
    max_tokens_field: ?enum {
        max_completion_tokens,
        max_tokens,
    } = null,
    /// Whether tool results require the `name` field.
    requires_tool_result_name: ?bool = null,
    /// Whether a user message after tool results requires an assistant message in between.
    requires_assistant_after_tool_result: ?bool = null,
    /// Whether thinking blocks must be converted to text blocks with <thinking> delimiters.
    requires_thinking_as_text: ?bool = null,
    /// Format for reasoning/thinking parameter.
    thinking_format: ?ThinkingFormat = null,
    /// OpenRouter-specific routing preferences.
    open_router_routing: ?OpenRouterRouting = null,
    /// Vercel AI Gateway routing preferences.
    vercel_gateway_routing: ?VercelGatewayRouting = null,
    /// Whether z.ai supports top-level `tool_stream: true`.
    zai_tool_stream: ?bool = null,
    /// Whether the provider supports the `strict` field in tool definitions.
    supports_strict_mode: ?bool = null,

    pub const ReasoningEffortMap = struct {
        minimal: ?[]const u8 = null,
        low: ?[]const u8 = null,
        medium: ?[]const u8 = null,
        high: ?[]const u8 = null,
        xhigh: ?[]const u8 = null,
    };

    pub const ThinkingFormat = enum {
        openai,
        openrouter,
        zai,
        qwen,
        qwen_chat_template,
    };
};

/// Compatibility settings for OpenAI Responses APIs
pub const OpenAIResponsesCompat = struct {
    // Reserved for future use
};

/// OpenRouter provider routing preferences
pub const OpenRouterRouting = struct {
    /// List of provider slugs to exclusively use for this request.
    only: ?[][]const u8 = null,
    /// List of provider slugs to try in order.
    order: ?[][]const u8 = null,
};

/// Vercel AI Gateway routing preferences
pub const VercelGatewayRouting = struct {
    /// List of provider slugs to exclusively use for this request.
    only: ?[][]const u8 = null,
    /// List of provider slugs to try in order.
    order: ?[][]const u8 = null,
};

/// Compatibility union for Model
pub const Compat = union(enum) {
    openai_completions: OpenAICompletionsCompat,
    openai_responses: OpenAIResponsesCompat,
};

/// Model interface for the unified model system
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: []const u8,
    reasoning: bool,
    input: []const InputType,
    cost: Cost,
    context_window: u64,
    max_tokens: u64,
    headers: ?[]const Header = null,
    /// Compatibility overrides for OpenAI-compatible APIs.
    compat: ?Compat = null,

    pub const InputType = enum {
        text,
        image,
    };

    pub const Cost = struct {
        /// $/million tokens
        input: f64,
        /// $/million tokens
        output: f64,
        /// $/million tokens
        cache_read: f64,
        /// $/million tokens
        cache_write: f64,
    };
};

/// Stream function type — the core provider callable.
/// pi-mono source: types.ts:125-129
/// In zig, uses callback-based streaming instead of returning an AsyncIterable.
pub const StreamFunction = *const fn (
    model: Model,
    context: Context,
    options: StreamOptions,
    callback: *const fn (event: AssistantMessageEvent, ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,
) void;
