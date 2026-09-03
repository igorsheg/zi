const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const render = @import("../render/root.zig");
const terminal = @import("../terminal/root.zig");
const tool = @import("../tool/root.zig");
const StartupConfig = @import("StartupConfig.zig");

pub const AutomaticBool = enum { auto, on, off };
pub const ImagePolicy = enum { auto, on, off };

pub const ThemeFacts = struct {
    no_color: ?[]const u8 = null,
    term: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    colorfgbg: ?[]const u8 = null,
};

pub const Snapshot = struct {
    markdown: bool,
    show_reasoning: bool,
    display_columns: terminal.DisplayColumns.Policy,
    base_theme: render.Theme,
    run_tint_explicit: bool,
    sort_models: AutomaticBool,
    manual_context_limit: ?u64,
    image_input: ImagePolicy,
    maximum_turns: usize,
    compact_enabled: bool,
    compact_threshold: u8,
    request: ai.RequestPolicy.Policy,
    tools: tool.RuntimePolicy.Policy,
};

pub const Prepared = struct {
    override: config.Selection.PreparedOverride,
    snapshot: Snapshot,

    pub fn deinit(self: *Prepared) void {
        self.override.deinit();
        self.* = undefined;
    }
};

pub const ApplyResult = union(enum) {
    failed,
    changed: config.Settings.Inspection,
};
pub const Error = error{ OutOfMemory, InvalidSetting };

pub const Owner = struct {
    allocator: std.mem.Allocator,
    startup: *StartupConfig.Owner,
    theme_facts: ThemeFacts,
    snapshot: Snapshot,

    pub fn init(
        allocator: std.mem.Allocator,
        startup: *StartupConfig.Owner,
        theme_facts: ThemeFacts,
    ) Error!Owner {
        return .{
            .allocator = allocator,
            .startup = startup,
            .theme_facts = theme_facts,
            .snapshot = try resolveSnapshot(allocator, startup.store(), theme_facts),
        };
    }

    pub fn inspect(
        self: *const Owner,
        allocator: std.mem.Allocator,
        setting: *const config.Settings.Setting,
        maximum_display_bytes: usize,
    ) error{OutOfMemory}!config.Settings.Inspection {
        return config.Settings.inspect(self.startup.store(), allocator, setting, maximum_display_bytes);
    }

    pub fn prepare(
        self: *Owner,
        setting: *const config.Settings.Setting,
        update: config.Settings.Update,
    ) Error!Prepared {
        if (!setting.editable) return error.InvalidSetting;
        var override = self.startup.prepareRunOverride(setting.key, switch (update) {
            .clear => null,
            .set => |value| value,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge, error.Invalid => error.InvalidSetting,
        };
        errdefer override.deinit();
        return .{
            .snapshot = try resolveSnapshot(self.allocator, override.store(), self.theme_facts),
            .override = override,
        };
    }

    pub fn publishRetired(
        self: *Owner,
        prepared: *Prepared,
    ) config.Selection.RetiredOverlay {
        self.snapshot = prepared.snapshot;
        const retired = self.startup.publishRunOverrideRetired(&prepared.override);
        prepared.* = undefined;
        return retired;
    }

    pub fn publish(self: *Owner, prepared: *Prepared) void {
        var retired = self.publishRetired(prepared);
        retired.deinit();
    }

    /// Prepares the candidate snapshot and confirmation text before publishing.
    /// A changed result owns its inspection and the caller must deinitialize it.
    pub fn apply(
        self: *Owner,
        allocator: std.mem.Allocator,
        setting: *const config.Settings.Setting,
        update: config.Settings.Update,
        maximum_display_bytes: usize,
    ) error{OutOfMemory}!ApplyResult {
        var prepared = self.prepare(setting, update) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSetting => .failed,
        };
        var prepared_owned = true;
        defer if (prepared_owned) prepared.deinit();
        var inspection = try config.Settings.inspect(
            prepared.override.store(),
            allocator,
            setting,
            maximum_display_bytes,
        );
        errdefer inspection.deinit(allocator);
        self.publish(&prepared);
        prepared_owned = false;
        return .{ .changed = inspection };
    }

    pub fn deinit(self: *Owner) void {
        self.* = undefined;
    }

    pub fn theme(self: *const Owner) render.Theme {
        if (!self.snapshot.run_tint_explicit) {
            if (self.startup.tint()) |tint| return self.snapshot.base_theme.withTint(tint) catch
                self.snapshot.base_theme;
        }
        return self.snapshot.base_theme;
    }

    pub fn displayPolicy(self: *const Owner) terminal.DisplayColumns.Policy {
        return self.snapshot.display_columns;
    }

    pub fn effectiveContextLimit(self: *const Owner, discovered: u64) ?u64 {
        return self.snapshot.manual_context_limit orelse if (discovered != 0) discovered else null;
    }

    pub fn resolveSortModels(self: *const Owner, keep_provider_order: bool) bool {
        return switch (self.snapshot.sort_models) {
            .auto => !keep_provider_order,
            .on => true,
            .off => false,
        };
    }

    pub fn resolveImageInput(
        self: *const Owner,
        support: ai.ModelMeta.Support,
    ) ai.Provider.ImageInput {
        return switch (self.snapshot.image_input) {
            .auto => switch (support) {
                .yes => .supported,
                .no => .unsupported,
                .unknown => .unknown,
            },
            .on => .supported,
            .off => .unsupported,
        };
    }

    pub fn requestPolicy(self: *const Owner) ai.RequestPolicy.Policy {
        return self.snapshot.request;
    }

    pub fn toolPolicy(self: *const Owner) tool.RuntimePolicy.Policy {
        return self.snapshot.tools;
    }
};

fn resolveSnapshot(
    allocator: std.mem.Allocator,
    store: config.Store,
    facts: ThemeFacts,
) Error!Snapshot {
    var configured_theme = try config.Settings.getString(store, allocator, "theme");
    defer configured_theme.deinit(allocator);
    var configured_tint = try config.Settings.getString(store, allocator, "tint");
    defer configured_tint.deinit(allocator);
    const theme_resolution = render.Theme.resolveWithFallback(.{
        .configured_theme = configured_theme.value orelse "auto",
        .configured_tint = configured_tint.value orelse "teal",
        .no_color = facts.no_color,
        .term = facts.term,
        .colorterm = facts.colorterm,
        .colorfgbg = facts.colorfgbg,
    });

    var display_width = try config.Settings.getString(store, allocator, "display_width");
    defer display_width.deinit(allocator);
    const display_columns = terminal.DisplayColumns.Policy.parse(display_width.value orelse "auto") catch
        terminal.DisplayColumns.Policy.auto;

    var sort_models = try config.Settings.getString(store, allocator, "sort_models");
    defer sort_models.deinit(allocator);
    var image_input = try config.Settings.getString(store, allocator, "image_input");
    defer image_input.deinit(allocator);

    const context_value = (try config.Settings.getSize(store, allocator, "context_limit")).value;
    const configured_max_turns = (try config.Settings.getInt(store, allocator, "max_turns")).value;
    const maximum_turns: usize = if (configured_max_turns <= 0)
        agent.Loop.maximum_max_turns
    else
        @min(@as(usize, @intCast(configured_max_turns)), agent.Loop.maximum_max_turns);

    const request: ai.RequestPolicy.Policy = .{
        .show_reasoning = (try config.Settings.getBool(store, allocator, "show_reasoning")).value,
        .additional_retries = @intCast((try config.Settings.getInt(
            store,
            allocator,
            "http.max_retries",
        )).value),
        .retry_base_ms = (try config.Settings.getDurationMs(store, allocator, "http.retry_base")).value,
        .idle_timeout_ms = (try config.Settings.getDurationMs(store, allocator, "http.idle_timeout")).value,
    };
    ai.RequestPolicy.validate(request) catch return error.InvalidSetting;

    const tools: tool.RuntimePolicy.Policy = .{
        .output_bytes = @intCast((try config.Settings.getSize(store, allocator, "tool_output_cap")).value),
        .bash_timeout_ms = (try config.Settings.getDurationMs(store, allocator, "bash.timeout")).value,
        .bash_maximum_timeout_ms = (try config.Settings.getDurationMs(store, allocator, "bash.timeout_max")).value,
        .bash_termination_grace_ms = (try config.Settings.getDurationMs(
            store,
            allocator,
            "bash.timeout_grace",
        )).value,
        .bash_background_yield_ms = (try config.Settings.getDurationMs(
            store,
            allocator,
            "bash.background_yield",
        )).value,
        .task_wait_timeout_ms = (try config.Settings.getDurationMs(store, allocator, "task.wait_timeout")).value,
        .task_maximum_running = @intCast((try config.Settings.getInt(
            store,
            allocator,
            "task.max_running",
        )).value),
    };
    tool.RuntimePolicy.validate(tools) catch return error.InvalidSetting;

    return .{
        .markdown = (try config.Settings.getBool(store, allocator, "markdown")).value,
        .show_reasoning = request.show_reasoning,
        .display_columns = display_columns,
        .base_theme = theme_resolution.theme,
        .run_tint_explicit = configured_tint.source == .run,
        .sort_models = parseAutomaticBool(sort_models.value),
        .manual_context_limit = if (context_value == 0) null else context_value,
        .image_input = parseImagePolicy(image_input.value),
        .maximum_turns = maximum_turns,
        .compact_enabled = (try config.Settings.getBool(store, allocator, "compact.auto")).value,
        .compact_threshold = @intCast((try config.Settings.getInt(
            store,
            allocator,
            "compact.threshold",
        )).value),
        .request = request,
        .tools = tools,
    };
}

fn parseAutomaticBool(value: ?[]const u8) AutomaticBool {
    const text = value orelse return .auto;
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;
    if (boolean(text)) |enabled| return if (enabled) .on else .off;
    return .auto;
}

fn parseImagePolicy(value: ?[]const u8) ImagePolicy {
    const text = value orelse return .auto;
    if (std.ascii.eqlIgnoreCase(text, "auto")) return .auto;
    if (boolean(text)) |enabled| return if (enabled) .on else .off;
    return .auto;
}

fn boolean(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "off")) return false;
    return null;
}

const EmptyEnvironment = struct {
    pub fn get(_: *const EmptyEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

test "snapshot resolves all editable runtime policy fields" {
    var document = try config.Document.parse(
        std.testing.allocator,
        "{\"markdown\":false,\"show_reasoning\":true,\"sort_models\":\"off\"," ++
            "\"context_limit\":\"64k\",\"display_width\":\"40\",\"theme\":\"off\"," ++
            "\"tint\":\"rose\",\"compact.auto\":false,\"compact.threshold\":75," ++
            "\"max_turns\":9,\"image_input\":\"on\",\"tool_output_cap\":\"32k\"," ++
            "\"bash.timeout\":\"3s\",\"bash.timeout_max\":\"30s\"," ++
            "\"bash.timeout_grace\":\"250ms\",\"bash.background_yield\":\"2s\"," ++
            "\"task.wait_timeout\":\"4s\",\"task.max_running\":64," ++
            "\"http.max_retries\":2,\"http.retry_base\":\"20ms\"," ++
            "\"http.idle_timeout\":0}",
        config.Document.runtime_limits,
    );
    defer document.deinit();
    var environment: EmptyEnvironment = .{};
    const store = config.Store.init(.{
        .run = &document,
        .registry = config.Settings.storeRegistry(),
        .environment = .from(&environment),
    });
    const snapshot = try resolveSnapshot(std.testing.allocator, store, .{});
    try std.testing.expect(!snapshot.markdown);
    try std.testing.expect(snapshot.show_reasoning);
    try std.testing.expectEqual(AutomaticBool.off, snapshot.sort_models);
    try std.testing.expectEqual(@as(?u64, 64 * 1024), snapshot.manual_context_limit);
    const expected_width: terminal.DisplayColumns.Policy = .{ .fixed = 40 };
    try std.testing.expectEqual(expected_width, snapshot.display_columns);
    try std.testing.expectEqual(render.Theme.Name.off, snapshot.base_theme.name);
    try std.testing.expectEqual(render.Theme.Tint.rose, snapshot.base_theme.tint);
    try std.testing.expect(snapshot.run_tint_explicit);
    try std.testing.expect(!snapshot.compact_enabled);
    try std.testing.expectEqual(@as(u8, 75), snapshot.compact_threshold);
    try std.testing.expectEqual(@as(usize, 9), snapshot.maximum_turns);
    try std.testing.expectEqual(ImagePolicy.on, snapshot.image_input);
    try std.testing.expectEqual(@as(usize, 32 * 1024), snapshot.tools.output_bytes);
    try std.testing.expectEqual(@as(u64, 3 * 1000), snapshot.tools.bash_timeout_ms);
    try std.testing.expectEqual(@as(u64, 30 * 1000), snapshot.tools.bash_maximum_timeout_ms);
    try std.testing.expectEqual(@as(u64, 250), snapshot.tools.bash_termination_grace_ms);
    try std.testing.expectEqual(@as(u64, 2 * 1000), snapshot.tools.bash_background_yield_ms);
    try std.testing.expectEqual(@as(u64, 4 * 1000), snapshot.tools.task_wait_timeout_ms);
    try std.testing.expectEqual(@as(usize, 64), snapshot.tools.task_maximum_running);
    try std.testing.expectEqual(@as(u16, 2), snapshot.request.additional_retries);
    try std.testing.expectEqual(@as(u64, 20), snapshot.request.retry_base_ms);
    try std.testing.expectEqual(@as(u64, 0), snapshot.request.idle_timeout_ms);
}

fn exerciseSnapshotAllocationFailures(allocator: std.mem.Allocator) !void {
    var document = try config.Document.parse(
        allocator,
        "{\"theme\":\"dark\",\"tint\":\"sage\",\"display_width\":\"80\"," ++
            "\"sort_models\":\"on\",\"image_input\":\"off\"}",
        config.Document.runtime_limits,
    );
    defer document.deinit();
    var environment: EmptyEnvironment = .{};
    const store = config.Store.init(.{
        .run = &document,
        .registry = config.Settings.storeRegistry(),
        .environment = .from(&environment),
    });
    _ = try resolveSnapshot(allocator, store, .{ .term = "xterm-256color" });
}

test "snapshot resolution releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSnapshotAllocationFailures,
        .{},
    );
}
