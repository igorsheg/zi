const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const json_write = @import("../../json/write.zig");
const storage_mod = @import("storage.zig");
const file_storage = @import("file_storage.zig");

const log = std.log.scoped(.settings_manager);

/// pi-mono: settings-manager.ts:226-958
pub const SettingsManager = struct {
    allocator: std.mem.Allocator,
    storage: storage_mod.SettingsStorage,
    owns_storage: bool,

    global_settings: types.Settings,
    project_settings: types.Settings,
    settings: types.Settings,

    global_parse: ?json.ParseResult = null,
    project_parse: ?json.ParseResult = null,

    modified_fields: std.EnumSet(types.SettingsField),
    modified_project_fields: std.EnumSet(types.SettingsField),
    modified_nested: std.AutoHashMap(types.SettingsField, std.StringHashMap(void)),
    modified_project_nested: std.AutoHashMap(types.SettingsField, std.StringHashMap(void)),

    global_load_error: bool = false,
    project_load_error: bool = false,
    errors: std.ArrayListUnmanaged(types.SettingsError),

    // ── constructors ────────────────────────────────────────────────────

    /// File-backed settings manager.
    /// pi-mono: settings-manager.ts:232-240
    pub fn create(allocator: std.mem.Allocator, cwd: []const u8, agent_dir_override: ?[]const u8) !SettingsManager {
        return createWithIo(allocator, std.Options.debug_io, cwd, agent_dir_override);
    }

    pub fn createWithIo(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, agent_dir_override: ?[]const u8) !SettingsManager {
        var fs = try allocator.create(file_storage.FileSettingsStorage);
        fs.* = try file_storage.FileSettingsStorage.initWithIo(allocator, io, cwd, agent_dir_override);
        return fromStorageInternal(allocator, fs.asStorage(), true);
    }

    /// From any storage backend.
    /// pi-mono: settings-manager.ts:242-244
    pub fn fromStorage(allocator: std.mem.Allocator, storage: storage_mod.SettingsStorage) SettingsManager {
        return fromStorageInternal(allocator, storage, false);
    }

    /// In-memory for tests. Optionally pre-populate with initial settings.
    /// pi-mono: settings-manager.ts:246-257
    pub fn inMemory(allocator: std.mem.Allocator, initial: ?types.Settings) !SettingsManager {
        var mem = try allocator.create(storage_mod.InMemorySettingsStorage);
        mem.* = storage_mod.InMemorySettingsStorage.init(allocator);
        if (initial) |s| {
            mem.global = try json_write.toOwnedSlice(allocator, &s, json.writeSettings);
        }
        return fromStorageInternal(allocator, mem.asStorage(), true);
    }

    fn fromStorageInternal(allocator: std.mem.Allocator, storage: storage_mod.SettingsStorage, owns: bool) SettingsManager {
        var mgr = SettingsManager{
            .allocator = allocator,
            .storage = storage,
            .owns_storage = owns,
            .global_settings = .{},
            .project_settings = .{},
            .settings = .{},
            .modified_fields = std.EnumSet(types.SettingsField).initEmpty(),
            .modified_project_fields = std.EnumSet(types.SettingsField).initEmpty(),
            .modified_nested = std.AutoHashMap(types.SettingsField, std.StringHashMap(void)).init(allocator),
            .modified_project_nested = std.AutoHashMap(types.SettingsField, std.StringHashMap(void)).init(allocator),
            .errors = .empty,
        };
        mgr.loadScope(.global);
        mgr.loadScope(.project);
        mgr.settings = json.deepMergeSettings(mgr.global_settings, mgr.project_settings);
        return mgr;
    }

    pub fn deinit(self: *SettingsManager) void {
        if (self.global_parse) |*p| p.deinit();
        if (self.project_parse) |*p| p.deinit();
        self.global_parse = null;
        self.project_parse = null;

        var nested_it = self.modified_nested.valueIterator();
        while (nested_it.next()) |v| v.deinit();
        self.modified_nested.deinit();

        var pnested_it = self.modified_project_nested.valueIterator();
        while (pnested_it.next()) |v| v.deinit();
        self.modified_project_nested.deinit();

        self.errors.deinit(self.allocator);

        if (self.owns_storage) self.storage.deinit();
    }

    // ── loading ─────────────────────────────────────────────────────────

    fn loadScope(self: *SettingsManager, scope: types.SettingsScope) void {
        var capture: ReadCapture = .{ .allocator = self.allocator };
        self.storage.withLock(scope, @ptrCast(&capture), ReadCapture.callback);
        defer if (capture.content) |c| self.allocator.free(c);
        if (capture.content) |content| {
            const result = json.parseSettingsJson(self.allocator, content) catch {
                switch (scope) {
                    .global => self.global_load_error = true,
                    .project => self.project_load_error = true,
                }
                self.errors.append(self.allocator, .{
                    .scope = scope,
                    .message = "failed to parse settings JSON",
                }) catch {};
                return;
            };
            switch (scope) {
                .global => {
                    if (self.global_parse) |*old| old.deinit();
                    self.global_parse = result;
                    self.global_settings = result.settings;
                    self.global_load_error = false;
                },
                .project => {
                    if (self.project_parse) |*old| old.deinit();
                    self.project_parse = result;
                    self.project_settings = result.settings;
                    self.project_load_error = false;
                },
            }
        } else {
            switch (scope) {
                .global => {
                    if (self.global_parse) |*old| old.deinit();
                    self.global_parse = null;
                    self.global_settings = .{};
                    self.global_load_error = false;
                },
                .project => {
                    if (self.project_parse) |*old| old.deinit();
                    self.project_parse = null;
                    self.project_settings = .{};
                    self.project_load_error = false;
                },
            }
        }
    }

    pub fn reload(self: *SettingsManager) void {
        self.loadScope(.global);
        self.loadScope(.project);
        self.modified_fields = std.EnumSet(types.SettingsField).initEmpty();
        self.modified_project_fields = std.EnumSet(types.SettingsField).initEmpty();
        clearNestedMap(self.allocator, &self.modified_nested);
        clearNestedMap(self.allocator, &self.modified_project_nested);
        self.settings = json.deepMergeSettings(self.global_settings, self.project_settings);
    }

    // ── dirty tracking ──────────────────────────────────────────────────

    fn markModified(self: *SettingsManager, field: types.SettingsField, nested_key: ?[]const u8) void {
        self.modified_fields.insert(field);
        if (nested_key) |nk| {
            var gop = self.modified_nested.getOrPut(field) catch return;
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            gop.value_ptr.put(nk, {}) catch {};
        }
    }

    fn markProjectModified(self: *SettingsManager, field: types.SettingsField, nested_key: ?[]const u8) void {
        self.modified_project_fields.insert(field);
        if (nested_key) |nk| {
            var gop = self.modified_project_nested.getOrPut(field) catch return;
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            gop.value_ptr.put(nk, {}) catch {};
        }
    }

    // ── persistence ─────────────────────────────────────────────────────

    fn save(self: *SettingsManager) void {
        self.settings = json.deepMergeSettings(self.global_settings, self.project_settings);
        if (self.global_load_error) return;
        self.persistScopedSettings(.global);
    }

    fn saveProjectSettings(self: *SettingsManager) void {
        self.settings = json.deepMergeSettings(self.global_settings, self.project_settings);
        if (self.project_load_error) return;
        self.persistScopedSettings(.project);
    }

    fn persistScopedSettings(self: *SettingsManager, scope: types.SettingsScope) void {
        // Step 1: read current file content (duped by ReadCapture, we must free)
        var capture: ReadCapture = .{ .allocator = self.allocator };
        self.storage.withLock(scope, @ptrCast(&capture), ReadCapture.callback);

        // Step 2: merge modified fields into raw object
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Free the captured content after arena takes ownership of its parse
        defer if (capture.content) |c| self.allocator.free(c);

        var raw_obj: std.json.ObjectMap = if (capture.content) |c| blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, a, c, .{}) catch
                break :blk .{};
            if (parsed.value == .object) break :blk parsed.value.object else break :blk .{};
        } else .{};

        const modified = if (scope == .global) &self.modified_fields else &self.modified_project_fields;
        const nested_modified = if (scope == .global) &self.modified_nested else &self.modified_project_nested;
        const settings_ref = if (scope == .global) &self.global_settings else &self.project_settings;

        var field_it = modified.iterator();
        while (field_it.next()) |field| {
            if (nested_modified.get(field)) |nested_keys| {
                var nk_it = nested_keys.keyIterator();
                while (nk_it.next()) |nk| {
                    json.applyTypedNestedFieldToRaw(a, &raw_obj, field, nk.*, settings_ref) catch continue;
                }
            } else {
                json.applyTypedFieldToRaw(a, &raw_obj, field, settings_ref) catch continue;
            }
        }

        // Step 3: serialize and write back
        const new_json = json.serializeSettingsObject(a, raw_obj) catch return;
        var write_ctx: WriteCapture = .{ .content = new_json };
        self.storage.withLock(scope, @ptrCast(&write_ctx), WriteCapture.callback);

        // Step 4: clear dirty state
        if (scope == .global) {
            self.modified_fields = std.EnumSet(types.SettingsField).initEmpty();
            clearNestedMap(self.allocator, &self.modified_nested);
        } else {
            self.modified_project_fields = std.EnumSet(types.SettingsField).initEmpty();
            clearNestedMap(self.allocator, &self.modified_project_nested);
        }
    }

    // ── simple string getters/setters ───────────────────────────────────

    pub fn getLastChangelogVersion(self: *const SettingsManager) ?[]const u8 {
        return self.settings.last_changelog_version;
    }

    pub fn setLastChangelogVersion(self: *SettingsManager, version: []const u8) void {
        self.global_settings.last_changelog_version = version;
        self.markModified(.last_changelog_version, null);
        self.save();
    }

    pub fn getSessionDir(self: *const SettingsManager) ?[]const u8 {
        return self.settings.session_dir;
    }

    pub fn getModels(self: *const SettingsManager) ?[]const types.CustomModel {
        return self.settings.models;
    }

    pub fn getDefaultProvider(self: *const SettingsManager) ?[]const u8 {
        return self.settings.default_provider;
    }

    pub fn setDefaultProvider(self: *SettingsManager, provider: []const u8) void {
        self.global_settings.default_provider = provider;
        self.markModified(.default_provider, null);
        self.save();
    }

    pub fn getDefaultModel(self: *const SettingsManager) ?[]const u8 {
        return self.settings.default_model;
    }

    pub fn setDefaultModel(self: *SettingsManager, model: []const u8) void {
        self.global_settings.default_model = model;
        self.markModified(.default_model, null);
        self.save();
    }

    pub fn setDefaultModelAndProvider(self: *SettingsManager, provider: []const u8, model: []const u8) void {
        self.global_settings.default_provider = provider;
        self.global_settings.default_model = model;
        self.markModified(.default_provider, null);
        self.markModified(.default_model, null);
        self.save();
    }

    pub fn getTheme(self: *const SettingsManager) ?[]const u8 {
        return self.settings.theme;
    }

    pub fn setTheme(self: *SettingsManager, theme: []const u8) void {
        self.global_settings.theme = theme;
        self.markModified(.theme, null);
        self.save();
    }

    pub fn getShellPath(self: *const SettingsManager) ?[]const u8 {
        return self.settings.shell_path;
    }

    pub fn setShellPath(self: *SettingsManager, path: []const u8) void {
        self.global_settings.shell_path = path;
        self.markModified(.shell_path, null);
        self.save();
    }

    pub fn getShellCommandPrefix(self: *const SettingsManager) ?[]const u8 {
        return self.settings.shell_command_prefix;
    }

    pub fn setShellCommandPrefix(self: *SettingsManager, prefix: []const u8) void {
        self.global_settings.shell_command_prefix = prefix;
        self.markModified(.shell_command_prefix, null);
        self.save();
    }

    // ── enum getters/setters ────────────────────────────────────────────

    pub fn getSteeringMode(self: *const SettingsManager) types.SteeringMode {
        return self.settings.steering_mode orelse .one_at_a_time;
    }

    pub fn setSteeringMode(self: *SettingsManager, mode: types.SteeringMode) void {
        self.global_settings.steering_mode = mode;
        self.markModified(.steering_mode, null);
        self.save();
    }

    pub fn getFollowUpMode(self: *const SettingsManager) types.FollowUpMode {
        return self.settings.follow_up_mode orelse .one_at_a_time;
    }

    pub fn setFollowUpMode(self: *SettingsManager, mode: types.FollowUpMode) void {
        self.global_settings.follow_up_mode = mode;
        self.markModified(.follow_up_mode, null);
        self.save();
    }

    pub fn getDefaultThinkingLevel(self: *const SettingsManager) ?types.DefaultThinkingLevel {
        return self.settings.default_thinking_level;
    }

    pub fn setDefaultThinkingLevel(self: *SettingsManager, level: ?types.DefaultThinkingLevel) void {
        self.global_settings.default_thinking_level = level;
        self.markModified(.default_thinking_level, null);
        self.save();
    }

    pub fn getTransport(self: *const SettingsManager) types.TransportSetting {
        return self.settings.transport orelse .sse;
    }

    pub fn setTransport(self: *SettingsManager, transport: types.TransportSetting) void {
        self.global_settings.transport = transport;
        self.markModified(.transport, null);
        self.save();
    }

    pub fn getDoubleEscapeAction(self: *const SettingsManager) types.DoubleEscapeAction {
        return self.settings.double_escape_action orelse .tree;
    }

    pub fn setDoubleEscapeAction(self: *SettingsManager, action: types.DoubleEscapeAction) void {
        self.global_settings.double_escape_action = action;
        self.markModified(.double_escape_action, null);
        self.save();
    }

    pub fn getTreeFilterMode(self: *const SettingsManager) types.TreeFilterMode {
        return self.settings.tree_filter_mode orelse .default;
    }

    pub fn setTreeFilterMode(self: *SettingsManager, mode: types.TreeFilterMode) void {
        self.global_settings.tree_filter_mode = mode;
        self.markModified(.tree_filter_mode, null);
        self.save();
    }

    // ── simple bool getters/setters ─────────────────────────────────────

    pub fn getHideThinkingBlock(self: *const SettingsManager) bool {
        return self.settings.hide_thinking_block orelse false;
    }

    pub fn setHideThinkingBlock(self: *SettingsManager, hide: bool) void {
        self.global_settings.hide_thinking_block = hide;
        self.markModified(.hide_thinking_block, null);
        self.save();
    }

    pub fn getQuietStartup(self: *const SettingsManager) bool {
        return self.settings.quiet_startup orelse false;
    }

    pub fn setQuietStartup(self: *SettingsManager, quiet: bool) void {
        self.global_settings.quiet_startup = quiet;
        self.markModified(.quiet_startup, null);
        self.save();
    }

    pub fn getCollapseChangelog(self: *const SettingsManager) bool {
        return self.settings.collapse_changelog orelse false;
    }

    pub fn setCollapseChangelog(self: *SettingsManager, collapse: bool) void {
        self.global_settings.collapse_changelog = collapse;
        self.markModified(.collapse_changelog, null);
        self.save();
    }

    pub fn getEnableSkillCommands(self: *const SettingsManager) bool {
        return self.settings.enable_skill_commands orelse true;
    }

    pub fn setEnableSkillCommands(self: *SettingsManager, enabled: bool) void {
        self.global_settings.enable_skill_commands = enabled;
        self.markModified(.enable_skill_commands, null);
        self.save();
    }

    // ── nested getters/setters ──────────────────────────────────────────

    pub fn getCompactionEnabled(self: *const SettingsManager) bool {
        if (self.settings.compaction) |c| {
            if (c.enabled) |v| return v;
        }
        return true;
    }

    pub fn setCompactionEnabled(self: *SettingsManager, enabled: bool) void {
        if (self.global_settings.compaction == null) self.global_settings.compaction = .{};
        self.global_settings.compaction.?.enabled = enabled;
        self.markModified(.compaction, "enabled");
        self.save();
    }

    pub fn getCompactionReserveTokens(self: *const SettingsManager) i64 {
        if (self.settings.compaction) |c| {
            if (c.reserve_tokens) |v| return v;
        }
        return 16384;
    }

    pub fn getCompactionKeepRecentTokens(self: *const SettingsManager) i64 {
        if (self.settings.compaction) |c| {
            if (c.keep_recent_tokens) |v| return v;
        }
        return 20000;
    }

    pub fn getCompactionSettings(self: *const SettingsManager) types.ResolvedCompactionSettings {
        return .{
            .enabled = self.getCompactionEnabled(),
            .reserve_tokens = self.getCompactionReserveTokens(),
            .keep_recent_tokens = self.getCompactionKeepRecentTokens(),
        };
    }

    pub fn getBranchSummarySettings(self: *const SettingsManager) types.ResolvedBranchSummarySettings {
        const bs = self.settings.branch_summary;
        return .{
            .reserve_tokens = if (bs) |s| s.reserve_tokens orelse 16384 else 16384,
            .skip_prompt = if (bs) |s| s.skip_prompt orelse false else false,
        };
    }

    pub fn getBranchSummarySkipPrompt(self: *const SettingsManager) bool {
        if (self.settings.branch_summary) |s| {
            if (s.skip_prompt) |v| return v;
        }
        return false;
    }

    pub fn getRetryEnabled(self: *const SettingsManager) bool {
        if (self.settings.retry) |r| {
            if (r.enabled) |v| return v;
        }
        return true;
    }

    pub fn setRetryEnabled(self: *SettingsManager, enabled: bool) void {
        if (self.global_settings.retry == null) self.global_settings.retry = .{};
        self.global_settings.retry.?.enabled = enabled;
        self.markModified(.retry, "enabled");
        self.save();
    }

    pub fn getRetrySettings(self: *const SettingsManager) types.ResolvedRetrySettings {
        const r = self.settings.retry;
        return .{
            .enabled = if (r) |s| s.enabled orelse true else true,
            .max_retries = if (r) |s| s.max_retries orelse 3 else 3,
            .base_delay_ms = if (r) |s| s.base_delay_ms orelse 2000 else 2000,
            .max_delay_ms = if (r) |s| s.max_delay_ms orelse 30000 else 30000,
        };
    }

    pub fn getShowImages(self: *const SettingsManager) bool {
        if (self.settings.terminal) |t| {
            if (t.show_images) |v| return v;
        }
        return true;
    }

    pub fn setShowImages(self: *SettingsManager, show: bool) void {
        if (self.global_settings.terminal == null) self.global_settings.terminal = .{};
        self.global_settings.terminal.?.show_images = show;
        self.markModified(.terminal, "showImages");
        self.save();
    }

    pub fn getClearOnShrink(self: *const SettingsManager) bool {
        if (self.settings.terminal) |t| {
            if (t.clear_on_shrink) |v| return v;
        }
        if (@import("env").get("PI_CLEAR_ON_SHRINK")) |v| {
            return std.mem.eql(u8, v, "1");
        }
        return false;
    }

    pub fn setClearOnShrink(self: *SettingsManager, clear: bool) void {
        if (self.global_settings.terminal == null) self.global_settings.terminal = .{};
        self.global_settings.terminal.?.clear_on_shrink = clear;
        self.markModified(.terminal, "clearOnShrink");
        self.save();
    }

    pub fn getImageAutoResize(self: *const SettingsManager) bool {
        if (self.settings.images) |i| {
            if (i.auto_resize) |v| return v;
        }
        return true;
    }

    pub fn setImageAutoResize(self: *SettingsManager, auto_resize: bool) void {
        if (self.global_settings.images == null) self.global_settings.images = .{};
        self.global_settings.images.?.auto_resize = auto_resize;
        self.markModified(.images, "autoResize");
        self.save();
    }

    pub fn getBlockImages(self: *const SettingsManager) bool {
        if (self.settings.images) |i| {
            if (i.block_images) |v| return v;
        }
        return false;
    }

    pub fn setBlockImages(self: *SettingsManager, block: bool) void {
        if (self.global_settings.images == null) self.global_settings.images = .{};
        self.global_settings.images.?.block_images = block;
        self.markModified(.images, "blockImages");
        self.save();
    }

    // ── clamped setters ─────────────────────────────────────────────────

    pub fn getEditorPaddingX(self: *const SettingsManager) i64 {
        return self.settings.editor_padding_x orelse 0;
    }

    pub fn setEditorPaddingX(self: *SettingsManager, padding: i64) void {
        self.global_settings.editor_padding_x = @max(0, @min(3, padding));
        self.markModified(.editor_padding_x, null);
        self.save();
    }

    pub fn getAutocompleteMaxVisible(self: *const SettingsManager) i64 {
        return self.settings.autocomplete_max_visible orelse 5;
    }

    pub fn setAutocompleteMaxVisible(self: *SettingsManager, max_visible: i64) void {
        self.global_settings.autocomplete_max_visible = @max(3, @min(20, max_visible));
        self.markModified(.autocomplete_max_visible, null);
        self.save();
    }

    // ── env-fallback getters/setters ────────────────────────────────────

    pub fn getShowHardwareCursor(self: *const SettingsManager) bool {
        if (self.settings.show_hardware_cursor) |v| return v;
        if (@import("env").get("PI_HARDWARE_CURSOR")) |v| {
            return std.mem.eql(u8, v, "1");
        }
        return false;
    }

    pub fn setShowHardwareCursor(self: *SettingsManager, show: bool) void {
        self.global_settings.show_hardware_cursor = show;
        self.markModified(.show_hardware_cursor, null);
        self.save();
    }

    // ── other getters ───────────────────────────────────────────────────

    pub fn getThinkingBudgets(self: *const SettingsManager) ?types.ThinkingBudgetsSettings {
        return self.settings.thinking_budgets;
    }

    pub fn getCodeBlockIndent(self: *const SettingsManager) []const u8 {
        if (self.settings.markdown) |m| {
            if (m.code_block_indent) |v| return v;
        }
        return "  ";
    }

    pub fn getNpmCommand(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.npm_command;
    }

    pub fn setNpmCommand(self: *SettingsManager, cmd: []const []const u8) void {
        self.global_settings.npm_command = cmd;
        self.markModified(.npm_command, null);
        self.save();
    }

    pub fn getEnabledModels(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.enabled_models;
    }

    pub fn setEnabledModels(self: *SettingsManager, models: []const []const u8) void {
        self.global_settings.enabled_models = models;
        self.markModified(.enabled_models, null);
        self.save();
    }

    // ── array fields with dual-scope setters ────────────────────────────

    pub fn getPackages(self: *const SettingsManager) ?[]const types.PackageSource {
        return self.settings.packages;
    }

    pub fn getGlobalPackages(self: *const SettingsManager) ?[]const types.PackageSource {
        return self.global_settings.packages;
    }

    pub fn getProjectPackages(self: *const SettingsManager) ?[]const types.PackageSource {
        return self.project_settings.packages;
    }

    pub fn setPackages(self: *SettingsManager, packages: []const types.PackageSource) void {
        self.global_settings.packages = packages;
        self.markModified(.packages, null);
        self.save();
    }

    pub fn setProjectPackages(self: *SettingsManager, packages: []const types.PackageSource) void {
        self.project_settings.packages = packages;
        self.markProjectModified(.packages, null);
        self.saveProjectSettings();
    }

    pub fn getExtensionPaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.extensions;
    }

    pub fn getGlobalExtensionPaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.global_settings.extensions;
    }

    pub fn getProjectExtensionPaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.project_settings.extensions;
    }

    pub fn setExtensionPaths(self: *SettingsManager, paths: []const []const u8) void {
        self.global_settings.extensions = paths;
        self.markModified(.extensions, null);
        self.save();
    }

    pub fn setProjectExtensionPaths(self: *SettingsManager, paths: []const []const u8) void {
        self.project_settings.extensions = paths;
        self.markProjectModified(.extensions, null);
        self.saveProjectSettings();
    }

    pub fn getSkillPaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.skills;
    }

    pub fn setSkillPaths(self: *SettingsManager, paths: []const []const u8) void {
        self.global_settings.skills = paths;
        self.markModified(.skills, null);
        self.save();
    }

    pub fn setProjectSkillPaths(self: *SettingsManager, paths: []const []const u8) void {
        self.project_settings.skills = paths;
        self.markProjectModified(.skills, null);
        self.saveProjectSettings();
    }

    pub fn getPromptTemplatePaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.prompts;
    }

    pub fn setPromptTemplatePaths(self: *SettingsManager, paths: []const []const u8) void {
        self.global_settings.prompts = paths;
        self.markModified(.prompts, null);
        self.save();
    }

    pub fn setProjectPromptTemplatePaths(self: *SettingsManager, paths: []const []const u8) void {
        self.project_settings.prompts = paths;
        self.markProjectModified(.prompts, null);
        self.saveProjectSettings();
    }

    pub fn getThemePaths(self: *const SettingsManager) ?[]const []const u8 {
        return self.settings.themes_paths;
    }

    pub fn setThemePaths(self: *SettingsManager, paths: []const []const u8) void {
        self.global_settings.themes_paths = paths;
        self.markModified(.themes_paths, null);
        self.save();
    }

    pub fn setProjectThemePaths(self: *SettingsManager, paths: []const []const u8) void {
        self.project_settings.themes_paths = paths;
        self.markProjectModified(.themes_paths, null);
        self.saveProjectSettings();
    }

    // ── utility ─────────────────────────────────────────────────────────

    /// Apply overrides on top of current effective settings (non-persisted).
    /// pi-mono: settings-manager.ts:270-272
    pub fn applyOverrides(self: *SettingsManager, overrides: types.Settings) void {
        self.settings = json.deepMergeSettings(self.settings, overrides);
    }

    /// No-op in zig (all writes are synchronous).
    /// pi-mono: settings-manager.ts:954-958
    pub fn flush(_: *SettingsManager) void {}

    /// Drain accumulated errors, returning the list and resetting it.
    /// Caller does NOT own the returned slice memory — it points into the
    /// ArrayList's backing buffer and is invalidated on next mutation.
    pub fn drainErrors(self: *SettingsManager) []const types.SettingsError {
        const items = self.errors.items;
        self.errors = .empty;
        return items;
    }
};

// ── callback helpers for storage vtable ──────────────────────────────

const ReadCapture = struct {
    content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    fn callback(ctx: *anyopaque, current: ?[]const u8) ?[]const u8 {
        const self: *ReadCapture = @ptrCast(@alignCast(ctx));
        // Dupe the content — file storage frees `current` after callback returns
        self.content = if (current) |c| self.allocator.dupe(u8, c) catch null else null;
        return null;
    }
};

const WriteCapture = struct {
    content: []const u8,

    fn callback(ctx: *anyopaque, _: ?[]const u8) ?[]const u8 {
        const self: *WriteCapture = @ptrCast(@alignCast(ctx));
        return self.content;
    }
};

// ── internal helpers ────────────────────────────────────────────────

fn clearNestedMap(_: std.mem.Allocator, map: *std.AutoHashMap(types.SettingsField, std.StringHashMap(void))) void {
    var it = map.valueIterator();
    while (it.next()) |v| v.deinit();
    map.clearRetainingCapacity();
}

// ── tests ───────────────────────────────────────────────────────────

test "set persists and reload recovers the value" {
    const allocator = std.testing.allocator;

    var mgr = try SettingsManager.inMemory(allocator, null);
    defer mgr.deinit();

    try std.testing.expect(mgr.getDefaultModel() == null);

    mgr.setDefaultModel("claude-sonnet-4");
    try std.testing.expectEqualStrings("claude-sonnet-4", mgr.getDefaultModel().?);

    mgr.reload();
    try std.testing.expectEqualStrings("claude-sonnet-4", mgr.getDefaultModel().?);
}

test "setDefaultModelAndProvider writes provider and model in matching fields" {
    const allocator = std.testing.allocator;

    var mgr = try SettingsManager.inMemory(allocator, null);
    defer mgr.deinit();

    mgr.setDefaultModelAndProvider("anthropic", "claude-sonnet-4");

    try std.testing.expectEqualStrings("anthropic", mgr.getDefaultProvider().?);
    try std.testing.expectEqualStrings("claude-sonnet-4", mgr.getDefaultModel().?);
}

test "save preserves external edits to unrelated fields" {
    const allocator = std.testing.allocator;

    var mem = try allocator.create(storage_mod.InMemorySettingsStorage);
    mem.* = storage_mod.InMemorySettingsStorage.init(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    // Pre-populate with an "external" field we didn't set through SettingsManager
    const initial_json =
        \\{"defaultProvider":"anthropic","theme":"dark","unknownField":"preserved"}
    ;
    mem.global = try allocator.dupe(u8, initial_json);

    var mgr = SettingsManager.fromStorage(allocator, mem.asStorage());
    defer mgr.deinit();

    try std.testing.expectEqualStrings("anthropic", mgr.getDefaultProvider().?);
    try std.testing.expectEqualStrings("dark", mgr.getTheme().?);

    // Modify only defaultModel — should not destroy theme or unknownField
    mgr.setDefaultModel("gpt-5");

    // Read back the raw JSON from storage
    const raw = mem.global orelse return error.TestUnexpectedResult;
    // Verify theme and unknownField survived the merge-on-write
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"preserved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"gpt-5\"") != null);
}
