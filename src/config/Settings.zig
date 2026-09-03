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
    choices: []const []const u8 = &.{},
    example: ?[]const u8 = null,
    editable: bool = false,
    secret: bool = false,
};

const bool_choices = [_][]const u8{ "on", "off" };
const tristate_choices = [_][]const u8{ "auto", "on", "off" };
const display_width_choices = [_][]const u8{ "auto", "terminal" };
const theme_choices = [_][]const u8{ "auto", "dark", "light", "ansi", "off" };
const tint_choices = [_][]const u8{ "teal", "violet", "rose", "sage" };
const api_choices = [_][]const u8{ "chat", "responses" };
const reasoning_format_choices = [_][]const u8{ "flat", "nested" };
const cache_ttl_choices = [_][]const u8{ "5m", "1h" };
const thinking_mode_choices = [_][]const u8{ "adaptive", "budget", "off" };

const registry = [_]Setting{
    .{
        .key = "preset",
        .env = "ZI_PRESET",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Preset from presets.<name> to apply at startup; empty disables",
    },
    .{
        .key = "provider",
        .env = "ZI_PROVIDER",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Provider id; pass --provider to choose",
    },
    .{
        .key = "model",
        .env = "ZI_MODEL",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Model id (provider-specific; some auto-fill or require it)",
    },
    .{
        .key = "effort",
        .env = "ZI_EFFORT",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Reasoning effort (provider-specific); empty omits it",
    },
    .{
        .key = "system_prompt",
        .env = "ZI_SYSTEM_PROMPT",
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
        .env = "ZI_SYSTEM_PROMPT_APPEND",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Text appended after the base system prompt; @path reads a file",
    },
    .{
        .key = "no_env",
        .choices = &bool_choices,
        .env = "ZI_NO_ENV",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the Environment section in the system prompt",
    },
    .{
        .key = "no_agents_md",
        .choices = &bool_choices,
        .env = "ZI_NO_AGENTS_MD",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip AGENTS.md project instructions in the system prompt",
    },
    .{
        .key = "no_skills",
        .choices = &bool_choices,
        .env = "ZI_NO_SKILLS",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the skills listing in the system prompt",
    },
    .{
        .key = "no_subagents",
        .choices = &bool_choices,
        .env = "ZI_NO_SUBAGENTS",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Skip the subagents section in the system prompt",
    },
    .{
        .key = "no_tasks",
        .choices = &bool_choices,
        .env = "ZI_NO_TASKS",
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
        .editable = true,
        .choices = &bool_choices,
        .env = "ZI_MARKDOWN",
        .default = "1",
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Render Markdown in the terminal (TTY only; piped output is always raw)",
    },
    .{
        .key = "show_reasoning",
        .editable = true,
        .choices = &bool_choices,
        .env = "ZI_SHOW_REASONING",
        .default = null,
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Show reasoning/CoT deltas live (default off)",
    },
    .{
        .key = "sort_models",
        .choices = &tristate_choices,
        .editable = true,
        .env = "ZI_SORT_MODELS",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Sort the /model picker newest-first; auto uses the provider's own default",
    },
    .{
        .key = "context_limit",
        .editable = true,
        .env = "ZI_CONTEXT_LIMIT",
        .default = null,
        .keep_empty = false,
        .kind = .size,
        .min = null,
        .max = null,
        .description = "Manual context-window size for the % display; overrides auto-detect",
    },
    .{
        .key = "display_width",
        .editable = true,
        .choices = &display_width_choices,
        .example = "100",
        .env = "ZI_DISPLAY_WIDTH",
        .default = "auto",
        .keep_empty = false,
        .kind = .int,
        .min = 20,
        .max = 4096,
        .description = "Content width: auto uses full width through 110 columns and 100 beyond that; terminal " ++
            "always uses full width; a number sets an exact width",
    },
    .{
        .key = "theme",
        .editable = true,
        .choices = &theme_choices,
        .env = "ZI_THEME",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Color theme: auto, dark, light, ansi, off (auto detects from the terminal)",
    },
    .{
        .key = "tint",
        .editable = true,
        .choices = &tint_choices,
        .env = "ZI_TINT",
        .default = "teal",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Identity tint for model output; an active preset's own tint wins until set here. Ignored " ++
            "by the ansi and off themes",
    },
    .{
        .key = "compact.auto",
        .choices = &bool_choices,
        .editable = true,
        .env = "ZI_COMPACT_AUTO",
        .default = "1",
        .keep_empty = false,
        .kind = .bool,
        .min = null,
        .max = null,
        .description = "Auto-summarize history when it nears the context window (manual /compact still works)",
    },
    .{
        .key = "compact.threshold",
        .editable = true,
        .env = "ZI_COMPACT_THRESHOLD",
        .default = "85",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 100,
        .description = "Auto-compact when context usage reaches this percent of the window",
    },
    .{
        .key = "max_turns",
        .editable = true,
        .env = "ZI_MAX_TURNS",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = null,
        .description = "Interactive: pause for confirmation after this many model round-trips per user turn",
    },
    .{
        .key = "catalog.url",
        .env = "ZI_CATALOG_URL",
        .default = "https://models.dev/api.json",
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Model-metadata catalog endpoint (models.dev api.json shape); empty disables fetching",
    },
    .{
        .key = "catalog.refresh",
        .env = "ZI_CATALOG_REFRESH",
        .default = "24h",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Re-fetch the cached model catalog when older than this; 0 disables fetching",
    },
    .{
        .key = "no_session",
        .choices = &tristate_choices,
        .env = "ZI_NO_SESSION",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Skip recording conversations and typed prompts; auto skips both for dev providers (mock)",
    },
    .{
        .key = "session_retention_days",
        .env = "ZI_SESSION_RETENTION_DAYS",
        .default = "30",
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = 36500,
        .description = "Delete sessions after this many inactive days; 0 disables pruning",
    },
    .{
        .key = "transcript",
        .env = "ZI_TRANSCRIPT",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Path to mirror the Ctrl-T transcript view; empty disables",
    },
    .{
        .key = "image_input",
        .choices = &tristate_choices,
        .editable = true,
        .env = "ZI_IMAGE_INPUT",
        .default = "auto",
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Let the model view images via the read tool; auto detects per provider/model",
    },
    .{
        .key = "tool_output_cap",
        .editable = true,
        .env = "ZI_TOOL_OUTPUT_CAP",
        .default = "50k",
        .keep_empty = false,
        .kind = .size,
        .min = null,
        .max = null,
        .description = "Max bytes captured from a tool's output",
    },
    .{
        .key = "bash.timeout",
        .editable = true,
        .env = "ZI_BASH_TIMEOUT",
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
        .editable = true,
        .env = "ZI_BASH_TIMEOUT_MAX",
        .default = "30m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Ceiling on the model's per-call bash timeout; 0 disables",
    },
    .{
        .key = "bash.timeout_grace",
        .editable = true,
        .env = "ZI_BASH_TIMEOUT_GRACE",
        .default = "2s",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = 300000,
        .description = "Grace window between SIGTERM and SIGKILL for bash commands; 0 skips",
    },
    .{
        .key = "bash.background_yield",
        .editable = true,
        .env = "ZI_BASH_BACKGROUND_YIELD",
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
        .env = "ZI_BASH_SHELL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Shell for the bash tool, a $PATH name or path (default: bash, else sh)",
    },
    .{
        .key = "task.wait_timeout",
        .editable = true,
        .env = "ZI_TASK_WAIT_TIMEOUT",
        .default = "10m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Default task_wait timeout when the model omits one (kill waits default to immediate)",
    },
    .{
        .key = "task.max_running",
        .editable = true,
        .env = "ZI_TASK_MAX_RUNNING",
        .default = "32",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 64,
        .description = "Maximum concurrently running background tasks",
    },
    .{
        .key = "http.max_retries",
        .editable = true,
        .env = "ZI_HTTP_MAX_RETRIES",
        .default = "4",
        .keep_empty = false,
        .kind = .int,
        .min = null,
        .max = 100,
        .description = "Additional retries for transient HTTP failures",
    },
    .{
        .key = "http.retry_base",
        .editable = true,
        .env = "ZI_HTTP_RETRY_BASE",
        .default = "1s",
        .keep_empty = false,
        .kind = .duration,
        .min = 1,
        .max = null,
        .description = "Base backoff between HTTP retries",
    },
    .{
        .key = "http.idle_timeout",
        .editable = true,
        .env = "ZI_HTTP_IDLE_TIMEOUT",
        .default = "10m",
        .keep_empty = false,
        .kind = .duration,
        .min = null,
        .max = null,
        .description = "Silence on a streaming response before giving up; 0 disables",
    },
    .{
        .key = "providers.openai-compatible.base_url",
        .env = "ZI_OPENAI_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Base URL of the OpenAI-compatible endpoint",
    },
    .{
        .key = "providers.openai-compatible.api_key",
        .secret = true,
        .env = "ZI_OPENAI_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Bearer token for the OpenAI-compatible endpoint",
    },
    .{
        .key = "providers.openai-compatible.display_name",
        .env = "ZI_OPENAI_DISPLAY_NAME",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Display name for the provider in the banner and picker",
    },
    .{
        .key = "providers.openai-compatible.api",
        .choices = &api_choices,
        .env = "ZI_OPENAI_API",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Request protocol: chat (Chat Completions) or responses",
    },
    .{
        .key = "providers.openai-compatible.reasoning_format",
        .choices = &reasoning_format_choices,
        .env = "ZI_OPENAI_REASONING_FORMAT",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Reasoning request dialect: flat or nested",
    },
    .{
        .key = "providers.openai-compatible.reasoning_roundtrip",
        .env = "ZI_REASONING_ROUNDTRIP",
        .default = null,
        .keep_empty = true,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Replay reasoning text to the model (off/on, or a field name)",
    },
    .{
        .key = "providers.openai-compatible.send_cache_key",
        .choices = &tristate_choices,
        .env = "ZI_OPENAI_SEND_CACHE_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Send a stable prompt_cache_key (prefix-cache hint); auto uses the provider default",
    },
    .{
        .key = "providers.openai-compatible.request_cost",
        .choices = &tristate_choices,
        .env = "ZI_OPENAI_REQUEST_COST",
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
        .choices = &tristate_choices,
        .env = "ZI_OPENAI_CACHE",
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
        .choices = &cache_ttl_choices,
        .env = "ZI_OPENAI_CACHE_TTL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Cache breakpoint TTL: 5m or 1h (default 1h, suiting an interactive agent's pauses)",
    },
    .{
        .key = "providers.anthropic-compatible.base_url",
        .env = "ZI_ANTHROPIC_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Base URL of the Anthropic-compatible /v1 endpoint",
    },
    .{
        .key = "providers.anthropic-compatible.api_key",
        .secret = true,
        .env = "ZI_ANTHROPIC_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "x-api-key token for the Anthropic-compatible endpoint",
    },
    .{
        .key = "providers.anthropic-compatible.display_name",
        .env = "ZI_ANTHROPIC_DISPLAY_NAME",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Display name for the provider in the banner and picker",
    },
    .{
        .key = "providers.anthropic-compatible.max_tokens",
        .env = "ZI_ANTHROPIC_MAX_TOKENS",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = null,
        .description = "Max output tokens (thinking + text) per response; unset follows the model's own cap",
    },
    .{
        .key = "providers.anthropic-compatible.thinking_mode",
        .choices = &thinking_mode_choices,
        .env = "ZI_ANTHROPIC_THINKING_MODE",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Thinking mode: adaptive, budget, or off",
    },
    .{
        .key = "providers.anthropic-compatible.thinking_budget",
        .env = "ZI_ANTHROPIC_THINKING_BUDGET",
        .default = null,
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = null,
        .description = "Budget-mode thinking tokens (default: max_tokens - 1)",
    },
    .{
        .key = "providers.anthropic-compatible.cache",
        .choices = &tristate_choices,
        .env = "ZI_ANTHROPIC_CACHE",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Send prompt cache_control breakpoints; auto uses the provider default",
    },
    .{
        .key = "providers.anthropic-compatible.cache_ttl",
        .choices = &cache_ttl_choices,
        .env = "ZI_ANTHROPIC_CACHE_TTL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Cache breakpoint TTL: 5m or 1h (default 1h, suiting an interactive agent's pauses)",
    },
    .{
        .key = "providers.anthropic-compatible.version",
        .env = "ZI_ANTHROPIC_VERSION",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "anthropic-version request header value (default: 2023-06-01)",
    },
    .{
        .key = "providers.llamacpp.base_url",
        .env = "ZI_LLAMACPP_BASE_URL",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Full llama-server base URL; overrides the port setting",
    },
    .{
        .key = "providers.llamacpp.api_key",
        .secret = true,
        .env = "ZI_LLAMACPP_API_KEY",
        .default = null,
        .keep_empty = false,
        .kind = .string,
        .min = null,
        .max = null,
        .description = "Bearer token when llama-server runs with --api-key",
    },
    .{
        .key = "providers.llamacpp.port",
        .env = "ZI_LLAMACPP_PORT",
        .default = "8080",
        .keep_empty = false,
        .kind = .int,
        .min = 1,
        .max = 65535,
        .description = "Port for the local llama-server (when base_url is unset)",
    },
    .{
        .key = "providers.mock.script",
        .env = "ZI_MOCK_SCRIPT",
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

pub const Update = union(enum) {
    clear,
    set: []const u8,
};

pub const ValidationError = error{ ReadOnly, InvalidValue };

pub const Inspection = struct {
    display: []u8,
    source: Store.Source,
    invalid: bool,
    clipped: bool,

    pub fn deinit(self: *Inspection, allocator: std.mem.Allocator) void {
        @memset(self.display, 0);
        allocator.free(self.display);
        self.* = undefined;
    }
};

pub fn validateUpdate(setting: *const Setting, value: []const u8) ValidationError!Update {
    if (!setting.editable) return error.ReadOnly;
    if (std.mem.eql(u8, value, "default")) return .clear;
    if (choice(setting, value)) |canonical| return .{ .set = canonical };
    if (setting.kind == .bool) {
        if (parseBool(value) == null) return error.InvalidValue;
        return .{ .set = value };
    }
    if (hasBooleanChoices(setting)) {
        if (parseBool(value) == null) return error.InvalidValue;
        return .{ .set = value };
    }
    if (!validTypedValue(setting, value)) return error.InvalidValue;
    return .{ .set = value };
}

pub fn expectedHint(setting: *const Setting, buffer: []u8) []const u8 {
    if (std.mem.eql(u8, setting.key, "display_width"))
        return "auto|terminal, or a whole number from 20 to 4096; e.g. 100";
    if (setting.choices.len != 0 and setting.kind == .string) {
        var writer: std.Io.Writer = .fixed(buffer);
        for (setting.choices, 0..) |value, index| {
            if (index != 0) writer.writeByte('|') catch return "one of the listed choices";
            writer.writeAll(value) catch return "one of the listed choices";
        }
        return writer.buffered();
    }
    return switch (setting.kind) {
        .bool => "on|off",
        .int => if (setting.min != null or setting.max != null)
            formatIntegerHint(setting, buffer)
        else
            "a nonnegative whole number",
        .size => "a size like 64k or 1M",
        .duration => "a duration like 2s or 500ms",
        .string => "a valid value",
    };
}

fn formatIntegerHint(setting: *const Setting, buffer: []u8) []const u8 {
    if (setting.min) |minimum| {
        if (setting.max) |maximum| {
            return std.fmt.bufPrint(buffer, "a whole number from {d} to {d}", .{ minimum, maximum }) catch
                "a whole number in range";
        }
        return std.fmt.bufPrint(buffer, "a whole number of at least {d}", .{minimum}) catch
            "a whole number in range";
    }
    if (setting.max) |maximum| {
        return std.fmt.bufPrint(buffer, "a whole number from 0 to {d}", .{maximum}) catch
            "a whole number in range";
    }
    return "a nonnegative whole number";
}

pub fn inspect(
    store: Store,
    allocator: std.mem.Allocator,
    setting: *const Setting,
    maximum_display_bytes: usize,
) error{OutOfMemory}!Inspection {
    const bounded = try store.inspectBounded(
        allocator,
        setting.key,
        maximum_display_bytes,
        .{
            .context = setting,
            .classify_fn = classifyForStore,
            .secret = setting.secret,
        },
    );
    return .{
        .display = bounded.value,
        .source = bounded.source,
        .invalid = bounded.invalid,
        .clipped = bounded.clipped,
    };
}

fn classifyForStore(context: *const anyopaque, value: ?[]const u8) Store.Classification {
    const setting: *const Setting = @ptrCast(@alignCast(context));
    const text = value orelse return .{ .display = "unset" };
    if (text.len == 0) return .{ .display = "(empty)" };
    if (setting.kind == .bool) {
        const boolean = parseBool(text) orelse return .{ .display = text, .invalid = true };
        return .{ .display = if (boolean) "on" else "off" };
    }
    if (hasBooleanChoices(setting)) {
        if (choice(setting, text)) |canonical| {
            if (std.mem.eql(u8, canonical, "auto")) return .{ .display = "auto" };
        }
        const boolean = parseBool(text) orelse return .{ .display = text, .invalid = true };
        return .{ .display = if (boolean) "on" else "off" };
    }
    if (setting.kind == .string and setting.choices.len != 0)
        return .{ .display = text, .invalid = choice(setting, text) == null };
    if (choice(setting, text) != null) return .{ .display = text };
    return .{ .display = text, .invalid = !validTypedValue(setting, text) };
}

fn choice(setting: *const Setting, value: []const u8) ?[]const u8 {
    for (setting.choices) |canonical| {
        if (std.ascii.eqlIgnoreCase(value, canonical)) return canonical;
    }
    return null;
}

fn hasBooleanChoices(setting: *const Setting) bool {
    var on = false;
    var off = false;
    for (setting.choices) |value| {
        on = on or std.mem.eql(u8, value, "on");
        off = off or std.mem.eql(u8, value, "off");
    }
    return on and off;
}

fn validTypedValue(setting: *const Setting, value: []const u8) bool {
    if (setting.kind == .string and setting.choices.len == 0) return true;
    if (value.len == 0 or containsGrammarWhitespace(value)) return false;
    return switch (setting.kind) {
        .string => false,
        .bool => parseBool(value) != null,
        .int => blk: {
            for (value) |byte| if (!std.ascii.isDigit(byte)) break :blk false;
            const number = std.fmt.parseInt(i32, value, 10) catch break :blk false;
            break :blk inBounds(setting, number);
        },
        .size => if (strictUnsigned(value)) inUnsignedBounds(setting, parseSize(value) orelse return false) else false,
        .duration => if (strictUnsigned(value))
            inUnsignedBounds(setting, parseDurationMs(value) orelse return false)
        else
            false,
    };
}

fn strictUnsigned(value: []const u8) bool {
    return value.len != 0 and value[0] != '+' and value[0] != '-';
}

fn containsGrammarWhitespace(value: []const u8) bool {
    for (value) |byte| if (isCWhitespace(byte)) return true;
    return false;
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

pub const SizeResult = struct {
    value: u64,
    source: Store.Source,
};

pub const DurationMsResult = struct {
    value: u64,
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

/// Resolves a positive decimal size with an optional binary K or M suffix.
/// Invalid or out-of-bounds values fall back to the registry default, then zero.
pub fn getSize(
    store: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{OutOfMemory}!SizeResult {
    var resolved = try store.readNonempty(allocator, key);
    defer resolved.deinit(allocator);
    const setting = find(key);
    const parsed = if (resolved.value) |text| parseSize(text) else null;
    return .{
        .value = if (parsed) |value|
            if (inUnsignedBounds(setting, value)) value else fallbackSize(setting)
        else
            fallbackSize(setting),
        .source = resolved.source,
    };
}

/// Resolves a nonnegative decimal duration in milliseconds. Supported suffixes
/// are ms, s, m, and h; a missing suffix means seconds. Invalid or out-of-bounds
/// values fall back to the registry default, then zero.
pub fn getDurationMs(
    store: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) error{OutOfMemory}!DurationMsResult {
    var resolved = try store.readNonempty(allocator, key);
    defer resolved.deinit(allocator);
    const setting = find(key);
    const parsed = if (resolved.value) |text| parseDurationMs(text) else null;
    return .{
        .value = if (parsed) |value|
            if (inUnsignedBounds(setting, value)) value else fallbackDurationMs(setting)
        else
            fallbackDurationMs(setting),
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

const ParsedLong = struct {
    value: c_long,
    end: usize,
};

fn parseLongPrefix(text: []const u8) ?ParsedLong {
    var start: usize = 0;
    while (start < text.len and isCWhitespace(text[start])) start += 1;
    var end = start;
    if (end < text.len and (text[end] == '+' or text[end] == '-')) end += 1;
    const digits_start = end;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == digits_start) return null;
    return .{
        .value = std.fmt.parseInt(c_long, text[start..end], 10) catch return null,
        .end = end,
    };
}

fn skipUnitWhitespace(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
    return end;
}

fn parseSize(text: []const u8) ?u64 {
    const parsed = parseLongPrefix(text) orelse return null;
    if (parsed.value <= 0) return null;
    var end = skipUnitWhitespace(text, parsed.end);
    var multiplier: u64 = 1;
    if (end < text.len) switch (text[end]) {
        'k', 'K' => {
            multiplier = 1024;
            end += 1;
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            end += 1;
        },
        else => {},
    };
    end = skipUnitWhitespace(text, end);
    if (end != text.len) return null;
    const value: u64 = @intCast(parsed.value);
    const long_max: u64 = @intCast(std.math.maxInt(c_long));
    if (value > long_max / multiplier) return null;
    return value * multiplier;
}

fn parseDurationMs(text: []const u8) ?u64 {
    const parsed = parseLongPrefix(text) orelse return null;
    if (parsed.value < 0) return null;
    var end = skipUnitWhitespace(text, parsed.end);
    var multiplier: u64 = undefined;
    if (end + 1 < text.len and (text[end] == 'm' or text[end] == 'M') and
        (text[end + 1] == 's' or text[end + 1] == 'S'))
    {
        multiplier = 1;
        end += 2;
    } else if (end == text.len or text[end] == 's' or text[end] == 'S') {
        multiplier = 1000;
        if (end < text.len) end += 1;
    } else if (text[end] == 'm' or text[end] == 'M') {
        multiplier = 60_000;
        end += 1;
    } else if (text[end] == 'h' or text[end] == 'H') {
        multiplier = 3_600_000;
        end += 1;
    } else return null;
    end = skipUnitWhitespace(text, end);
    if (end != text.len) return null;
    const value: u64 = @intCast(parsed.value);
    const long_max: u64 = @intCast(std.math.maxInt(c_long));
    if (value > long_max / multiplier) return null;
    return value * multiplier;
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

fn inUnsignedBounds(setting: ?*const Setting, value: u64) bool {
    const metadata = setting orelse return true;
    if (metadata.min) |minimum| {
        if (minimum >= 0 and value < @as(u64, @intCast(minimum))) return false;
    }
    if (metadata.max) |maximum| {
        if (maximum < 0 or value > @as(u64, @intCast(maximum))) return false;
    }
    return true;
}

fn fallbackSize(setting: ?*const Setting) u64 {
    const metadata = setting orelse return 0;
    const text = metadata.default orelse return 0;
    return parseSize(text) orelse 0;
}

fn fallbackDurationMs(setting: ?*const Setting) u64 {
    const metadata = setting orelse return 0;
    const text = metadata.default orelse return 0;
    return parseDurationMs(text) orelse 0;
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
    try std.testing.expectEqual(@as(usize, 61), list().len);
    try std.testing.expectEqualStrings("preset", list()[0].key);
    try std.testing.expectEqualStrings("providers.mock.script", list()[60].key);

    const threshold = find("compact.threshold").?;
    try std.testing.expectEqual(Kind.int, threshold.kind);
    try std.testing.expectEqual(@as(?i32, 1), threshold.min);
    try std.testing.expectEqual(@as(?i32, 100), threshold.max);
    try std.testing.expectEqualStrings("85", threshold.default.?);

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
        "theme",
        "tint",
        "compact.auto",
        "compact.threshold",
        "max_turns",
        "catalog.url",
        "catalog.refresh",
        "no_session",
        "session_retention_days",
        "transcript",
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
        "providers.mock.script",
    };
    try std.testing.expectEqual(expected.len, list().len);
    for (&expected, list()) |key, setting| try std.testing.expectEqualStrings(key, setting.key);
    for (list(), 0..) |left, left_index| {
        try std.testing.expect(std.mem.startsWith(u8, left.env, "ZI_"));
        for (list()[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.key, right.key));
            try std.testing.expect(!std.mem.eql(u8, left.env, right.env));
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

    const high: MapEnvironment = .{ .name = "ZI_COMPACT_THRESHOLD", .value = "101" };
    const bounded = try getInt(testStore(&high), std.testing.allocator, "compact.threshold");
    try std.testing.expectEqual(@as(i32, 85), bounded.value);
    try std.testing.expectEqual(Store.Source.env, bounded.source);

    const signed: MapEnvironment = .{ .name = "ZI_MAX_TURNS", .value = "  +2147483647" };
    const maximum = try getInt(testStore(&signed), std.testing.allocator, "max_turns");
    try std.testing.expectEqual(std.math.maxInt(i32), maximum.value);

    const overflow: MapEnvironment = .{ .name = "ZI_MAX_TURNS", .value = "2147483648" };
    const invalid = try getInt(testStore(&overflow), std.testing.allocator, "max_turns");
    try std.testing.expectEqual(@as(i32, 0), invalid.value);

    const boolean: MapEnvironment = .{ .name = "ZI_MARKDOWN", .value = "OFF" };
    const disabled = try getBool(testStore(&boolean), std.testing.allocator, "markdown");
    try std.testing.expect(!disabled.value);
}

test "size parser matches hax thresholds whitespace and overflow" {
    const long_max = comptime @as(u64, @intCast(std.math.maxInt(c_long)));
    const long_max_text = std.fmt.comptimePrint("{d}", .{long_max});
    const long_overflow_text = std.fmt.comptimePrint("{d}", .{@as(u128, long_max) + 1});
    const multiplied_overflow_text = std.fmt.comptimePrint("{d}k", .{long_max / 1024 + 1});

    try std.testing.expectEqual(@as(?u64, 1), parseSize("1"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize(" \t+1 \tK\t"));
    try std.testing.expectEqual(@as(?u64, 2 * 1024 * 1024), parseSize("\n2m"));
    try std.testing.expectEqual(@as(?u64, long_max), parseSize(long_max_text));

    const invalid = [_][]const u8{
        "",
        " \t",
        "0",
        "-1",
        "1g",
        "1kb",
        "1k\n",
        long_overflow_text,
        multiplied_overflow_text,
    };
    for (&invalid) |text| try std.testing.expect(parseSize(text) == null);
}

test "duration parser matches hax units whitespace and overflow" {
    const long_max = comptime @as(u64, @intCast(std.math.maxInt(c_long)));
    const long_max_ms = std.fmt.comptimePrint("{d}ms", .{long_max});
    const long_overflow_ms = std.fmt.comptimePrint("{d}ms", .{@as(u128, long_max) + 1});
    const seconds_threshold = long_max / 1000;
    const maximum_seconds = std.fmt.comptimePrint("{d}s", .{seconds_threshold});
    const overflowing_seconds = std.fmt.comptimePrint("{d}s", .{seconds_threshold + 1});
    const overflowing_default_seconds = std.fmt.comptimePrint("{d}", .{long_max});

    try std.testing.expectEqual(@as(?u64, 0), parseDurationMs("0"));
    try std.testing.expectEqual(@as(?u64, 0), parseDurationMs("-0ms"));
    try std.testing.expectEqual(@as(?u64, 12_000), parseDurationMs(" \t+12 \tS\t"));
    try std.testing.expectEqual(@as(?u64, 12), parseDurationMs("12mS"));
    try std.testing.expectEqual(@as(?u64, 120_000), parseDurationMs("2M"));
    try std.testing.expectEqual(@as(?u64, 7_200_000), parseDurationMs("2h"));
    try std.testing.expectEqual(@as(?u64, long_max), parseDurationMs(long_max_ms));
    try std.testing.expectEqual(@as(?u64, seconds_threshold * 1000), parseDurationMs(maximum_seconds));

    const invalid = [_][]const u8{
        "",
        " \t",
        "-1ms",
        "1d",
        "1m s",
        "1ms\n",
        long_overflow_ms,
        overflowing_seconds,
        overflowing_default_seconds,
    };
    for (&invalid) |text| try std.testing.expect(parseDurationMs(text) == null);
}

test "size and duration getters preserve source and use converted bounds" {
    const invalid_size: MapEnvironment = .{ .name = "ZI_TOOL_OUTPUT_CAP", .value = "0" };
    const size_fallback = try getSize(testStore(&invalid_size), std.testing.allocator, "tool_output_cap");
    try std.testing.expectEqual(@as(u64, 50 * 1024), size_fallback.value);
    try std.testing.expectEqual(Store.Source.env, size_fallback.source);

    const custom_size: MapEnvironment = .{ .name = "ZI_TOOL_OUTPUT_CAP", .value = "2M" };
    const size = try getSize(testStore(&custom_size), std.testing.allocator, "tool_output_cap");
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), size.value);
    try std.testing.expectEqual(Store.Source.env, size.source);

    const excessive_grace: MapEnvironment = .{ .name = "ZI_BASH_TIMEOUT_GRACE", .value = "301s" };
    const duration_fallback = try getDurationMs(
        testStore(&excessive_grace),
        std.testing.allocator,
        "bash.timeout_grace",
    );
    try std.testing.expectEqual(@as(u64, 2_000), duration_fallback.value);
    try std.testing.expectEqual(Store.Source.env, duration_fallback.source);

    const maximum_grace: MapEnvironment = .{ .name = "ZI_BASH_TIMEOUT_GRACE", .value = "300000ms" };
    const duration = try getDurationMs(testStore(&maximum_grace), std.testing.allocator, "bash.timeout_grace");
    try std.testing.expectEqual(@as(u64, 300_000), duration.value);

    const below_minimum: MapEnvironment = .{ .name = "ZI_HTTP_RETRY_BASE", .value = "0ms" };
    const minimum_fallback = try getDurationMs(
        testStore(&below_minimum),
        std.testing.allocator,
        "http.retry_base",
    );
    try std.testing.expectEqual(@as(u64, 1_000), minimum_fallback.value);

    const unknown = try getDurationMs(testStore(&below_minimum), std.testing.allocator, "unknown");
    try std.testing.expectEqual(@as(u64, 0), unknown.value);
    try std.testing.expectEqual(Store.Source.default, unknown.source);

    const bounded_size: Setting = .{
        .key = "test",
        .env = "TEST",
        .default = "1k",
        .keep_empty = false,
        .kind = .size,
        .min = 1024,
        .max = 2048,
        .description = "test",
    };
    try std.testing.expect(inUnsignedBounds(&bounded_size, parseSize("1k").?));
    try std.testing.expect(!inUnsignedBounds(&bounded_size, parseSize("3k").?));
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
            _ = try getSize(value, allocator, "tool_output_cap");
            _ = try getDurationMs(value, allocator, "bash.timeout");
        }
    }.exercise, .{store});
}

test "config command metadata pins slice two editability and secrets" {
    const editable = [_][]const u8{
        "markdown",
        "show_reasoning",
        "sort_models",
        "context_limit",
        "display_width",
        "theme",
        "tint",
        "compact.auto",
        "compact.threshold",
        "max_turns",
        "image_input",
        "tool_output_cap",
        "bash.timeout",
        "bash.timeout_max",
        "bash.timeout_grace",
        "bash.background_yield",
        "task.wait_timeout",
        "task.max_running",
        "http.max_retries",
        "http.retry_base",
        "http.idle_timeout",
    };
    var editable_count: usize = 0;
    var secret_count: usize = 0;
    for (list()) |setting| {
        if (setting.editable) {
            try std.testing.expect(editable_count < editable.len);
            try std.testing.expectEqualStrings(editable[editable_count], setting.key);
            editable_count += 1;
        }
        secret_count += @intFromBool(setting.secret);
    }
    try std.testing.expectEqual(editable.len, editable_count);
    try std.testing.expectEqual(@as(usize, 3), secret_count);
    try std.testing.expectEqualStrings("100", find("display_width").?.example.?);
    try std.testing.expectEqualStrings("auto", find("image_input").?.choices[0]);
}

test "inspection preserves enum spelling and accepts free-form whitespace" {
    var theme_environment: MapEnvironment = .{ .name = "ZI_THEME", .value = "LIGHT" };
    var theme = try inspect(
        testStore(&theme_environment),
        std.testing.allocator,
        find("theme").?,
        4096,
    );
    defer theme.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("LIGHT", theme.display);
    try std.testing.expect(!theme.invalid);

    var prompt_environment: MapEnvironment = .{ .name = "ZI_SYSTEM_PROMPT", .value = "hello world" };
    var prompt = try inspect(
        testStore(&prompt_environment),
        std.testing.allocator,
        find("system_prompt").?,
        4096,
    );
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello world", prompt.display);
    try std.testing.expect(!prompt.invalid);
}

test "runtime update validation is complete strict and canonical" {
    const sort = find("sort_models").?;
    try std.testing.expectEqualStrings("auto", (try validateUpdate(sort, "AUTO")).set);
    try std.testing.expectEqualStrings("YES", (try validateUpdate(sort, "YES")).set);
    try std.testing.expect((try validateUpdate(sort, "default")) == .clear);
    try std.testing.expectError(error.InvalidValue, validateUpdate(sort, "auto "));

    const threshold = find("compact.threshold").?;
    try std.testing.expectEqualStrings("75", (try validateUpdate(threshold, "75")).set);
    try std.testing.expectError(error.InvalidValue, validateUpdate(threshold, "0"));
    try std.testing.expectError(error.InvalidValue, validateUpdate(threshold, "101"));
    try std.testing.expectError(error.InvalidValue, validateUpdate(threshold, " 75"));
    try std.testing.expectError(error.InvalidValue, validateUpdate(threshold, "75 "));
    try std.testing.expectError(error.InvalidValue, validateUpdate(threshold, "7_5"));

    const width = find("display_width").?;
    try std.testing.expectEqualStrings("120", (try validateUpdate(width, "120")).set);
    try std.testing.expectError(error.ReadOnly, validateUpdate(find("provider").?, "mock"));
}

test "inspection normalizes aliases marks invalid values and redacts secrets" {
    var boolean_environment: MapEnvironment = .{ .name = "ZI_SORT_MODELS", .value = "YES" };
    var normalized = try inspect(
        testStore(&boolean_environment),
        std.testing.allocator,
        find("sort_models").?,
        4096,
    );
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("on", normalized.display);
    try std.testing.expect(!normalized.invalid);

    var invalid_environment: MapEnvironment = .{ .name = "ZI_COMPACT_THRESHOLD", .value = "banana" };
    var invalid = try inspect(
        testStore(&invalid_environment),
        std.testing.allocator,
        find("compact.threshold").?,
        4096,
    );
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("banana", invalid.display);
    try std.testing.expect(invalid.invalid);

    var secret_environment: MapEnvironment = .{ .name = "ZI_OPENAI_API_KEY", .value = "hidden" };
    var secret = try inspect(
        testStore(&secret_environment),
        std.testing.allocator,
        find("providers.openai-compatible.api_key").?,
        4096,
    );
    defer secret.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("set", secret.display);
}
