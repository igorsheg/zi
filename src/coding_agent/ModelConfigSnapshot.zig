const std = @import("std");
const ai_catalog = @import("../ai/model_catalog.zig");
const ai_settings = @import("../ai/settings.zig");
const ModelConfig = @import("ModelConfig.zig");
const ZiPaths = @import("ZiPaths.zig");

const ModelConfigSnapshot = @This();

const max_document_bytes = 1024 * 1024;
const max_value_bytes = 32 * 1024;
const max_custom_providers = 30;
const max_models_per_provider = 64;
const max_custom_models = 256;
const max_aliases = 16;
const max_provider_id_bytes = 256;
const max_provider_name_bytes = 256;
const max_model_id_bytes = 512;
const max_endpoint_bytes = 8 * 1024;

pub const Diagnostic = enum {
    unreadable,
    too_large,
    invalid,
};

pub const LoadError = error{
    OutOfMemory,
    Cancelled,
};

const Source = struct {
    version: u32,
    providers: []const SourceProvider,
};

const SourceProvider = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    authentication: Authentication,
    models: []const SourceModel,
};

const Authentication = enum {
    none,
    api_key,
};

const SourceModel = struct {
    id: []const u8,
    aliases: []const []const u8 = &.{},
    profile: SourceProfile,
};

const SourceProfile = struct {
    capabilities: []const ai_settings.Capability,
    settings: []const ai_settings.Setting,
    context_window: u64,
    max_output_tokens: u64,
};

arena: std.heap.ArenaAllocator,
state: State,

const State = union(enum) {
    builtin: ?Diagnostic,
    configured: ModelConfig,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) LoadError!ModelConfigSnapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const source_text = std.Io.Dir.cwd().readFileAlloc(
        io,
        paths.global_models_file,
        allocator,
        .limited(max_document_bytes),
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
        error.FileNotFound => settled(arena, null),
        error.StreamTooLong => settled(arena, .too_large),
        else => settled(arena, .unreadable),
    };
    defer allocator.free(source_text);

    const source = std.json.parseFromSliceLeaky(Source, arena.allocator(), source_text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_value_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => settled(arena, .invalid),
    };
    const config = compose(arena.allocator(), source) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidModelsFile => settled(arena, .invalid),
    };
    return .{
        .arena = arena,
        .state = .{ .configured = config },
    };
}

pub fn view(self: *const ModelConfigSnapshot) ModelConfig {
    return switch (self.state) {
        .builtin => ModelConfig.builtin,
        .configured => |config| config,
    };
}

pub fn diagnostic(self: *const ModelConfigSnapshot) ?Diagnostic {
    return switch (self.state) {
        .builtin => |value| value,
        .configured => null,
    };
}

pub fn deinit(self: *ModelConfigSnapshot) void {
    self.arena.deinit();
    self.* = undefined;
}

fn settled(arena: std.heap.ArenaAllocator, diagnostic_value: ?Diagnostic) ModelConfigSnapshot {
    return .{
        .arena = arena,
        .state = .{ .builtin = diagnostic_value },
    };
}

fn compose(allocator: std.mem.Allocator, source: Source) error{ OutOfMemory, InvalidModelsFile }!ModelConfig {
    if (source.version != 1 or source.providers.len > max_custom_providers) {
        return error.InvalidModelsFile;
    }
    var custom_model_count: usize = 0;
    for (source.providers) |provider| {
        try validateProvider(provider);
        if (provider.models.len > max_custom_models - custom_model_count) return error.InvalidModelsFile;
        custom_model_count += provider.models.len;
    }

    const entries = try allocator.alloc(
        ai_catalog.Entry,
        ModelConfig.builtin.catalog.entries.len + custom_model_count,
    );
    @memcpy(entries[0..ModelConfig.builtin.catalog.entries.len], ModelConfig.builtin.catalog.entries);
    var entry_index = ModelConfig.builtin.catalog.entries.len;
    for (source.providers) |provider| {
        for (provider.models) |model| {
            entries[entry_index] = .{
                .identity = .{ .provider = provider.id, .model = model.id },
                .aliases = model.aliases,
                .profile = try profile(model.profile),
            };
            entry_index += 1;
        }
    }

    const providers = try allocator.alloc(
        ModelConfig.ProviderDefinition,
        ModelConfig.builtin.providers.len + source.providers.len,
    );
    @memcpy(providers[0..ModelConfig.builtin.providers.len], ModelConfig.builtin.providers);
    for (source.providers, 0..) |provider, index| {
        providers[ModelConfig.builtin.providers.len + index] = .{ .openai_completions = .{
            .id = provider.id,
            .name = provider.name,
            .base_url = provider.base_url,
            .authentication = switch (provider.authentication) {
                .none => .none,
                .api_key => .api_key,
            },
        } };
    }
    return ModelConfig.init(.{ .entries = entries }, providers) catch return error.InvalidModelsFile;
}

fn validateProvider(provider: SourceProvider) error{InvalidModelsFile}!void {
    try validateIdentifierBytes(provider.id, max_provider_id_bytes);
    try validateText(provider.name, max_provider_name_bytes);
    try validateEndpoint(provider.base_url);
    if (provider.models.len == 0 or provider.models.len > max_models_per_provider) {
        return error.InvalidModelsFile;
    }
    for (provider.models) |model| {
        try validateIdentifierBytes(model.id, max_model_id_bytes);
        if (model.aliases.len > max_aliases) return error.InvalidModelsFile;
        for (model.aliases) |alias| try validateIdentifierBytes(alias, max_model_id_bytes);
    }
}

fn profile(source: SourceProfile) error{InvalidModelsFile}!ai_settings.ModelProfile {
    var capabilities: std.EnumSet(ai_settings.Capability) = .initEmpty();
    for (source.capabilities) |capability| {
        if (capability == .image_input or capabilities.contains(capability)) return error.InvalidModelsFile;
        capabilities.insert(capability);
    }
    if (!capabilities.contains(.streaming) or !capabilities.contains(.tools)) {
        return error.InvalidModelsFile;
    }

    var settings: std.EnumSet(ai_settings.Setting) = .initEmpty();
    for (source.settings) |setting| {
        if (setting == .reasoning_effort or settings.contains(setting)) return error.InvalidModelsFile;
        settings.insert(setting);
    }
    return .{
        .capabilities = capabilities,
        .settings = settings,
        .context_window = source.context_window,
        .max_output_tokens = source.max_output_tokens,
    };
}

fn validateIdentifierBytes(value: []const u8, maximum_bytes: usize) error{InvalidModelsFile}!void {
    if (value.len > maximum_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
}

fn validateText(value: []const u8, maximum_bytes: usize) error{InvalidModelsFile}!void {
    if (value.len == 0 or value.len > maximum_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
    var has_non_whitespace = false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidModelsFile;
        if (!std.ascii.isWhitespace(byte)) has_non_whitespace = true;
    }
    if (!has_non_whitespace) return error.InvalidModelsFile;
}

fn validateEndpoint(value: []const u8) error{InvalidModelsFile}!void {
    if (value.len == 0 or value.len > max_endpoint_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidModelsFile;
    }
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidModelsFile;
    const uri = std.Uri.parse(value) catch return error.InvalidModelsFile;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidModelsFile;
    }
    if (uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
    {
        return error.InvalidModelsFile;
    }
}

const valid_source =
    \\{
    \\  "version": 1,
    \\  "providers": [{
    \\    "id": "local",
    \\    "name": "Local Models",
    \\    "base_url": "http://127.0.0.1:11434/v1",
    \\    "authentication": "api_key",
    \\    "models": [{
    \\      "id": "qwen-coder",
    \\      "aliases": ["local-coder"],
    \\      "profile": {
    \\        "capabilities": ["streaming", "tools", "parallel_tool_calls"],
    \\        "settings": ["temperature", "max_output_tokens"],
    \\        "context_window": 32768,
    \\        "max_output_tokens": 8192
    \\      }
    \\    }]
    \\  }]
    \\}
;

fn testPaths(temporary: *std.testing.TmpDir, buffer: []u8) !ZiPaths {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return ZiPaths.init(std.testing.allocator, buffer[0..length], buffer[0..length]);
}

fn writeModels(temporary: *std.testing.TmpDir, contents: []const u8) !void {
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/agent/models.json",
        .data = contents,
    });
}

test "missing global models file settles to built-ins" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.diagnostic() == null);
    try std.testing.expectEqual(ModelConfig.builtin.providers.len, snapshot.view().providers.len);
    try std.testing.expectEqual(ModelConfig.builtin.catalog.entries.len, snapshot.view().catalog.entries.len);
}

test "global models snapshot owns a custom compatible provider and canonical alias" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, valid_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();
    paths.deinit();
    try writeModels(&temporary, "invalid after load");

    try std.testing.expect(snapshot.diagnostic() == null);
    const config = snapshot.view();
    try std.testing.expectEqual(ModelConfig.builtin.providers.len + 1, config.providers.len);
    try std.testing.expectEqual(ModelConfig.builtin.catalog.entries.len + 1, config.catalog.entries.len);
    const provider = config.findProvider("local").?.openai_completions;
    try std.testing.expectEqualStrings("Local Models", provider.name);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", provider.base_url);
    try std.testing.expectEqual(ModelConfig.ProviderDefinition.OpenAi.Authentication.api_key, provider.authentication);
    const resolved = config.resolve(.{ .provider = "local", .model = "local-coder" }).?;
    try std.testing.expectEqualStrings("qwen-coder", resolved.canonicalModelId());
    try std.testing.expect(resolved.entry.profile.supports(.streaming));
    try std.testing.expect(resolved.entry.profile.supports(.tools));
    try std.testing.expect(resolved.entry.profile.supportsSetting(.temperature));
    try std.testing.expectEqual(@as(?u64, 32768), resolved.entry.profile.context_window);
}

test "invalid global models files retain built-ins with one diagnostic" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    const cases = [_][]const u8{
        "not json",
        \\{"version":2,"providers":[]}
        ,
        \\{"version":1,"providers":[],"unknown":true}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"version":1,"providers":[{"id":"openai","name":"Collision","base_url":"https://example.test/v1","authentication":"api_key","models":[{"id":"model","profile":{"capabilities":["streaming","tools"],"settings":[],"context_window":100,"max_output_tokens":20}}]}]}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"version":1,"providers":[{"id":"bad","name":"Bad","base_url":"file:///tmp/model","authentication":"none","models":[{"id":"model","profile":{"capabilities":["streaming","tools"],"settings":[],"context_window":100,"max_output_tokens":20}}]}]}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"version":1,"providers":[{"id":"bad","name":"Bad","base_url":"https://example.test/v1","authentication":"none","models":[{"id":"model","profile":{"capabilities":["streaming"],"settings":[],"context_window":100,"max_output_tokens":20}}]}]}
        ,
        // ziglint-ignore: Z024 -- compact invalid JSON fixture
        \\{"version":1,"providers":[{"id":"bad","name":"Bad","base_url":"https://example.test/v1","authentication":"none","models":[{"id":"model","aliases":["same"],"profile":{"capabilities":["streaming","tools"],"settings":[],"context_window":100,"max_output_tokens":20}},{"id":"same","profile":{"capabilities":["streaming","tools"],"settings":[],"context_window":100,"max_output_tokens":20}}]}]}
        ,
    };
    for (cases) |contents| {
        try writeModels(&temporary, contents);
        var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
        defer snapshot.deinit();
        try std.testing.expectEqual(Diagnostic.invalid, snapshot.diagnostic().?);
        try std.testing.expectEqual(ModelConfig.builtin.providers.len, snapshot.view().providers.len);
        try std.testing.expect(snapshot.view().findProvider("bad") == null);
    }
}

test "global models read failures and document bounds retain built-ins" {
    var oversized_temporary = std.testing.tmpDir(.{});
    defer oversized_temporary.cleanup();
    const oversized = try std.testing.allocator.alloc(u8, max_document_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try writeModels(&oversized_temporary, oversized);
    var oversized_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var oversized_paths = try testPaths(&oversized_temporary, &oversized_buffer);
    defer oversized_paths.deinit();
    var oversized_snapshot = try load(std.testing.allocator, std.testing.io, &oversized_paths);
    defer oversized_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.too_large, oversized_snapshot.diagnostic().?);

    var unreadable_temporary = std.testing.tmpDir(.{});
    defer unreadable_temporary.cleanup();
    try unreadable_temporary.dir.createDirPath(std.testing.io, ".zi/agent/models.json");
    var unreadable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var unreadable_paths = try testPaths(&unreadable_temporary, &unreadable_buffer);
    defer unreadable_paths.deinit();
    var unreadable_snapshot = try load(std.testing.allocator, std.testing.io, &unreadable_paths);
    defer unreadable_snapshot.deinit();
    try std.testing.expectEqual(Diagnostic.unreadable, unreadable_snapshot.diagnostic().?);
}

fn loadAndDeinit(allocator: std.mem.Allocator, paths: *const ZiPaths) !void {
    var snapshot = try load(allocator, std.testing.io, paths);
    snapshot.deinit();
}

test "global models snapshot settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeModels(&temporary, valid_source);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadAndDeinit,
        .{&paths},
    );
}
