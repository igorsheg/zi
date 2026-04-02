const std = @import("std");
const ai = @import("ai");

// ── enums ──────────────────────────────────────────────────────────────

/// pi-mono: settings-manager.ts:67 — includes "off" which ai.protocol.ThinkingLevel lacks
pub const DefaultThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

/// pi-mono: settings-manager.ts:69
pub const SteeringMode = enum {
    all,
    one_at_a_time,
};

/// pi-mono: settings-manager.ts:70
pub const FollowUpMode = enum {
    all,
    one_at_a_time,
};

/// pi-mono: settings-manager.ts:90
pub const DoubleEscapeAction = enum {
    fork,
    tree,
    none,
};

/// pi-mono: settings-manager.ts:91
pub const TreeFilterMode = enum {
    default,
    no_tools,
    user_only,
    labeled_only,
    all,
};

pub const SettingsScope = enum {
    global,
    project,
};

pub const TransportSetting = ai.protocol.Transport;

// ── nested settings structs ────────────────────────────────────────────

/// pi-mono: settings-manager.ts:7-11
pub const CompactionSettings = struct {
    enabled: ?bool = null,
    reserve_tokens: ?i64 = null,
    keep_recent_tokens: ?i64 = null,
};

/// pi-mono: settings-manager.ts:13-16
pub const BranchSummarySettings = struct {
    reserve_tokens: ?i64 = null,
    skip_prompt: ?bool = null,
};

/// pi-mono: settings-manager.ts:18-23
pub const RetrySettings = struct {
    enabled: ?bool = null,
    max_retries: ?i64 = null,
    base_delay_ms: ?i64 = null,
    max_delay_ms: ?i64 = null,
};

/// pi-mono: settings-manager.ts:25-28
pub const TerminalSettings = struct {
    show_images: ?bool = null,
    clear_on_shrink: ?bool = null,
};

/// pi-mono: settings-manager.ts:30-33
pub const ImageSettings = struct {
    auto_resize: ?bool = null,
    block_images: ?bool = null,
};

/// pi-mono: settings-manager.ts:35-40
pub const ThinkingBudgetsSettings = struct {
    minimal: ?i64 = null,
    low: ?i64 = null,
    medium: ?i64 = null,
    high: ?i64 = null,
};

/// pi-mono: settings-manager.ts:42-44
pub const MarkdownSettings = struct {
    code_block_indent: ?[]const u8 = null,
};

/// pi-mono: settings-manager.ts:53-61
pub const PackageSourceFilter = struct {
    source: []const u8,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
};

/// pi-mono: settings-manager.ts:48-61
pub const PackageSource = union(enum) {
    string: []const u8,
    filtered: PackageSourceFilter,
};

// ── main Settings struct ───────────────────────────────────────────────

/// All user-configurable settings. Every field is optional.
/// pi-mono: settings-manager.ts:63-98
pub const Settings = struct {
    last_changelog_version: ?[]const u8 = null,
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?DefaultThinkingLevel = null,
    transport: ?TransportSetting = null,
    steering_mode: ?SteeringMode = null,
    follow_up_mode: ?FollowUpMode = null,
    theme: ?[]const u8 = null,
    compaction: ?CompactionSettings = null,
    branch_summary: ?BranchSummarySettings = null,
    retry: ?RetrySettings = null,
    hide_thinking_block: ?bool = null,
    shell_path: ?[]const u8 = null,
    quiet_startup: ?bool = null,
    shell_command_prefix: ?[]const u8 = null,
    npm_command: ?[]const []const u8 = null,
    collapse_changelog: ?bool = null,
    packages: ?[]const PackageSource = null,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes_paths: ?[]const []const u8 = null,
    enable_skill_commands: ?bool = null,
    terminal: ?TerminalSettings = null,
    images: ?ImageSettings = null,
    enabled_models: ?[]const []const u8 = null,
    double_escape_action: ?DoubleEscapeAction = null,
    tree_filter_mode: ?TreeFilterMode = null,
    thinking_budgets: ?ThinkingBudgetsSettings = null,
    editor_padding_x: ?i64 = null,
    autocomplete_max_visible: ?i64 = null,
    show_hardware_cursor: ?bool = null,
    markdown: ?MarkdownSettings = null,
    session_dir: ?[]const u8 = null,
};

// ── resolved settings (with defaults applied) ──────────────────────────

/// pi-mono: settings-manager.ts:637-643
pub const ResolvedCompactionSettings = struct {
    enabled: bool,
    reserve_tokens: i64,
    keep_recent_tokens: i64,
};

/// pi-mono: settings-manager.ts:645-649
pub const ResolvedBranchSummarySettings = struct {
    reserve_tokens: i64,
    skip_prompt: bool,
};

/// pi-mono: settings-manager.ts derived from getRetrySettings
pub const ResolvedRetrySettings = struct {
    enabled: bool,
    max_retries: i64,
    base_delay_ms: i64,
    max_delay_ms: i64,
};

// ── error type ─────────────────────────────────────────────────────────

pub const SettingsError = struct {
    scope: SettingsScope,
    message: []const u8,
};

// ── field enum for dirty tracking ──────────────────────────────────────

pub const SettingsField = enum {
    last_changelog_version,
    default_provider,
    default_model,
    default_thinking_level,
    transport,
    steering_mode,
    follow_up_mode,
    theme,
    compaction,
    branch_summary,
    retry,
    hide_thinking_block,
    shell_path,
    quiet_startup,
    shell_command_prefix,
    npm_command,
    collapse_changelog,
    packages,
    extensions,
    skills,
    prompts,
    themes_paths,
    enable_skill_commands,
    terminal,
    images,
    enabled_models,
    double_escape_action,
    tree_filter_mode,
    thinking_budgets,
    editor_padding_x,
    autocomplete_max_visible,
    show_hardware_cursor,
    markdown,
    session_dir,
};

// ── string conversion helpers (camelCase wire format) ──────────────────

pub fn defaultThinkingLevelToString(level: DefaultThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn defaultThinkingLevelFromString(s: []const u8) ?DefaultThinkingLevel {
    const map = std.StaticStringMap(DefaultThinkingLevel).initComptime(.{
        .{ "off", .off },
        .{ "minimal", .minimal },
        .{ "low", .low },
        .{ "medium", .medium },
        .{ "high", .high },
        .{ "xhigh", .xhigh },
    });
    return map.get(s);
}

pub fn steeringModeToString(mode: SteeringMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

pub fn steeringModeFromString(s: []const u8) ?SteeringMode {
    const map = std.StaticStringMap(SteeringMode).initComptime(.{
        .{ "all", .all },
        .{ "one-at-a-time", .one_at_a_time },
    });
    return map.get(s);
}

pub fn followUpModeToString(mode: FollowUpMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

pub fn followUpModeFromString(s: []const u8) ?FollowUpMode {
    const map = std.StaticStringMap(FollowUpMode).initComptime(.{
        .{ "all", .all },
        .{ "one-at-a-time", .one_at_a_time },
    });
    return map.get(s);
}

pub fn doubleEscapeActionToString(action: DoubleEscapeAction) []const u8 {
    return switch (action) {
        .fork => "fork",
        .tree => "tree",
        .none => "none",
    };
}

pub fn doubleEscapeActionFromString(s: []const u8) ?DoubleEscapeAction {
    const map = std.StaticStringMap(DoubleEscapeAction).initComptime(.{
        .{ "fork", .fork },
        .{ "tree", .tree },
        .{ "none", .none },
    });
    return map.get(s);
}

pub fn treeFilterModeToString(mode: TreeFilterMode) []const u8 {
    return switch (mode) {
        .default => "default",
        .no_tools => "no-tools",
        .user_only => "user-only",
        .labeled_only => "labeled-only",
        .all => "all",
    };
}

pub fn treeFilterModeFromString(s: []const u8) ?TreeFilterMode {
    const map = std.StaticStringMap(TreeFilterMode).initComptime(.{
        .{ "default", .default },
        .{ "no-tools", .no_tools },
        .{ "user-only", .user_only },
        .{ "labeled-only", .labeled_only },
        .{ "all", .all },
    });
    return map.get(s);
}

pub fn transportToString(t: TransportSetting) []const u8 {
    return switch (t) {
        .sse => "sse",
        .websocket => "websocket",
        .auto => "auto",
    };
}

pub fn transportFromString(s: []const u8) ?TransportSetting {
    const map = std.StaticStringMap(TransportSetting).initComptime(.{
        .{ "sse", .sse },
        .{ "websocket", .websocket },
        .{ "auto", .auto },
    });
    return map.get(s);
}

// ── camelCase field name mapping for JSON keys ─────────────────────────

pub fn settingsFieldToJsonKey(field: SettingsField) []const u8 {
    return switch (field) {
        .last_changelog_version => "lastChangelogVersion",
        .default_provider => "defaultProvider",
        .default_model => "defaultModel",
        .default_thinking_level => "defaultThinkingLevel",
        .transport => "transport",
        .steering_mode => "steeringMode",
        .follow_up_mode => "followUpMode",
        .theme => "theme",
        .compaction => "compaction",
        .branch_summary => "branchSummary",
        .retry => "retry",
        .hide_thinking_block => "hideThinkingBlock",
        .shell_path => "shellPath",
        .quiet_startup => "quietStartup",
        .shell_command_prefix => "shellCommandPrefix",
        .npm_command => "npmCommand",
        .collapse_changelog => "collapseChangelog",
        .packages => "packages",
        .extensions => "extensions",
        .skills => "skills",
        .prompts => "prompts",
        .themes_paths => "themes",
        .enable_skill_commands => "enableSkillCommands",
        .terminal => "terminal",
        .images => "images",
        .enabled_models => "enabledModels",
        .double_escape_action => "doubleEscapeAction",
        .tree_filter_mode => "treeFilterMode",
        .thinking_budgets => "thinkingBudgets",
        .editor_padding_x => "editorPaddingX",
        .autocomplete_max_visible => "autocompleteMaxVisible",
        .show_hardware_cursor => "showHardwareCursor",
        .markdown => "markdown",
        .session_dir => "sessionDir",
    };
}
