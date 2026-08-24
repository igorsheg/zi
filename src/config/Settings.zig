const std = @import("std");
const Store = @import("Store.zig");

const Settings = @This();

pub const Kind = enum { string, int, bool, size, duration };

/// Static setting metadata in user-visible registry order. Every string is
/// borrowed for the life of the program.
pub const Setting = struct {
    key: []const u8,
    env: []const u8,
    default: ?[]const u8,
    keep_empty: bool,
    kind: Kind,
    min: ?i32,
    max: ?i32,
    description: []const u8,
};

const registry = [_]Setting{
    .{
        .key = "preset",
        .env = "HAX_PRESET",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Preset from presets.<name> to apply at startup; empty disables",
    },
    .{
        .key = "provider",
        .env = "HAX_PROVIDER",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Provider id; /provider shows the available choices",
    },
    .{
        .key = "model",
        .env = "HAX_MODEL",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Model id (provider-specific; some auto-fill or require it)",
    },
    .{
        .key = "effort",
        .env = "HAX_EFFORT",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Reasoning effort (provider-specific); empty omits it",
    },
    .{
        .key = "system_prompt",
        .env = "HAX_SYSTEM_PROMPT",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Replace the built-in base prompt (context sections still follow); @path reads a file; " ++
            "(none) sends no system message at all",
    },
    .{
        .key = "system_prompt_append",
        .env = "HAX_SYSTEM_PROMPT_APPEND",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Text appended after the base system prompt; @path reads a file",
    },
    .{
        .key = "no_env",
        .env = "HAX_NO_ENV",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the Environment section in the system prompt",
    },
    .{
        .key = "no_agents_md",
        .env = "HAX_NO_AGENTS_MD",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip AGENTS.md project instructions in the system prompt",
    },
    .{
        .key = "no_skills",
        .env = "HAX_NO_SKILLS",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the skills listing in the system prompt",
    },
    .{
        .key = "no_subagents",
        .env = "HAX_NO_SUBAGENTS",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the subagents section in the system prompt",
    },
    .{
        .key = "no_tasks",
        .env = "HAX_NO_TASKS",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Disable background tasks: bash timeouts kill instead of detaching, and the task tools " ++
            "are not offered",
    },
    .{
        .key = "markdown",
        .env = "HAX_MARKDOWN",
        .default = "1",
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Render Markdown in the terminal (TTY only; piped output is always raw)",
    },
    .{
        .key = "show_reasoning",
        .env = "HAX_SHOW_REASONING",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Show reasoning/CoT deltas live (default off)",
    },
    .{
        .key = "sort_models",
        .env = "HAX_SORT_MODELS",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Sort the /model picker newest-first; auto uses the provider's own default",
    },
    .{
        .key = "context_limit",
        .env = "HAX_CONTEXT_LIMIT",
        .default = null,
        .keep_empty = false,
        .kind = .size,
        .min = null,
        .max = null,
        .description = "Manual context-window size for the % display; overrides auto-detect",
    },
    .{
        .key = "display_width",
        .env = "HAX_DISPLAY_WIDTH",
        .default = "auto",
        .keep_empty = false,
        .kind = .int,
        .min = 20,
        .max = null,
        .description = "Content width: auto uses full width through 110 columns and 100 beyond that; terminal " ++
            "always uses full width; a number sets an exact width",
    },
    .{
        .key = "notify",
        .env = "HAX_NOTIFY",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Desktop-notification style: auto, bel, osc9, off (auto detects from the terminal)",
    },
    .{
        .key = "theme",
        .env = "HAX_THEME",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Color theme: auto, dark, light, ansi, off (auto detects from the terminal)",
    },
    .{
        .key = "tint",
        .env = "HAX_TINT",
        .default = "teal",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Identity tint for model output; an active preset's own tint wins until set here. Ignored " ++
            "by the ansi and off themes",
    },
    .{
        .key = "keep_awake",
        .env = "HAX_KEEP_AWAKE",
        .default = "1",
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Inhibit idle system sleep while a turn is running (display may still blank)",
    },
    .{
        .key = "compact.auto",
        .env = "HAX_COMPACT_AUTO",
        .default = "1",
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Auto-summarize history when it nears the context window (manual /compact still works)",
    },
    .{
        .key = "compact.threshold",
        .env = "HAX_COMPACT_THRESHOLD",
        .default = "85",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 100,
        .description = "Auto-compact when context usage reaches this percent of the window",
    },
    .{
        .key = "max_turns",
        .env = "HAX_MAX_TURNS",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = null,
        .description = "Interactive: pause for confirmation after this many model round-trips per user turn",
    },
    .{
        .key = "catalog.url",
        .env = "HAX_CATALOG_URL",
        .default = "https://models.dev/api.json",
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Model-metadata catalog endpoint (models.dev api.json shape); empty disables fetching",
    },
    .{
        .key = "catalog.refresh",
        .env = "HAX_CATALOG_REFRESH",
        .default = "24h",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Re-fetch the cached model catalog when older than this; 0 disables fetching",
    },
    .{
        .key = "no_session",
        .env = "HAX_NO_SESSION",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Skip recording conversations and typed prompts; auto skips both for dev providers (mock)",
    },
    .{
        .key = "session_retention_days",
        .env = "HAX_SESSION_RETENTION_DAYS",
        .default = "30",
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = 36500,
        .description = "Delete sessions after this many inactive days; 0 disables pruning",
    },
    .{
        .key = "transcript",
        .env = "HAX_TRANSCRIPT",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Path to mirror the Ctrl-T transcript view; empty disables",
    },
    .{
        .key = "trace",
        .env = "HAX_TRACE",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Path to a wire-level HTTP/SSE trace dump; empty disables",
    },
    .{
        .key = "image_input",
        .env = "HAX_IMAGE_INPUT",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Let the model view images via the read tool; auto detects per provider/model",
    },
    .{
        .key = "tool_output_cap",
        .env = "HAX_TOOL_OUTPUT_CAP",
        .default = "50k",
        .keep_empty = false,
        .kind = .size,
        .min = null,
        .max = null,
        .description = "Max bytes captured from a tool's output",
    },
    .{
        .key = "bash.timeout",
        .env = "HAX_BASH_TIMEOUT",
        .default = "2m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Default bash-tool command timeout: the command detaches into a background task (kills " ++
            "when tasks are disabled); 0 disables",
    },
    .{
        .key = "bash.timeout_max",
        .env = "HAX_BASH_TIMEOUT_MAX",
        .default = "30m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Ceiling on the model's per-call bash timeout; 0 disables",
    },
    .{
        .key = "bash.timeout_grace",
        .env = "HAX_BASH_TIMEOUT_GRACE",
        .default = "2s",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = 300000,
        .description = "Grace window between SIGTERM and SIGKILL for bash commands; 0 skips",
    },
    .{
        .key = "bash.background_yield",
        .env = "HAX_BASH_BACKGROUND_YIELD",
        .default = "5s",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Initial output window before an explicitly backgrounded bash command detaches into a " ++
            "task",
    },
    .{
        .key = "bash.shell",
        .env = "HAX_BASH_SHELL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Shell for the bash tool, a $PATH name or path (default: bash, else sh)",
    },
    .{
        .key = "task.wait_timeout",
        .env = "HAX_TASK_WAIT_TIMEOUT",
        .default = "10m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Default task_wait timeout when the model omits one (kill waits default to immediate)",
    },
    .{
        .key = "task.max_running",
        .env = "HAX_TASK_MAX_RUNNING",
        .default = "32",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 64,
        .description = "Maximum concurrently running background tasks",
    },
    .{
        .key = "http.max_retries",
        .env = "HAX_HTTP_MAX_RETRIES",
        .default = "4",
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = 100,
        .description = "Additional retries for transient HTTP failures",
    },
    .{
        .key = "http.retry_base",
        .env = "HAX_HTTP_RETRY_BASE",
        .default = "1s",
        .keep_empty = false,
        .kind = .duration,
        .min = 1,
        .max = null,
        .description = "Base backoff between HTTP retries",
    },
    .{
        .key = "http.idle_timeout",
        .env = "HAX_HTTP_IDLE_TIMEOUT",
        .default = "10m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Silence on a streaming response before giving up; 0 disables",
    },
    .{
        .key = "providers.openai-compatible.base_url",
        .env = "HAX_OPENAI_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Base URL of the OpenAI-compatible endpoint",
    },
    .{
        .key = "providers.openai-compatible.api_key",
        .env = "HAX_OPENAI_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Bearer token for the OpenAI-compatible endpoint",
    },
    .{
        .key = "providers.openai-compatible.display_name",
        .env = "HAX_OPENAI_DISPLAY_NAME",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Display name for the provider in the banner and picker",
    },
    .{
        .key = "providers.openai-compatible.api",
        .env = "HAX_OPENAI_API",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Request protocol: chat (Chat Completions) or responses",
    },
    .{
        .key = "providers.openai-compatible.reasoning_format",
        .env = "HAX_OPENAI_REASONING_FORMAT",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Reasoning request dialect: flat or nested",
    },
    .{
        .key = "providers.openai-compatible.reasoning_roundtrip",
        .env = "HAX_REASONING_ROUNDTRIP",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Replay reasoning text to the model (off/on, or a field name)",
    },
    .{
        .key = "providers.openai-compatible.send_cache_key",
        .env = "HAX_OPENAI_SEND_CACHE_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Send a stable prompt_cache_key (prefix-cache hint); auto uses the provider default",
    },
    .{
        .key = "providers.openai-compatible.request_cost",
        .env = "HAX_OPENAI_REQUEST_COST",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Request usage accounting (`usage: {include: true}`) for per-response cost; auto uses the " ++
            "provider default",
    },
    .{
        .key = "providers.openai-compatible.cache",
        .env = "HAX_OPENAI_CACHE",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Send prompt cache_control breakpoints (routers fronting Anthropic models, which cache " ++
            "only on request); auto uses the provider default",
    },
    .{
        .key = "providers.openai-compatible.cache_ttl",
        .env = "HAX_OPENAI_CACHE_TTL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Cache breakpoint TTL: 5m or 1h (default 1h, suiting an interactive agent's pauses)",
    },
    .{
        .key = "providers.anthropic-compatible.base_url",
        .env = "HAX_ANTHROPIC_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Base URL of the Anthropic-compatible /v1 endpoint",
    },
    .{
        .key = "providers.anthropic-compatible.api_key",
        .env = "HAX_ANTHROPIC_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "x-api-key token for the Anthropic-compatible endpoint",
    },
    .{
        .key = "providers.anthropic-compatible.display_name",
        .env = "HAX_ANTHROPIC_DISPLAY_NAME",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Display name for the provider in the banner and picker",
    },
    .{
        .key = "providers.anthropic-compatible.max_tokens",
        .env = "HAX_ANTHROPIC_MAX_TOKENS",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = null,
        .description = "Max output tokens (thinking + text) per response; unset follows the model's own cap",
    },
    .{
        .key = "providers.anthropic-compatible.thinking_mode",
        .env = "HAX_ANTHROPIC_THINKING_MODE",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Thinking mode: adaptive, budget, or off",
    },
    .{
        .key = "providers.anthropic-compatible.thinking_budget",
        .env = "HAX_ANTHROPIC_THINKING_BUDGET",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = null,
        .description = "Budget-mode thinking tokens (default: max_tokens - 1)",
    },
    .{
        .key = "providers.anthropic-compatible.cache",
        .env = "HAX_ANTHROPIC_CACHE",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Send prompt cache_control breakpoints; auto uses the provider default",
    },
    .{
        .key = "providers.anthropic-compatible.cache_ttl",
        .env = "HAX_ANTHROPIC_CACHE_TTL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Cache breakpoint TTL: 5m or 1h (default 1h, suiting an interactive agent's pauses)",
    },
    .{
        .key = "providers.anthropic-compatible.version",
        .env = "HAX_ANTHROPIC_VERSION",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "anthropic-version request header value (default: 2023-06-01)",
    },
    .{
        .key = "providers.llamacpp.base_url",
        .env = "HAX_LLAMACPP_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Full llama-server base URL; overrides the port setting",
    },
    .{
        .key = "providers.llamacpp.api_key",
        .env = "HAX_LLAMACPP_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Bearer token when llama-server runs with --api-key",
    },
    .{
        .key = "providers.llamacpp.port",
        .env = "HAX_LLAMACPP_PORT",
        .default = "8080",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 65535,
        .description = "Port for the local llama-server (when base_url is unset)",
    },
    .{
        .key = "providers.openrouter.title",
        .env = "HAX_OPENROUTER_TITLE",
        .default = "zi",
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "X-Title header for OpenRouter attribution (empty disables)",
    },
    .{
        .key = "providers.openrouter.referer",
        .env = "HAX_OPENROUTER_REFERER",
        .default = "https://github.com/igorsheg/zi",
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "HTTP-Referer header for OpenRouter attribution (empty disables)",
    },
    .{
        .key = "providers.mock.script",
        .env = "HAX_MOCK_SCRIPT",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Path to a mock-provider script (mock provider only)",
    },
};

/// Returns the allocation-free, ordered static registry.
pub fn list() []const Setting {
    return &registry;
}

/// Returns borrowed static metadata, or null for an unknown key.
pub fn find(key: []const u8) ?*const Setting {
    for (&registry) |*setting| {
        if (std.mem.eql(u8, setting.key, key)) return setting;
    }
    return null;
}

const registry_context: u8 = 0;

/// Adapts this registry to Store without allocating. The returned adapter and
/// all metadata it exposes have static lifetime.
pub fn storeRegistry() Store.SettingRegistry {
    return .{ .context = &registry_context, .find_fn = findStoreSetting };
}

fn findStoreSetting(_: *const anyopaque, key: []const u8) ?Store.Setting {
    const setting = find(key) orelse return null;
    return .{
        .env_var = setting.env,
        .default_value = setting.default,
        .keep_empty = setting.keep_empty,
    };
}

pub const StringResult = Store.Result;

pub const IntResult = struct {
    value: i32,
    source: Store.Source,
};

pub const BoolResult = struct {
    value: bool,
    source: Store.Source,
};

/// Resolves and owns a string exactly as Store does. Call deinit on the result.
pub fn getString(
    store: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{OutOfMemory}!StringResult {
    return store.read(allocator, key);
}

/// Resolves a nonempty decimal C int. Invalid, negative, or out-of-bounds
/// values fall back to the registry default, then zero.
pub fn getInt(
    store: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{OutOfMemory}!IntResult {
    var resolved = try store.readNonempty(allocator, key);
    defer resolved.deinit(allocator);
    const setting = find(key);
    const parsed = if (resolved.value) |value| parseCInt(value) else null;
    const value = if (parsed) |number|
        if (number >= 0 and inBounds(setting, number)) number else fallbackInt(setting)
    else
        fallbackInt(setting);
    return .{ .value = value, .source = resolved.source };
}

/// Resolves a nonempty hax-compatible boolean. Invalid or absent values fall
/// back to the registry default, then false.
pub fn getBool(
    store: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{OutOfMemory}!BoolResult {
    var resolved = try store.readNonempty(allocator, key);
    defer resolved.deinit(allocator);
    const value = if (resolved.value) |text| parseBool(text) else null;
    return .{
        .value = value orelse fallbackBool(find(key)),
        .source = resolved.source,
    };
}

fn parseCInt(text: []const u8) ?i32 {
    var start: usize = 0;
    while (start < text.len and isCWhitespace(text[start])) start += 1;
    if (start == text.len) return null;
    return std.fmt.parseInt(i32, text[start..], 10) catch null;
}

fn isCWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
        byte == 0x0b or byte == 0x0c;
}

fn inBounds(setting: ?*const Setting, value: i32) bool {
    const metadata = setting orelse return true;
    if (metadata.min) |minimum| if (value < minimum) return false;
    if (metadata.max) |maximum| if (value > maximum) return false;
    return true;
}

fn fallbackInt(setting: ?*const Setting) i32 {
    const metadata = setting orelse return 0;
    const text = metadata.default orelse return 0;
    return parseCInt(text) orelse 0;
}

fn parseBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on")) return true;
    if (std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return false;
    return null;
}

fn fallbackBool(setting: ?*const Setting) bool {
    const metadata = setting orelse return false;
    const text = metadata.default orelse return false;
    return parseBool(text) orelse false;
}

const EmptyEnvironment = struct {
    pub fn get(_: *const EmptyEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

const MapEnvironment = struct {
    name: []const u8,
    value: []const u8,

    pub fn get(self: *const MapEnvironment, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, self.name, name)) self.value else null;
    }
};

fn testStore(environment: anytype) Store {
    return .init(.{ .registry = storeRegistry(), .environment = .from(environment) });
}

test "registry golden count order and representative metadata" {
    try std.testing.expectEqual(@as(usize, 66), list().len);
    try std.testing.expectEqualStrings("preset", list()[0].key);
    try std.testing.expectEqualStrings("providers.mock.script", list()[65].key);

    const threshold = find("compact.threshold").?;
    try std.testing.expectEqual(Kind.int, threshold.kind);
    try std.testing.expectEqual(@as(?i32, 1), threshold.min);
    try std.testing.expectEqual(@as(?i32, 100), threshold.max);
    try std.testing.expectEqualStrings("85", threshold.default.?);

    const title = find("providers.openrouter.title").?;
    try std.testing.expectEqualStrings("HAX_OPENROUTER_TITLE", title.env);
    try std.testing.expectEqualStrings("zi", title.default.?);
    try std.testing.expect(title.keep_empty);
    try std.testing.expect(find("not-a-setting") == null);
}

test "registry golden keys are complete ordered and unique" {
    const expected = [_][]const u8{
        "preset",
        "provider",
        "model",
        "effort",
        "system_prompt",
        "system_prompt_append",
        "no_env",
        "no_agents_md",
        "no_skills",
        "no_subagents",
        "no_tasks",
        "markdown",
        "show_reasoning",
        "sort_models",
        "context_limit",
        "display_width",
        "notify",
        "theme",
        "tint",
        "keep_awake",
        "compact.auto",
        "compact.threshold",
        "max_turns",
        "catalog.url",
        "catalog.refresh",
        "no_session",
        "session_retention_days",
        "transcript",
        "trace",
        "image_input",
        "tool_output_cap",
        "bash.timeout",
        "bash.timeout_max",
        "bash.timeout_grace",
        "bash.background_yield",
        "bash.shell",
        "task.wait_timeout",
        "task.max_running",
        "http.max_retries",
        "http.retry_base",
        "http.idle_timeout",
        "providers.openai-compatible.base_url",
        "providers.openai-compatible.api_key",
        "providers.openai-compatible.display_name",
        "providers.openai-compatible.api",
        "providers.openai-compatible.reasoning_format",
        "providers.openai-compatible.reasoning_roundtrip",
        "providers.openai-compatible.send_cache_key",
        "providers.openai-compatible.request_cost",
        "providers.openai-compatible.cache",
        "providers.openai-compatible.cache_ttl",
        "providers.anthropic-compatible.base_url",
        "providers.anthropic-compatible.api_key",
        "providers.anthropic-compatible.display_name",
        "providers.anthropic-compatible.max_tokens",
        "providers.anthropic-compatible.thinking_mode",
        "providers.anthropic-compatible.thinking_budget",
        "providers.anthropic-compatible.cache",
        "providers.anthropic-compatible.cache_ttl",
        "providers.anthropic-compatible.version",
        "providers.llamacpp.base_url",
        "providers.llamacpp.api_key",
        "providers.llamacpp.port",
        "providers.openrouter.title",
        "providers.openrouter.referer",
        "providers.mock.script",
    };
    try std.testing.expectEqual(expected.len, list().len);
    for (&expected, list()) |key, setting| try std.testing.expectEqualStrings(key, setting.key);
    for (list(), 0..) |left, left_index| {
        for (list()[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.key, right.key));
        }
    }
}

test "Store adapter and typed getters preserve fallbacks bounds and source" {
    const empty: EmptyEnvironment = .{};
    const default_store = testStore(&empty);
    const threshold = try getInt(default_store, std.testing.allocator, "compact.threshold");
    try std.testing.expectEqual(@as(i32, 85), threshold.value);
    try std.testing.expectEqual(Store.Source.default, threshold.source);
    const markdown = try getBool(default_store, std.testing.allocator, "markdown");
    try std.testing.expect(markdown.value);

    const high: MapEnvironment = .{ .name = "HAX_COMPACT_THRESHOLD", .value = "101" };
    const bounded = try getInt(testStore(&high), std.testing.allocator, "compact.threshold");
    try std.testing.expectEqual(@as(i32, 85), bounded.value);
    try std.testing.expectEqual(Store.Source.env, bounded.source);

    const signed: MapEnvironment = .{ .name = "HAX_MAX_TURNS", .value = "  +2147483647" };
    const maximum = try getInt(testStore(&signed), std.testing.allocator, "max_turns");
    try std.testing.expectEqual(std.math.maxInt(i32), maximum.value);

    const overflow: MapEnvironment = .{ .name = "HAX_MAX_TURNS", .value = "2147483648" };
    const invalid = try getInt(testStore(&overflow), std.testing.allocator, "max_turns");
    try std.testing.expectEqual(@as(i32, 0), invalid.value);

    const boolean: MapEnvironment = .{ .name = "HAX_MARKDOWN", .value = "OFF" };
    const disabled = try getBool(testStore(&boolean), std.testing.allocator, "markdown");
    try std.testing.expect(!disabled.value);
}

test "typed getter allocation failures are explicit" {
    const empty: EmptyEnvironment = .{};
    const store = testStore(&empty);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn exercise(allocator: std.mem.Allocator, value: Store) !void {
            var text = try getString(value, allocator, "markdown");
            defer text.deinit(allocator);
            _ = try getInt(value, allocator, "compact.threshold");
            _ = try getBool(value, allocator, "markdown");
        }
    }.exercise, .{store});
}
