const std = @import("std");
const paths_mod = @import("paths.zig");

pub const max_settings_file_bytes = 64 * 1024;
pub const max_settings_string_bytes = 4096;

pub const Settings = struct {
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?[]const u8 = null,
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
    io: std.Io,
    dir: std.Io.Dir,
    global_path: []const u8,
    project_path: []const u8,
    snapshot: SettingsSnapshot,

    pub const Options = struct {
        paths: paths_mod.PersistencePaths,
        dir: std.Io.Dir = .cwd(),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !SettingsManager {
        const global_path = try options.paths.globalSettingsPath(allocator);
        errdefer allocator.free(global_path);
        const project_path = try options.paths.projectSettingsPath(allocator);
        errdefer allocator.free(project_path);

        var snapshot: SettingsSnapshot = .{
            .global = try loadFile(allocator, io, options.dir, global_path),
            .project = .missing,
        };
        errdefer snapshot.deinit();
        snapshot.project = try loadFile(allocator, io, options.dir, project_path);

        return .{
            .allocator = allocator,
            .io = io,
            .dir = options.dir,
            .global_path = global_path,
            .project_path = project_path,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *SettingsManager) void {
        self.snapshot.deinit();
        self.allocator.free(self.project_path);
        self.allocator.free(self.global_path);
        self.* = undefined;
    }

    pub fn current(self: *const SettingsManager) *const SettingsSnapshot {
        return &self.snapshot;
    }
};

fn loadFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !SettingsFile {
    const bytes = std.Io.Dir.readFileAlloc(
        dir,
        io,
        path,
        allocator,
        .limited(max_settings_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer allocator.free(bytes);

    return .{ .loaded = try parseSettings(allocator, bytes) };
}

fn parseSettings(allocator: std.mem.Allocator, bytes: []const u8) !LoadedSettings {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;

    return .{
        .allocator = allocator,
        .value = .{
            .default_provider = try optionalString(allocator, parsed.value.object.get("defaultProvider")),
            .default_model = try optionalString(allocator, parsed.value.object.get("defaultModel")),
            .default_thinking_level = try optionalString(allocator, parsed.value.object.get("defaultThinkingLevel")),
        },
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
    try std.testing.expectEqualStrings("agent/settings.json", manager.global_path);
    try std.testing.expectEqualStrings("repo/.zi/settings.json", manager.project_path);
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
