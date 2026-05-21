const std = @import("std");
const runtime = @import("../runtime/root.zig");
const schema = @import("schema.zig");

pub const Error = error{
    SettingsFileTooLarge,
    TooManyModels,
    InvalidSettings,
} || std.mem.Allocator.Error || std.Io.Dir.StatFileError || std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner);

pub fn load(allocator: std.mem.Allocator, io: std.Io, storage: runtime.storage.Storage) Error!schema.Settings {
    var settings = schema.Settings.empty(allocator);
    errdefer settings.deinit();

    try loadFileIfPresent(&settings, io, storage.user_settings);
    if (storage.project_settings) |path| try loadFileIfPresent(&settings, io, path);

    return settings;
}

fn loadFileIfPresent(settings: *schema.Settings, io: std.Io, path: []const u8) Error!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (stat.size > schema.max_settings_file_bytes) return error.SettingsFileTooLarge;

    const allocator = settings.arena.child_allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(schema.max_settings_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(
        schema.JsonSettings,
        settings.arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try applyJsonSettings(settings, parsed.value);
}

fn applyJsonSettings(settings: *schema.Settings, json: schema.JsonSettings) Error!void {
    const allocator = settings.arena.allocator();

    if (json.defaultProvider) |value| settings.default_provider = try allocator.dupe(u8, value);
    if (json.defaultModel) |value| settings.default_model = try allocator.dupe(u8, value);

    if (json.models) |models| {
        if (models.len > schema.max_models) return error.TooManyModels;
        for (models) |model| try upsertModel(settings, model);
    }
}

fn upsertModel(settings: *schema.Settings, json: schema.JsonModel) Error!void {
    const allocator = settings.arena.allocator();
    const model = schema.Model{
        .id = try allocator.dupe(u8, json.id),
        .name = if (json.name) |value| try allocator.dupe(u8, value) else null,
        .api = try allocator.dupe(u8, json.api),
        .provider = try allocator.dupe(u8, json.provider),
        .base_url = if (json.baseUrl) |value| try allocator.dupe(u8, value) else null,
        .provider_model = if (json.providerModel) |value| try allocator.dupe(u8, value) else null,
        .context_window = json.contextWindow,
        .max_tokens = json.maxTokens,
    };

    for (settings.models, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.id, model.id)) {
            settings.models[index] = model;
            return;
        }
    }

    if (settings.models.len == schema.max_models) return error.TooManyModels;
    const next = try allocator.alloc(schema.Model, settings.models.len + 1);
    @memcpy(next[0..settings.models.len], settings.models);
    next[settings.models.len] = model;
    settings.models = next;
}

test "settings load empty when files are missing" {
    var storage = try runtime.storage.Storage.initFromHome(std.testing.allocator, "/tmp/zi-missing-home", "/tmp/zi-missing-project");
    defer storage.deinit();

    var settings = try load(std.testing.allocator, std.testing.io, storage);
    defer settings.deinit();

    try std.testing.expect(settings.default_provider == null);
    try std.testing.expect(settings.default_model == null);
    try std.testing.expectEqual(@as(usize, 0), settings.models.len);
}

test "settings load user defaults" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeUserSettings(
        \\{
        \\  "defaultProvider": "openai",
        \\  "defaultschema.Model": "gpt-5"
        \\}
    );

    var settings = try load(std.testing.allocator, std.testing.io, fixture.storage);
    defer settings.deinit();

    try std.testing.expectEqualStrings("openai", settings.default_provider.?);
    try std.testing.expectEqualStrings("gpt-5", settings.default_model.?);
}

test "settings project defaults override user defaults" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeUserSettings(
        \\{"defaultschema.Model":"gpt-5"}
    );
    try fixture.writeProjectSettings(
        \\{"defaultschema.Model":"openrouter/sonnet"}
    );

    var settings = try load(std.testing.allocator, std.testing.io, fixture.storage);
    defer settings.deinit();

    try std.testing.expectEqualStrings("openrouter/sonnet", settings.default_model.?);
}

test "settings models merge by id with project override" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeUserSettings(
        \\{
        \\  "models": [
        \\    {"id":"custom","api":"openai","provider":"openai","providerschema.Model":"old"},
        \\    {"id":"user-only","api":"openai","provider":"openai"}
        \\  ]
        \\}
    );
    try fixture.writeProjectSettings(
        \\{
        \\  "models": [
        \\    {"id":"custom","api":"openai","provider":"openrouter","providerschema.Model":"new"}
        \\  ]
        \\}
    );

    var settings = try load(std.testing.allocator, std.testing.io, fixture.storage);
    defer settings.deinit();

    try std.testing.expectEqual(@as(usize, 2), settings.models.len);
    try std.testing.expectEqualStrings("custom", settings.models[0].id);
    try std.testing.expectEqualStrings("openrouter", settings.models[0].provider);
    try std.testing.expectEqualStrings("new", settings.models[0].provider_model.?);
    try std.testing.expectEqualStrings("user-only", settings.models[1].id);
}

test "settings unknown fields are ignored" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeUserSettings(
        \\{"unknown":true,"defaultschema.Model":"gpt-5"}
    );

    var settings = try load(std.testing.allocator, std.testing.io, fixture.storage);
    defer settings.deinit();

    try std.testing.expectEqualStrings("gpt-5", settings.default_model.?);
}

test "settings malformed json is rejected" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeUserSettings("{");

    try std.testing.expectError(error.UnexpectedEndOfInput, load(std.testing.allocator, std.testing.io, fixture.storage));
}

test "settings reject too many models" {
    var settings = schema.Settings.empty(std.testing.allocator);
    defer settings.deinit();

    for (0..schema.max_models) |index| {
        const id = try std.fmt.allocPrint(std.testing.allocator, "model-{d}", .{index});
        defer std.testing.allocator.free(id);
        try upsertModel(&settings, .{ .id = id, .api = "openai", .provider = "openai" });
    }

    try std.testing.expectError(error.TooManyModels, upsertModel(&settings, .{ .id = "overflow", .api = "openai", .provider = "openai" }));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home_path: []const u8,
    project_path: []const u8,
    storage: runtime.storage.Storage,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_path = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
        const home_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "home" });
        errdefer std.testing.allocator.free(home_path);
        const project_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "project" });
        errdefer std.testing.allocator.free(project_path);

        try std.Io.Dir.cwd().createDirPath(std.testing.io, home_path);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, project_path);

        const storage = try runtime.storage.Storage.initFromHome(std.testing.allocator, home_path, project_path);
        return .{ .tmp = tmp, .home_path = home_path, .project_path = project_path, .storage = storage };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.storage.deinit();
        std.testing.allocator.free(fixture.project_path);
        std.testing.allocator.free(fixture.home_path);
        fixture.tmp.cleanup();
        fixture.* = undefined;
    }

    fn writeUserSettings(fixture: Fixture, bytes: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture.storage.agent_home);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture.storage.user_settings, .data = bytes });
    }

    fn writeProjectSettings(fixture: Fixture, bytes: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, fixture.storage.project_zi.?);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture.storage.project_settings.?, .data = bytes });
    }
};
