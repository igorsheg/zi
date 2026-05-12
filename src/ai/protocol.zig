const abort_signal_mod = @import("../zio/root.zig");
const std = @import("std");

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

pub const ThinkingBudgets = struct {
    minimal: ?u64 = null,
    low: ?u64 = null,
    medium: ?u64 = null,
    high: ?u64 = null,
};

pub const CacheRetention = enum {
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
    auto,
};

pub const StreamOptions = struct {
    io: std.Io = std.Options.debug_io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    signal: abort_signal_mod.cancel.Token = abort_signal_mod.cancel.Token.none,
    api_key: ?[]const u8 = null,

    transport: ?Transport = null,

    cache_retention: ?CacheRetention = null,

    session_id: ?[]const u8 = null,

    max_retry_delay_ms: ?u64 = null,

    headers: ?[]const Header = null,

    metadata: ?std.json.Value = null,

    on_payload: ?*const fn (allocator: std.mem.Allocator, payload: std.json.Value, model: *const Model, ctx: ?*anyopaque) ?std.json.Value = null,
    on_payload_ctx: ?*anyopaque = null,
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProviderStreamOptions = struct {
    base: StreamOptions = .{},

    provider_data: ?*anyopaque = null,
};

pub const SimpleStreamOptions = struct {
    base: StreamOptions = .{},
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
};

pub const TextSignatureV1 = struct {
    v: u8 = 1,
    id: []const u8,
    phase: ?enum {
        commentary,
        final_answer,
    } = null,
};

pub const TextContent = struct {
    text: []const u8,

    text_signature: ?[]const u8 = null,
};

pub const ThinkingContent = struct {
    thinking: []const u8,

    thinking_signature: ?[]const u8 = null,

    redacted: ?bool = null,
};

pub const ImageContent = struct {
    data: []const u8,

    mime_type: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,

    arguments: std.json.Value,

    thought_signature: ?[]const u8 = null,
};

pub const AgentToolCall = ToolCall;

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

pub const StopReason = enum {
    stop,
    length,
    toolUse,
    @"error",
    aborted,
};

pub const UserMessage = struct {
    content: UserMessageContent,

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

pub const AssistantMessage = struct {
    content: []const AssistantContentBlock,
    api: Api,
    provider: Provider,
    model: []const u8,

    response_id: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    failure: ?NormalizedFailure = null,

    timestamp: i64,

    pub const AssistantContentBlock = union(enum) {
        text: TextContent,
        thinking: ThinkingContent,
        tool_call: ToolCall,
    };
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
    details: ?std.json.Value = null,
    presentation: ?std.json.Value = null,
    is_error: bool,

    timestamp: i64,

    pub const ContentBlock = union(enum) {
        text: TextContent,
        image: ImageContent,
    };
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,

    parameters: std.json.Value,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

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

pub const OpenAICompletionsCompat = struct {
    supports_store: ?bool = null,

    supports_developer_role: ?bool = null,

    supports_reasoning_effort: ?bool = null,

    reasoning_effort_map: ?ReasoningEffortMap = null,

    supports_usage_in_streaming: ?bool = null,

    max_tokens_field: ?enum {
        max_completion_tokens,
        max_tokens,
    } = null,

    requires_tool_result_name: ?bool = null,

    requires_assistant_after_tool_result: ?bool = null,

    requires_thinking_as_text: ?bool = null,

    thinking_format: ?ThinkingFormat = null,

    open_router_routing: ?OpenRouterRouting = null,

    vercel_gateway_routing: ?VercelGatewayRouting = null,

    zai_tool_stream: ?bool = null,

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

pub const OpenAIResponsesCompat = struct {};

pub const OpenRouterRouting = struct {
    only: ?[][]const u8 = null,

    order: ?[][]const u8 = null,
};

pub const VercelGatewayRouting = struct {
    only: ?[][]const u8 = null,

    order: ?[][]const u8 = null,
};

pub const Compat = union(enum) {
    openai_completions: OpenAICompletionsCompat,
    openai_responses: OpenAIResponsesCompat,
};

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

    compat: ?Compat = null,

    pub const InputType = enum {
        text,
        image,
    };

    pub const Cost = struct {
        input: f64,

        output: f64,

        cache_read: f64,

        cache_write: f64,
    };
};

pub const StreamFunction = *const fn (
    model: Model,
    context: Context,
    options: StreamOptions,
    callback: *const fn (event: AssistantMessageEvent, ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,
) void;
