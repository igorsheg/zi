const std = @import("std");
const paths_mod = @import("paths.zig");

pub const max_settings_file_bytes = 64 * 1024;
pub const max_settings_string_bytes = 4096;

pub const Settings = struct {
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?[]const u8 = null,
    hide_thinking_block: ?bool = null,
    compaction: ?Compaction = null,
    retry: ?Retry = null,

    pub const Compaction = struct {
        keep_recent_tokens: ?u64 = null,
        reserve_tokens: ?u64 = null,
        enabled: ?bool = null,
    };

    pub const Retry = struct {
        enabled: ?bool = null,
        max_retries: ?u64 = null,
        base_delay_ms: ?u64 = null,
    };
};

pub const LoadedSettings = struct {
    allocator: std.mem.Allocator,
    value: Settings,

    pub fn deinit(self: *LoadedSettings) void {
        if (self.value.default_provider) |text| self.allocator.free(text);
        if (self.value.default_model) |text| self.allocator.free(text);
        if (self.value.default_thinking_level) |text| self.allocator.free(text);
        self.* = undefined;
    }
};

pub const SettingsFile = union(enum) {
    missing,
    loaded: LoadedSettings,

    pub fn deinit(self: *SettingsFile) void {
        switch (self.*) {
            .missing => {},
            .loaded => |*settings| settings.deinit(),
        }
        self.* = undefined;
    }
};

pub const SettingsSnapshot = struct {
    global: SettingsFile,
    project: SettingsFile,

    pub fn deinit(self: *SettingsSnapshot) void {
        self.global.deinit();
        self.project.deinit();
        self.* = undefined;
    }
};

pub const SettingsManager = struct {
    allocator: std.mem.Allocator,
    global_dir: []u8,
    snapshot: SettingsSnapshot,

    pub const Options = struct {
        paths: paths_mod.PersistencePaths,
        dir: std.Io.Dir = .cwd(),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !SettingsManager {
        const global_path = try options.paths.globalSettingsPath(allocator);
        defer allocator.free(global_path);
        const project_path = try options.paths.projectSettingsPath(allocator);
        defer allocator.free(project_path);

        const global_dir = try allocator.dupe(u8, options.paths.global_dir);
        errdefer allocator.free(global_dir);

        var snapshot: SettingsSnapshot = .{
            .global = try loadFile(allocator, io, options.dir, global_path),
            .project = .missing,
        };
        errdefer snapshot.deinit();
        snapshot.project = try loadFile(allocator, io, options.dir, project_path);

        return .{
            .allocator = allocator,
            .global_dir = global_dir,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *SettingsManager) void {
        self.snapshot.deinit();
        self.allocator.free(self.global_dir);
        self.* = undefined;
    }

    pub fn current(self: *const SettingsManager) *const SettingsSnapshot {
        return &self.snapshot;
    }

    pub fn setDefaultModel(
        self: *SettingsManager,
        io: std.Io,
        dir: std.Io.Dir,
        provider: []const u8,
        model: []const u8,
    ) !void {
        var global = fileSettings(self.snapshot.global);
        global.default_provider = provider;
        global.default_model = model;
        try self.replaceGlobalSettings(io, dir, global);
    }

    pub fn setDefaultThinkingLevel(
        self: *SettingsManager,
        io: std.Io,
        dir: std.Io.Dir,
        level: []const u8,
    ) !void {
        var global = fileSettings(self.snapshot.global);
        global.default_thinking_level = level;
        try self.replaceGlobalSettings(io, dir, global);
    }

    pub fn setHideThinkingBlock(
        self: *SettingsManager,
        io: std.Io,
        dir: std.Io.Dir,
        hidden: bool,
    ) !void {
        var global = fileSettings(self.snapshot.global);
        global.hide_thinking_block = hidden;
        try self.replaceGlobalSettings(io, dir, global);
    }

    fn replaceGlobalSettings(self: *SettingsManager, io: std.Io, dir: std.Io.Dir, global: Settings) !void {
        try writeGlobalSettings(self.allocator, io, dir, self.global_dir, global);
        var next = try loadedSettingsFromValue(self.allocator, global);
        errdefer next.deinit();
        self.snapshot.global.deinit();
        self.snapshot.global = .{ .loaded = next };
    }
};

fn fileSettings(file: SettingsFile) Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

fn loadedSettingsFromValue(allocator: std.mem.Allocator, value: Settings) !LoadedSettings {
    return .{ .allocator = allocator, .value = .{
        .default_provider = if (value.default_provider) |text| try allocator.dupe(u8, text) else null,
        .default_model = if (value.default_model) |text| try allocator.dupe(u8, text) else null,
        .default_thinking_level = if (value.default_thinking_level) |text| try allocator.dupe(u8, text) else null,
        .hide_thinking_block = value.hide_thinking_block,
        .compaction = value.compaction,
        .retry = value.retry,
    } };
}

fn writeGlobalSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    global_dir: []const u8,
    value: Settings,
) !void {
    try dir.createDirPath(io, global_dir);
    const path = try std.fs.path.join(allocator, &.{ global_dir, paths_mod.settings_file_name });
    defer allocator.free(path);

    const existing = std.Io.Dir.readFileAlloc(
        dir,
        io,
        path,
        allocator,
        .limited(max_settings_file_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => "{}",
    };
    defer if (existing.ptr != "{}".ptr) allocator.free(existing);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch
        try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        parsed.deinit();
        parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }

    const json_allocator = parsed.arena.allocator();
    if (value.default_provider) |text| try parsed.value.object.put(json_allocator, "defaultProvider", .{ .string = text });
    if (value.default_model) |text| try parsed.value.object.put(json_allocator, "defaultModel", .{ .string = text });
    if (value.default_thinking_level) |text| {
        try parsed.value.object.put(json_allocator, "defaultThinkingLevel", .{ .string = text });
    }
    if (value.hide_thinking_block) |hidden| {
        try parsed.value.object.put(json_allocator, "hideThinkingBlock", .{ .bool = hidden });
    }

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &bytes.writer);
    try bytes.writer.writeByte('\n');
    try writeFileAtomic(allocator, io, dir, path, bytes.written());
}

fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    data: []const u8,
) !void {
    const parent = std.fs.path.dirname(path);
    const basename = std.fs.path.basename(path);
    const tmp_basename = try std.fmt.allocPrint(allocator, ".{s}.tmp", .{basename});
    defer allocator.free(tmp_basename);
    const tmp_path = if (parent) |dir_path|
        try std.fs.path.join(allocator, &.{ dir_path, tmp_basename })
    else
        try allocator.dupe(u8, tmp_basename);
    defer allocator.free(tmp_path);
    errdefer dir.deleteFile(io, tmp_path) catch {};
    try dir.writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.rename(dir, tmp_path, dir, path, io);
}

/// A settings file is operational input: a missing, unreadable, or malformed
/// file degrades to defaults. Only allocation failure propagates.
fn loadFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !SettingsFile {
    const bytes = std.Io.Dir.readFileAlloc(
        dir,
        io,
        path,
        allocator,
        .limited(max_settings_file_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .missing,
    };
    defer allocator.free(bytes);

    return .{ .loaded = parseSettings(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .missing,
    } };
}

fn parseSettings(allocator: std.mem.Allocator, bytes: []const u8) !LoadedSettings {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;

    var value: Settings = .{};
    errdefer {
        if (value.default_provider) |text| allocator.free(text);
        if (value.default_model) |text| allocator.free(text);
        if (value.default_thinking_level) |text| allocator.free(text);
    }
    value.default_provider = try optionalString(allocator, parsed.value.object.get("defaultProvider"));
    value.default_model = try optionalString(allocator, parsed.value.object.get("defaultModel"));
    value.default_thinking_level = try optionalString(allocator, parsed.value.object.get("defaultThinkingLevel"));
    value.hide_thinking_block = try optionalBool(parsed.value.object.get("hideThinkingBlock"));
    value.compaction = try optionalCompaction(parsed.value.object.get("compaction"));
    value.retry = try optionalRetry(parsed.value.object.get("retry"));
    return .{ .allocator = allocator, .value = value };
}

fn optionalCompaction(value: ?std.json.Value) !?Settings.Compaction {
    const resolved = value orelse return null;
    if (resolved == .null) return null;
    if (resolved != .object) return error.InvalidSettings;
    return .{
        .keep_recent_tokens = try optionalNonNegativeInteger(resolved.object.get("keepRecentTokens")),
        .reserve_tokens = try optionalNonNegativeInteger(resolved.object.get("reserveTokens")),
        .enabled = try optionalBool(resolved.object.get("enabled")),
    };
}

fn optionalRetry(value: ?std.json.Value) !?Settings.Retry {
    const resolved = value orelse return null;
    if (resolved == .null) return null;
    if (resolved != .object) return error.InvalidSettings;
    return .{
        .enabled = try optionalBool(resolved.object.get("enabled")),
        .max_retries = try optionalNonNegativeInteger(resolved.object.get("maxRetries")),
        .base_delay_ms = try optionalNonNegativeInteger(resolved.object.get("baseDelayMs")),
    };
}

fn optionalString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .null => null,
        .string => |text| {
            if (text.len > max_settings_string_bytes) return error.InvalidSettings;
            return try allocator.dupe(u8, text);
        },
        else => error.InvalidSettings,
    };
}

fn optionalNonNegativeInteger(value: ?std.json.Value) !?u64 {
    const resolved = value orelse return null;
    if (resolved == .null) return null;
    if (resolved != .integer or resolved.integer < 0) return error.InvalidSettings;
    return @intCast(resolved.integer);
}

fn optionalBool(value: ?std.json.Value) !?bool {
    const resolved = value orelse return null;
    if (resolved == .null) return null;
    if (resolved != .bool) return error.InvalidSettings;
    return resolved.bool;
}

test "settings manager degrades malformed settings to defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/settings.json", .data = "{not json" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultProvider\":123}",
    });

    var manager = try SettingsManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer manager.deinit();

    try std.testing.expectEqual(SettingsFile.missing, manager.current().global);
    try std.testing.expectEqual(SettingsFile.missing, manager.current().project);
}

test "settings manager treats missing global and project settings as defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var manager = try SettingsManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer manager.deinit();

    try std.testing.expectEqual(SettingsFile.missing, manager.current().global);
    try std.testing.expectEqual(SettingsFile.missing, manager.current().project);
}

test "settings manager loads global and project default model settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"defaultThinkingLevel\":\"high\"}",
    });

    var manager = try SettingsManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer manager.deinit();

    try std.testing.expectEqualStrings("openai", manager.current().global.loaded.value.default_provider.?);
    try std.testing.expectEqualStrings("gpt", manager.current().global.loaded.value.default_model.?);
    try std.testing.expectEqualStrings("high", manager.current().project.loaded.value.default_thinking_level.?);
}

test "settings manager loads compaction and retry settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/settings.json",
        .data = "{\"compaction\":{\"keepRecentTokens\":1234,\"enabled\":true}," ++
            "\"retry\":{\"enabled\":true,\"maxRetries\":2,\"baseDelayMs\":50}}",
    });

    var manager = try SettingsManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer manager.deinit();

    try std.testing.expectEqual(
        @as(u64, 1234),
        manager.current().project.loaded.value.compaction.?.keep_recent_tokens.?,
    );
    try std.testing.expect(manager.current().project.loaded.value.compaction.?.enabled.?);
    try std.testing.expect(manager.current().project.loaded.value.retry.?.enabled.?);
    try std.testing.expectEqual(
        @as(u64, 2),
        manager.current().project.loaded.value.retry.?.max_retries.?,
    );
    try std.testing.expectEqual(
        @as(u64, 50),
        manager.current().project.loaded.value.retry.?.base_delay_ms.?,
    );
}
