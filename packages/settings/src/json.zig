const std = @import("std");
const types = @import("types.zig");

const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Owns the memory backing string values in the returned Settings.
/// Caller must keep alive as long as settings is used, then call deinit.
pub const ParseResult = struct {
    settings: types.Settings,
    parsed: std.json.Parsed(Value),

    pub fn deinit(self: *ParseResult) void {
        self.parsed.deinit();
    }
};

// ─── Parsing ────────────────────────────────────────────────────────

/// Parse a JSON string into typed Settings.
/// All allocated memory (string array slices, packages) lives in the parsed
/// arena — calling `ParseResult.deinit()` frees everything.
/// pi-mono: settings-manager.ts:291-302 (loadFromStorage parse path)
pub fn parseSettingsJson(allocator: std.mem.Allocator, json_content: []const u8) !ParseResult {
    const parsed = try std.json.parseFromSlice(Value, allocator, json_content, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.UnexpectedToken;

    const arena = parsed.arena.allocator();
    var settings: types.Settings = .{};
    const obj = &parsed.value.object;

    // ── string fields ──
    if (obj.get("lastChangelogVersion")) |v| {
        if (v == .string) settings.last_changelog_version = v.string;
    }
    if (obj.get("defaultProvider")) |v| {
        if (v == .string) settings.default_provider = v.string;
    }
    if (obj.get("defaultModel")) |v| {
        if (v == .string) settings.default_model = v.string;
    }
    if (obj.get("theme")) |v| {
        if (v == .string) settings.theme = v.string;
    }
    if (obj.get("shellPath")) |v| {
        if (v == .string) settings.shell_path = v.string;
    }
    if (obj.get("shellCommandPrefix")) |v| {
        if (v == .string) settings.shell_command_prefix = v.string;
    }
    if (obj.get("sessionDir")) |v| {
        if (v == .string) settings.session_dir = v.string;
    }

    // ── enum fields ──
    if (obj.get("defaultThinkingLevel")) |v| {
        if (v == .string) settings.default_thinking_level = types.defaultThinkingLevelFromString(v.string);
    }
    if (obj.get("transport")) |v| {
        if (v == .string) settings.transport = types.transportFromString(v.string);
    }
    if (obj.get("steeringMode")) |v| {
        if (v == .string) settings.steering_mode = types.steeringModeFromString(v.string);
    }
    if (obj.get("followUpMode")) |v| {
        if (v == .string) settings.follow_up_mode = types.followUpModeFromString(v.string);
    }
    if (obj.get("doubleEscapeAction")) |v| {
        if (v == .string) settings.double_escape_action = types.doubleEscapeActionFromString(v.string);
    }
    if (obj.get("treeFilterMode")) |v| {
        if (v == .string) settings.tree_filter_mode = types.treeFilterModeFromString(v.string);
    }

    // ── bool fields ──
    if (obj.get("hideThinkingBlock")) |v| {
        if (v == .bool) settings.hide_thinking_block = v.bool;
    }
    if (obj.get("quietStartup")) |v| {
        if (v == .bool) settings.quiet_startup = v.bool;
    }
    if (obj.get("collapseChangelog")) |v| {
        if (v == .bool) settings.collapse_changelog = v.bool;
    }
    if (obj.get("enableSkillCommands")) |v| {
        if (v == .bool) settings.enable_skill_commands = v.bool;
    }
    if (obj.get("showHardwareCursor")) |v| {
        if (v == .bool) settings.show_hardware_cursor = v.bool;
    }

    // ── integer fields ──
    if (obj.get("editorPaddingX")) |v| {
        if (v == .integer) settings.editor_padding_x = v.integer;
    }
    if (obj.get("autocompleteMaxVisible")) |v| {
        if (v == .integer) settings.autocomplete_max_visible = v.integer;
    }

    // ── nested struct fields ──
    if (obj.get("compaction")) |v| {
        if (v == .object) settings.compaction = parseCompaction(&v.object);
    }
    if (obj.get("branchSummary")) |v| {
        if (v == .object) settings.branch_summary = parseBranchSummary(&v.object);
    }
    if (obj.get("retry")) |v| {
        if (v == .object) settings.retry = parseRetry(&v.object);
    }
    if (obj.get("terminal")) |v| {
        if (v == .object) settings.terminal = parseTerminal(&v.object);
    }
    if (obj.get("images")) |v| {
        if (v == .object) settings.images = parseImages(&v.object);
    }
    if (obj.get("thinkingBudgets")) |v| {
        if (v == .object) settings.thinking_budgets = parseThinkingBudgets(&v.object);
    }
    if (obj.get("markdown")) |v| {
        if (v == .object) settings.markdown = parseMarkdown(&v.object);
    }

    // ── string array fields ──
    if (obj.get("extensions")) |v| {
        settings.extensions = try parseStringArray(arena, v);
    }
    if (obj.get("skills")) |v| {
        settings.skills = try parseStringArray(arena, v);
    }
    if (obj.get("prompts")) |v| {
        settings.prompts = try parseStringArray(arena, v);
    }
    if (obj.get("themes")) |v| {
        settings.themes_paths = try parseStringArray(arena, v);
    }
    if (obj.get("enabledModels")) |v| {
        settings.enabled_models = try parseStringArray(arena, v);
    }
    if (obj.get("npmCommand")) |v| {
        settings.npm_command = try parseStringArray(arena, v);
    }

    // ── packages (union array) ──
    if (obj.get("packages")) |v| {
        settings.packages = try parsePackages(arena, v);
    }

    return .{ .settings = settings, .parsed = parsed };
}

// ─── Nested Struct Parsers ──────────────────────────────────────────

fn parseCompaction(obj: *const ObjectMap) types.CompactionSettings {
    var c: types.CompactionSettings = .{};
    if (obj.get("enabled")) |v| {
        if (v == .bool) c.enabled = v.bool;
    }
    if (obj.get("reserveTokens")) |v| {
        if (v == .integer) c.reserve_tokens = v.integer;
    }
    if (obj.get("keepRecentTokens")) |v| {
        if (v == .integer) c.keep_recent_tokens = v.integer;
    }
    return c;
}

fn parseBranchSummary(obj: *const ObjectMap) types.BranchSummarySettings {
    var s: types.BranchSummarySettings = .{};
    if (obj.get("reserveTokens")) |v| {
        if (v == .integer) s.reserve_tokens = v.integer;
    }
    if (obj.get("skipPrompt")) |v| {
        if (v == .bool) s.skip_prompt = v.bool;
    }
    return s;
}

fn parseRetry(obj: *const ObjectMap) types.RetrySettings {
    var r: types.RetrySettings = .{};
    if (obj.get("enabled")) |v| {
        if (v == .bool) r.enabled = v.bool;
    }
    if (obj.get("maxRetries")) |v| {
        if (v == .integer) r.max_retries = v.integer;
    }
    if (obj.get("baseDelayMs")) |v| {
        if (v == .integer) r.base_delay_ms = v.integer;
    }
    if (obj.get("maxDelayMs")) |v| {
        if (v == .integer) r.max_delay_ms = v.integer;
    }
    return r;
}

fn parseTerminal(obj: *const ObjectMap) types.TerminalSettings {
    var t: types.TerminalSettings = .{};
    if (obj.get("showImages")) |v| {
        if (v == .bool) t.show_images = v.bool;
    }
    if (obj.get("clearOnShrink")) |v| {
        if (v == .bool) t.clear_on_shrink = v.bool;
    }
    return t;
}

fn parseImages(obj: *const ObjectMap) types.ImageSettings {
    var i: types.ImageSettings = .{};
    if (obj.get("autoResize")) |v| {
        if (v == .bool) i.auto_resize = v.bool;
    }
    if (obj.get("blockImages")) |v| {
        if (v == .bool) i.block_images = v.bool;
    }
    return i;
}

fn parseThinkingBudgets(obj: *const ObjectMap) types.ThinkingBudgetsSettings {
    var t: types.ThinkingBudgetsSettings = .{};
    if (obj.get("minimal")) |v| {
        if (v == .integer) t.minimal = v.integer;
    }
    if (obj.get("low")) |v| {
        if (v == .integer) t.low = v.integer;
    }
    if (obj.get("medium")) |v| {
        if (v == .integer) t.medium = v.integer;
    }
    if (obj.get("high")) |v| {
        if (v == .integer) t.high = v.integer;
    }
    return t;
}

fn parseMarkdown(obj: *const ObjectMap) types.MarkdownSettings {
    var m: types.MarkdownSettings = .{};
    if (obj.get("codeBlockIndent")) |v| {
        if (v == .string) m.code_block_indent = v.string;
    }
    return m;
}

/// Extract a string array from a JSON value. Allocates the slice of pointers
/// into the arena; the string data itself points into the parsed JSON tree.
fn parseStringArray(arena: std.mem.Allocator, v: Value) !?[]const []const u8 {
    if (v != .array) return null;
    const items = v.array.items;
    var count: usize = 0;
    for (items) |item| {
        if (item == .string) count += 1;
    }
    if (count == 0) return null;
    const result = try arena.alloc([]const u8, count);
    var idx: usize = 0;
    for (items) |item| {
        if (item == .string) {
            result[idx] = item.string;
            idx += 1;
        }
    }
    return result;
}

fn parsePackages(arena: std.mem.Allocator, v: Value) !?[]const types.PackageSource {
    if (v != .array) return null;
    const items = v.array.items;
    var count: usize = 0;
    for (items) |item| {
        if (item == .string or item == .object) count += 1;
    }
    if (count == 0) return null;
    const result = try arena.alloc(types.PackageSource, count);
    var idx: usize = 0;
    for (items) |item| {
        switch (item) {
            .string => |s| {
                result[idx] = .{ .string = s };
                idx += 1;
            },
            .object => |obj| {
                const source = obj.get("source") orelse continue;
                if (source != .string) continue;
                result[idx] = .{ .filtered = .{
                    .source = source.string,
                    .extensions = if (obj.get("extensions")) |ev| try parseStringArray(arena, ev) else null,
                    .skills = if (obj.get("skills")) |sv| try parseStringArray(arena, sv) else null,
                    .prompts = if (obj.get("prompts")) |pv| try parseStringArray(arena, pv) else null,
                    .themes = if (obj.get("themes")) |tv| try parseStringArray(arena, tv) else null,
                } };
                idx += 1;
            },
            else => {},
        }
    }
    return result[0..idx];
}

// ─── Deep Merge ─────────────────────────────────────────────────────

/// Deep merge: overrides take precedence over base.
/// For nested structs, sub-fields merge (override non-null fields only).
/// For primitives and arrays, override replaces entirely.
/// Does not allocate — copies field values (pointers into existing memory).
/// pi-mono: settings-manager.ts:100-129
pub fn deepMergeSettings(base: types.Settings, overrides: types.Settings) types.Settings {
    var result = base;

    // ── simple fields: override wins if non-null ──
    if (overrides.last_changelog_version) |v| result.last_changelog_version = v;
    if (overrides.default_provider) |v| result.default_provider = v;
    if (overrides.default_model) |v| result.default_model = v;
    if (overrides.default_thinking_level) |v| result.default_thinking_level = v;
    if (overrides.transport) |v| result.transport = v;
    if (overrides.steering_mode) |v| result.steering_mode = v;
    if (overrides.follow_up_mode) |v| result.follow_up_mode = v;
    if (overrides.theme) |v| result.theme = v;
    if (overrides.hide_thinking_block) |v| result.hide_thinking_block = v;
    if (overrides.shell_path) |v| result.shell_path = v;
    if (overrides.quiet_startup) |v| result.quiet_startup = v;
    if (overrides.shell_command_prefix) |v| result.shell_command_prefix = v;
    if (overrides.collapse_changelog) |v| result.collapse_changelog = v;
    if (overrides.enable_skill_commands) |v| result.enable_skill_commands = v;
    if (overrides.double_escape_action) |v| result.double_escape_action = v;
    if (overrides.tree_filter_mode) |v| result.tree_filter_mode = v;
    if (overrides.editor_padding_x) |v| result.editor_padding_x = v;
    if (overrides.autocomplete_max_visible) |v| result.autocomplete_max_visible = v;
    if (overrides.show_hardware_cursor) |v| result.show_hardware_cursor = v;
    if (overrides.session_dir) |v| result.session_dir = v;

    // ── array fields: override replaces entirely ──
    if (overrides.npm_command) |v| result.npm_command = v;
    if (overrides.packages) |v| result.packages = v;
    if (overrides.extensions) |v| result.extensions = v;
    if (overrides.skills) |v| result.skills = v;
    if (overrides.prompts) |v| result.prompts = v;
    if (overrides.themes_paths) |v| result.themes_paths = v;
    if (overrides.enabled_models) |v| result.enabled_models = v;

    // ── nested structs: merge sub-fields ──
    if (overrides.compaction) |ov| {
        if (result.compaction) |base_c| {
            var merged = base_c;
            if (ov.enabled) |v| merged.enabled = v;
            if (ov.reserve_tokens) |v| merged.reserve_tokens = v;
            if (ov.keep_recent_tokens) |v| merged.keep_recent_tokens = v;
            result.compaction = merged;
        } else {
            result.compaction = ov;
        }
    }
    if (overrides.branch_summary) |ov| {
        if (result.branch_summary) |base_s| {
            var merged = base_s;
            if (ov.reserve_tokens) |v| merged.reserve_tokens = v;
            if (ov.skip_prompt) |v| merged.skip_prompt = v;
            result.branch_summary = merged;
        } else {
            result.branch_summary = ov;
        }
    }
    if (overrides.retry) |ov| {
        if (result.retry) |base_r| {
            var merged = base_r;
            if (ov.enabled) |v| merged.enabled = v;
            if (ov.max_retries) |v| merged.max_retries = v;
            if (ov.base_delay_ms) |v| merged.base_delay_ms = v;
            if (ov.max_delay_ms) |v| merged.max_delay_ms = v;
            result.retry = merged;
        } else {
            result.retry = ov;
        }
    }
    if (overrides.terminal) |ov| {
        if (result.terminal) |base_t| {
            var merged = base_t;
            if (ov.show_images) |v| merged.show_images = v;
            if (ov.clear_on_shrink) |v| merged.clear_on_shrink = v;
            result.terminal = merged;
        } else {
            result.terminal = ov;
        }
    }
    if (overrides.images) |ov| {
        if (result.images) |base_i| {
            var merged = base_i;
            if (ov.auto_resize) |v| merged.auto_resize = v;
            if (ov.block_images) |v| merged.block_images = v;
            result.images = merged;
        } else {
            result.images = ov;
        }
    }
    if (overrides.thinking_budgets) |ov| {
        if (result.thinking_budgets) |base_t| {
            var merged = base_t;
            if (ov.minimal) |v| merged.minimal = v;
            if (ov.low) |v| merged.low = v;
            if (ov.medium) |v| merged.medium = v;
            if (ov.high) |v| merged.high = v;
            result.thinking_budgets = merged;
        } else {
            result.thinking_budgets = ov;
        }
    }
    if (overrides.markdown) |ov| {
        if (result.markdown) |base_m| {
            var merged = base_m;
            if (ov.code_block_indent) |v| merged.code_block_indent = v;
            result.markdown = merged;
        } else {
            result.markdown = ov;
        }
    }

    return result;
}

// ─── Serialization ──────────────────────────────────────────────────

/// Serialize a raw JSON ObjectMap to a pretty-printed JSON string (2-space indent).
pub fn serializeSettingsObject(allocator: std.mem.Allocator, object: ObjectMap) ![]const u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        Value{ .object = object },
        .{ .whitespace = .indent_2 },
    );
}

/// Serialize typed Settings to a pretty-printed JSON string.
/// Only writes non-null fields.
pub fn serializeSettings(allocator: std.mem.Allocator, settings: *const types.Settings) ![]const u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();
    try writeSettingsFields(&jw, settings);
    try jw.endObject();

    return out.toOwnedSlice();
}

fn writeSettingsFields(jw: *Stringify, settings: *const types.Settings) !void {
    // ── string fields ──
    if (settings.last_changelog_version) |v| {
        try jw.objectField("lastChangelogVersion");
        try jw.write(v);
    }
    if (settings.default_provider) |v| {
        try jw.objectField("defaultProvider");
        try jw.write(v);
    }
    if (settings.default_model) |v| {
        try jw.objectField("defaultModel");
        try jw.write(v);
    }
    if (settings.theme) |v| {
        try jw.objectField("theme");
        try jw.write(v);
    }
    if (settings.shell_path) |v| {
        try jw.objectField("shellPath");
        try jw.write(v);
    }
    if (settings.shell_command_prefix) |v| {
        try jw.objectField("shellCommandPrefix");
        try jw.write(v);
    }
    if (settings.session_dir) |v| {
        try jw.objectField("sessionDir");
        try jw.write(v);
    }

    // ── enum fields ──
    if (settings.default_thinking_level) |v| {
        try jw.objectField("defaultThinkingLevel");
        try jw.write(types.defaultThinkingLevelToString(v));
    }
    if (settings.transport) |v| {
        try jw.objectField("transport");
        try jw.write(types.transportToString(v));
    }
    if (settings.steering_mode) |v| {
        try jw.objectField("steeringMode");
        try jw.write(types.steeringModeToString(v));
    }
    if (settings.follow_up_mode) |v| {
        try jw.objectField("followUpMode");
        try jw.write(types.followUpModeToString(v));
    }
    if (settings.double_escape_action) |v| {
        try jw.objectField("doubleEscapeAction");
        try jw.write(types.doubleEscapeActionToString(v));
    }
    if (settings.tree_filter_mode) |v| {
        try jw.objectField("treeFilterMode");
        try jw.write(types.treeFilterModeToString(v));
    }

    // ── bool fields ──
    if (settings.hide_thinking_block) |v| {
        try jw.objectField("hideThinkingBlock");
        try jw.write(v);
    }
    if (settings.quiet_startup) |v| {
        try jw.objectField("quietStartup");
        try jw.write(v);
    }
    if (settings.collapse_changelog) |v| {
        try jw.objectField("collapseChangelog");
        try jw.write(v);
    }
    if (settings.enable_skill_commands) |v| {
        try jw.objectField("enableSkillCommands");
        try jw.write(v);
    }
    if (settings.show_hardware_cursor) |v| {
        try jw.objectField("showHardwareCursor");
        try jw.write(v);
    }

    // ── integer fields ──
    if (settings.editor_padding_x) |v| {
        try jw.objectField("editorPaddingX");
        try jw.write(v);
    }
    if (settings.autocomplete_max_visible) |v| {
        try jw.objectField("autocompleteMaxVisible");
        try jw.write(v);
    }

    // ── nested struct fields ──
    if (settings.compaction) |c| {
        try jw.objectField("compaction");
        try jw.beginObject();
        if (c.enabled) |v| {
            try jw.objectField("enabled");
            try jw.write(v);
        }
        if (c.reserve_tokens) |v| {
            try jw.objectField("reserveTokens");
            try jw.write(v);
        }
        if (c.keep_recent_tokens) |v| {
            try jw.objectField("keepRecentTokens");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.branch_summary) |s| {
        try jw.objectField("branchSummary");
        try jw.beginObject();
        if (s.reserve_tokens) |v| {
            try jw.objectField("reserveTokens");
            try jw.write(v);
        }
        if (s.skip_prompt) |v| {
            try jw.objectField("skipPrompt");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.retry) |r| {
        try jw.objectField("retry");
        try jw.beginObject();
        if (r.enabled) |v| {
            try jw.objectField("enabled");
            try jw.write(v);
        }
        if (r.max_retries) |v| {
            try jw.objectField("maxRetries");
            try jw.write(v);
        }
        if (r.base_delay_ms) |v| {
            try jw.objectField("baseDelayMs");
            try jw.write(v);
        }
        if (r.max_delay_ms) |v| {
            try jw.objectField("maxDelayMs");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.terminal) |t| {
        try jw.objectField("terminal");
        try jw.beginObject();
        if (t.show_images) |v| {
            try jw.objectField("showImages");
            try jw.write(v);
        }
        if (t.clear_on_shrink) |v| {
            try jw.objectField("clearOnShrink");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.images) |i| {
        try jw.objectField("images");
        try jw.beginObject();
        if (i.auto_resize) |v| {
            try jw.objectField("autoResize");
            try jw.write(v);
        }
        if (i.block_images) |v| {
            try jw.objectField("blockImages");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.thinking_budgets) |t| {
        try jw.objectField("thinkingBudgets");
        try jw.beginObject();
        if (t.minimal) |v| {
            try jw.objectField("minimal");
            try jw.write(v);
        }
        if (t.low) |v| {
            try jw.objectField("low");
            try jw.write(v);
        }
        if (t.medium) |v| {
            try jw.objectField("medium");
            try jw.write(v);
        }
        if (t.high) |v| {
            try jw.objectField("high");
            try jw.write(v);
        }
        try jw.endObject();
    }
    if (settings.markdown) |m| {
        try jw.objectField("markdown");
        try jw.beginObject();
        if (m.code_block_indent) |v| {
            try jw.objectField("codeBlockIndent");
            try jw.write(v);
        }
        try jw.endObject();
    }

    // ── string array fields ──
    if (settings.extensions) |arr| {
        try jw.objectField("extensions");
        try writeStringArray(jw, arr);
    }
    if (settings.skills) |arr| {
        try jw.objectField("skills");
        try writeStringArray(jw, arr);
    }
    if (settings.prompts) |arr| {
        try jw.objectField("prompts");
        try writeStringArray(jw, arr);
    }
    if (settings.themes_paths) |arr| {
        try jw.objectField("themes");
        try writeStringArray(jw, arr);
    }
    if (settings.enabled_models) |arr| {
        try jw.objectField("enabledModels");
        try writeStringArray(jw, arr);
    }
    if (settings.npm_command) |arr| {
        try jw.objectField("npmCommand");
        try writeStringArray(jw, arr);
    }

    // ── packages ──
    if (settings.packages) |pkgs| {
        try jw.objectField("packages");
        try jw.beginArray();
        for (pkgs) |pkg| {
            switch (pkg) {
                .string => |s| try jw.write(s),
                .filtered => |f| {
                    try jw.beginObject();
                    try jw.objectField("source");
                    try jw.write(f.source);
                    if (f.extensions) |arr| {
                        try jw.objectField("extensions");
                        try writeStringArray(jw, arr);
                    }
                    if (f.skills) |arr| {
                        try jw.objectField("skills");
                        try writeStringArray(jw, arr);
                    }
                    if (f.prompts) |arr| {
                        try jw.objectField("prompts");
                        try writeStringArray(jw, arr);
                    }
                    if (f.themes) |arr| {
                        try jw.objectField("themes");
                        try writeStringArray(jw, arr);
                    }
                    try jw.endObject();
                },
            }
        }
        try jw.endArray();
    }
}

fn writeStringArray(jw: *Stringify, arr: []const []const u8) !void {
    try jw.beginArray();
    for (arr) |s| try jw.write(s);
    try jw.endArray();
}

// ─── Apply Typed Field to Raw ───────────────────────────────────────

/// Apply a typed settings field value to a raw JSON object.
/// Used during merge-on-write: only modified fields get written back.
/// pi-mono: settings-manager.ts:451-479 (persistScopedSettings)
pub fn applyTypedFieldToRaw(
    allocator: std.mem.Allocator,
    object: *ObjectMap,
    field: types.SettingsField,
    settings: *const types.Settings,
) !void {
    const key = types.settingsFieldToJsonKey(field);
    switch (field) {
        .last_changelog_version => try putOptionalString(object, key, settings.last_changelog_version),
        .default_provider => try putOptionalString(object, key, settings.default_provider),
        .default_model => try putOptionalString(object, key, settings.default_model),
        .theme => try putOptionalString(object, key, settings.theme),
        .shell_path => try putOptionalString(object, key, settings.shell_path),
        .shell_command_prefix => try putOptionalString(object, key, settings.shell_command_prefix),
        .session_dir => try putOptionalString(object, key, settings.session_dir),

        .default_thinking_level => {
            if (settings.default_thinking_level) |v|
                try object.put(key, .{ .string = types.defaultThinkingLevelToString(v) });
        },
        .transport => {
            if (settings.transport) |v|
                try object.put(key, .{ .string = types.transportToString(v) });
        },
        .steering_mode => {
            if (settings.steering_mode) |v|
                try object.put(key, .{ .string = types.steeringModeToString(v) });
        },
        .follow_up_mode => {
            if (settings.follow_up_mode) |v|
                try object.put(key, .{ .string = types.followUpModeToString(v) });
        },
        .double_escape_action => {
            if (settings.double_escape_action) |v|
                try object.put(key, .{ .string = types.doubleEscapeActionToString(v) });
        },
        .tree_filter_mode => {
            if (settings.tree_filter_mode) |v|
                try object.put(key, .{ .string = types.treeFilterModeToString(v) });
        },

        .hide_thinking_block => try putOptionalBool(object, key, settings.hide_thinking_block),
        .quiet_startup => try putOptionalBool(object, key, settings.quiet_startup),
        .collapse_changelog => try putOptionalBool(object, key, settings.collapse_changelog),
        .enable_skill_commands => try putOptionalBool(object, key, settings.enable_skill_commands),
        .show_hardware_cursor => try putOptionalBool(object, key, settings.show_hardware_cursor),

        .editor_padding_x => try putOptionalInt(object, key, settings.editor_padding_x),
        .autocomplete_max_visible => try putOptionalInt(object, key, settings.autocomplete_max_visible),

        .compaction => {
            if (settings.compaction) |c| {
                var nested = ObjectMap.init(allocator);
                if (c.enabled) |v| try nested.put("enabled", .{ .bool = v });
                if (c.reserve_tokens) |v| try nested.put("reserveTokens", .{ .integer = v });
                if (c.keep_recent_tokens) |v| try nested.put("keepRecentTokens", .{ .integer = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .branch_summary => {
            if (settings.branch_summary) |s| {
                var nested = ObjectMap.init(allocator);
                if (s.reserve_tokens) |v| try nested.put("reserveTokens", .{ .integer = v });
                if (s.skip_prompt) |v| try nested.put("skipPrompt", .{ .bool = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .retry => {
            if (settings.retry) |r| {
                var nested = ObjectMap.init(allocator);
                if (r.enabled) |v| try nested.put("enabled", .{ .bool = v });
                if (r.max_retries) |v| try nested.put("maxRetries", .{ .integer = v });
                if (r.base_delay_ms) |v| try nested.put("baseDelayMs", .{ .integer = v });
                if (r.max_delay_ms) |v| try nested.put("maxDelayMs", .{ .integer = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .terminal => {
            if (settings.terminal) |t| {
                var nested = ObjectMap.init(allocator);
                if (t.show_images) |v| try nested.put("showImages", .{ .bool = v });
                if (t.clear_on_shrink) |v| try nested.put("clearOnShrink", .{ .bool = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .images => {
            if (settings.images) |i| {
                var nested = ObjectMap.init(allocator);
                if (i.auto_resize) |v| try nested.put("autoResize", .{ .bool = v });
                if (i.block_images) |v| try nested.put("blockImages", .{ .bool = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .thinking_budgets => {
            if (settings.thinking_budgets) |t| {
                var nested = ObjectMap.init(allocator);
                if (t.minimal) |v| try nested.put("minimal", .{ .integer = v });
                if (t.low) |v| try nested.put("low", .{ .integer = v });
                if (t.medium) |v| try nested.put("medium", .{ .integer = v });
                if (t.high) |v| try nested.put("high", .{ .integer = v });
                try object.put(key, .{ .object = nested });
            }
        },
        .markdown => {
            if (settings.markdown) |m| {
                var nested = ObjectMap.init(allocator);
                if (m.code_block_indent) |v| try nested.put("codeBlockIndent", .{ .string = v });
                try object.put(key, .{ .object = nested });
            }
        },

        .extensions => try putOptionalStringArray(allocator, object, key, settings.extensions),
        .skills => try putOptionalStringArray(allocator, object, key, settings.skills),
        .prompts => try putOptionalStringArray(allocator, object, key, settings.prompts),
        .themes_paths => try putOptionalStringArray(allocator, object, key, settings.themes_paths),
        .enabled_models => try putOptionalStringArray(allocator, object, key, settings.enabled_models),
        .npm_command => try putOptionalStringArray(allocator, object, key, settings.npm_command),

        .packages => {
            if (settings.packages) |pkgs| {
                var arr = try std.json.Array.initCapacity(allocator, pkgs.len);
                for (pkgs) |pkg| {
                    switch (pkg) {
                        .string => |s| try arr.append(.{ .string = s }),
                        .filtered => |f| {
                            var pkg_obj = ObjectMap.init(allocator);
                            try pkg_obj.put("source", .{ .string = f.source });
                            if (f.extensions) |exts| try pkg_obj.put("extensions", try buildJsonStringArray(allocator, exts));
                            if (f.skills) |sk| try pkg_obj.put("skills", try buildJsonStringArray(allocator, sk));
                            if (f.prompts) |pr| try pkg_obj.put("prompts", try buildJsonStringArray(allocator, pr));
                            if (f.themes) |th| try pkg_obj.put("themes", try buildJsonStringArray(allocator, th));
                            try arr.append(.{ .object = pkg_obj });
                        },
                    }
                }
                try object.put(key, .{ .array = arr });
            }
        },
    }
}

// ─── Apply Nested Field to Raw ──────────────────────────────────────

/// Apply a single nested field within a settings struct to the raw object.
/// e.g., field=compaction, nested_key="enabled" → sets raw["compaction"]["enabled"]
/// pi-mono: settings-manager.ts:464-471 (nested merge in persistScopedSettings)
pub fn applyTypedNestedFieldToRaw(
    allocator: std.mem.Allocator,
    object: *ObjectMap,
    field: types.SettingsField,
    nested_key: []const u8,
    settings: *const types.Settings,
) !void {
    const json_key = types.settingsFieldToJsonKey(field);

    var nested: ObjectMap = if (object.get(json_key)) |v| blk: {
        if (v == .object) break :blk v.object;
        break :blk ObjectMap.init(allocator);
    } else ObjectMap.init(allocator);

    switch (field) {
        .compaction => {
            if (settings.compaction) |c| {
                if (std.mem.eql(u8, nested_key, "enabled")) {
                    if (c.enabled) |v| try nested.put("enabled", .{ .bool = v });
                } else if (std.mem.eql(u8, nested_key, "reserveTokens")) {
                    if (c.reserve_tokens) |v| try nested.put("reserveTokens", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "keepRecentTokens")) {
                    if (c.keep_recent_tokens) |v| try nested.put("keepRecentTokens", .{ .integer = v });
                }
            }
        },
        .branch_summary => {
            if (settings.branch_summary) |s| {
                if (std.mem.eql(u8, nested_key, "reserveTokens")) {
                    if (s.reserve_tokens) |v| try nested.put("reserveTokens", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "skipPrompt")) {
                    if (s.skip_prompt) |v| try nested.put("skipPrompt", .{ .bool = v });
                }
            }
        },
        .retry => {
            if (settings.retry) |r| {
                if (std.mem.eql(u8, nested_key, "enabled")) {
                    if (r.enabled) |v| try nested.put("enabled", .{ .bool = v });
                } else if (std.mem.eql(u8, nested_key, "maxRetries")) {
                    if (r.max_retries) |v| try nested.put("maxRetries", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "baseDelayMs")) {
                    if (r.base_delay_ms) |v| try nested.put("baseDelayMs", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "maxDelayMs")) {
                    if (r.max_delay_ms) |v| try nested.put("maxDelayMs", .{ .integer = v });
                }
            }
        },
        .terminal => {
            if (settings.terminal) |t| {
                if (std.mem.eql(u8, nested_key, "showImages")) {
                    if (t.show_images) |v| try nested.put("showImages", .{ .bool = v });
                } else if (std.mem.eql(u8, nested_key, "clearOnShrink")) {
                    if (t.clear_on_shrink) |v| try nested.put("clearOnShrink", .{ .bool = v });
                }
            }
        },
        .images => {
            if (settings.images) |i| {
                if (std.mem.eql(u8, nested_key, "autoResize")) {
                    if (i.auto_resize) |v| try nested.put("autoResize", .{ .bool = v });
                } else if (std.mem.eql(u8, nested_key, "blockImages")) {
                    if (i.block_images) |v| try nested.put("blockImages", .{ .bool = v });
                }
            }
        },
        .thinking_budgets => {
            if (settings.thinking_budgets) |t| {
                if (std.mem.eql(u8, nested_key, "minimal")) {
                    if (t.minimal) |v| try nested.put("minimal", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "low")) {
                    if (t.low) |v| try nested.put("low", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "medium")) {
                    if (t.medium) |v| try nested.put("medium", .{ .integer = v });
                } else if (std.mem.eql(u8, nested_key, "high")) {
                    if (t.high) |v| try nested.put("high", .{ .integer = v });
                }
            }
        },
        .markdown => {
            if (settings.markdown) |m| {
                if (std.mem.eql(u8, nested_key, "codeBlockIndent")) {
                    if (m.code_block_indent) |v| try nested.put("codeBlockIndent", .{ .string = v });
                }
            }
        },
        else => {},
    }

    try object.put(json_key, .{ .object = nested });
}

// ─── Helpers ────────────────────────────────────────────────────────

fn putOptionalString(object: *ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |v| try object.put(key, .{ .string = v });
}

fn putOptionalBool(object: *ObjectMap, key: []const u8, value: ?bool) !void {
    if (value) |v| try object.put(key, .{ .bool = v });
}

fn putOptionalInt(object: *ObjectMap, key: []const u8, value: ?i64) !void {
    if (value) |v| try object.put(key, .{ .integer = v });
}

fn putOptionalStringArray(allocator: std.mem.Allocator, object: *ObjectMap, key: []const u8, value: ?[]const []const u8) !void {
    if (value) |arr| {
        try object.put(key, try buildJsonStringArray(allocator, arr));
    }
}

fn buildJsonStringArray(allocator: std.mem.Allocator, arr: []const []const u8) !Value {
    var json_arr = try std.json.Array.initCapacity(allocator, arr.len);
    for (arr) |s| try json_arr.append(.{ .string = s });
    return Value{ .array = json_arr };
}

// ─── Tests ──────────────────────────────────────────────────────────

test "parseSettingsJson round-trips all field categories" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input =
        \\{
        \\  "defaultProvider": "anthropic",
        \\  "defaultModel": "claude-4",
        \\  "defaultThinkingLevel": "high",
        \\  "transport": "sse",
        \\  "hideThinkingBlock": true,
        \\  "editorPaddingX": 4,
        \\  "compaction": {
        \\    "enabled": true,
        \\    "reserveTokens": 8000,
        \\    "keepRecentTokens": 4000
        \\  },
        \\  "extensions": ["ext-a", "ext-b"],
        \\  "steeringMode": "one-at-a-time",
        \\  "followUpMode": "all"
        \\}
    ;

    var result = try parseSettingsJson(allocator, input);
    defer result.deinit();

    const s = result.settings;
    try testing.expectEqualStrings("anthropic", s.default_provider.?);
    try testing.expectEqualStrings("claude-4", s.default_model.?);
    try testing.expectEqual(types.DefaultThinkingLevel.high, s.default_thinking_level.?);
    try testing.expectEqual(types.TransportSetting.sse, s.transport.?);
    try testing.expectEqual(true, s.hide_thinking_block.?);
    try testing.expectEqual(@as(i64, 4), s.editor_padding_x.?);
    try testing.expectEqual(true, s.compaction.?.enabled.?);
    try testing.expectEqual(@as(i64, 8000), s.compaction.?.reserve_tokens.?);
    try testing.expectEqual(@as(i64, 4000), s.compaction.?.keep_recent_tokens.?);
    try testing.expectEqual(@as(usize, 2), s.extensions.?.len);
    try testing.expectEqualStrings("ext-a", s.extensions.?[0]);
    try testing.expectEqualStrings("ext-b", s.extensions.?[1]);
    try testing.expectEqual(types.SteeringMode.one_at_a_time, s.steering_mode.?);
    try testing.expectEqual(types.FollowUpMode.all, s.follow_up_mode.?);

    const json_out = try serializeSettings(allocator, &s);
    defer allocator.free(json_out);

    var rt = try parseSettingsJson(allocator, json_out);
    defer rt.deinit();

    try testing.expectEqualStrings("anthropic", rt.settings.default_provider.?);
    try testing.expectEqual(true, rt.settings.compaction.?.enabled.?);
    try testing.expectEqual(@as(usize, 2), rt.settings.extensions.?.len);
}

test "deepMergeSettings merges nested structs and overrides simple fields" {
    const base: types.Settings = .{
        .default_provider = "anthropic",
        .default_model = "claude-3",
        .compaction = .{ .enabled = true, .reserve_tokens = 8000 },
        .extensions = &.{ "ext-a", "ext-b" },
    };
    const overrides: types.Settings = .{
        .default_model = "claude-4",
        .compaction = .{ .reserve_tokens = 16000 },
        .extensions = &.{"ext-c"},
        .hide_thinking_block = true,
    };
    const merged = deepMergeSettings(base, overrides);

    const testing = std.testing;
    try testing.expectEqualStrings("anthropic", merged.default_provider.?);
    try testing.expectEqualStrings("claude-4", merged.default_model.?);
    try testing.expectEqual(true, merged.compaction.?.enabled.?);
    try testing.expectEqual(@as(i64, 16000), merged.compaction.?.reserve_tokens.?);
    try testing.expectEqual(@as(usize, 1), merged.extensions.?.len);
    try testing.expectEqualStrings("ext-c", merged.extensions.?[0]);
    try testing.expectEqual(true, merged.hide_thinking_block.?);
}

test "applyTypedFieldToRaw writes nested struct to raw object" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const settings: types.Settings = .{
        .compaction = .{ .enabled = true, .reserve_tokens = 8000 },
    };

    var raw = ObjectMap.init(allocator);

    try applyTypedFieldToRaw(allocator, &raw, .compaction, &settings);

    const compaction_val = raw.get("compaction").?;
    try testing.expect(compaction_val == .object);
    const nested = compaction_val.object;
    try testing.expectEqual(true, nested.get("enabled").?.bool);
    try testing.expectEqual(@as(i64, 8000), nested.get("reserveTokens").?.integer);
}
