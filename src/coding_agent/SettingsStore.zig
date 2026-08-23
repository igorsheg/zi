const std = @import("std");
const builtin = @import("builtin");
const BoundedJson = @import("../BoundedJson.zig");
const Prompt = @import("Prompt.zig");
const PrivateFileStore = @import("PrivateFileStore.zig");
const ProjectTrust = @import("ProjectTrust.zig");
const ZiPaths = @import("ZiPaths.zig");

const settings_file_name = "settings.json";
const lock_file_name = ".settings.lock";
const max_document_bytes = 1024 * 1024;
const max_value_bytes = 32 * 1024;
const max_json_depth = 32;
const max_collection_items = 1024;
const max_identifier_bytes = 512;
const max_enabled_models = 256;
const max_thinking_levels = 256;
const max_retained_bytes = 128 * 1024;

const Boundary = PrivateFileStore.Boundary;
const Faults = PrivateFileStore.Faults;

pub const Scope = enum {
    global,
    project,
};

pub const DiagnosticKind = enum {
    missing,
    unreadable,
    too_large,
    invalid,
    unsafe,
};

pub const Diagnostic = struct {
    scope: Scope,
    kind: DiagnosticKind,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const ModelThinkingLevel = struct {
    model: []const u8,
    level: ThinkingLevel,
};

pub const LoadError = error{
    OutOfMemory,
    Cancelled,
};

pub const MutationError = error{
    OutOfMemory,
    InvalidGlobalSettings,
    UnsafeGlobalSettingsStorage,
    SettingsReadFailed,
    SettingsLockFailed,
    SettingsWriteFailed,
    CommitIndeterminate,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    default_provider: ?[]const u8,
    default_model: ?[]const u8,
    default_thinking_level: ?ThinkingLevel,
    model_thinking_levels: []const ModelThinkingLevel,
    enabled_models: ?[]const []const u8,
    diagnostics: []const Diagnostic,

    pub fn modelThinkingLevel(self: *const Snapshot, model: []const u8) ?ThinkingLevel {
        for (self.model_thinking_levels) |entry| {
            if (std.mem.eql(u8, entry.model, model)) return entry.level;
        }
        return null;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Source = struct {
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?ThinkingLevel = null,
    model_thinking_levels: ?[]const ModelThinkingLevel = null,
    enabled_models: ?[]const []const u8 = null,

    const empty: Source = .{};
};

const ParseError = error{
    OutOfMemory,
    InvalidSource,
};

const Mutation = struct {
    store: PrivateFileStore.Mutation,

    fn deinit(self: *Mutation) void {
        self.store.deinit();
        self.* = undefined;
    }

    fn setDefaultModel(
        self: *Mutation,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
    ) MutationError!void {
        validateIdentifier(provider) catch return error.InvalidGlobalSettings;
        validateIdentifier(model) catch return error.InvalidGlobalSettings;

        const maybe_source = self.store.readFileAlloc(
            allocator,
            settings_file_name,
            max_document_bytes + 1,
        ) catch |failure| return mapMutationReadFailure(failure);
        defer if (maybe_source) |source| allocator.free(source);
        const source = maybe_source orelse "{}";
        if (source.len > max_document_bytes) return error.InvalidGlobalSettings;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        var root = parseValue(allocator, owned, source) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSource => error.InvalidGlobalSettings,
        };
        _ = extractSource(owned, root) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSource => error.InvalidGlobalSettings,
        };
        switch (root) {
            .object => |*object| {
                object.put(owned, "defaultProvider", .{ .string = provider }) catch
                    return error.OutOfMemory;
                object.put(owned, "defaultModel", .{ .string = model }) catch
                    return error.OutOfMemory;
            },
            else => return error.InvalidGlobalSettings,
        }

        const encoded = try encodeValue(allocator, root);
        defer allocator.free(encoded);
        self.store.replace(settings_file_name, encoded) catch |failure|
            return mapMutationWriteFailure(failure);
    }
};

pub fn hasProjectSource(io: std.Io, paths: *const ZiPaths) error{Cancelled}!bool {
    const directory = std.Io.Dir.openDirAbsolute(io, paths.project, .{
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => false,
        error.Canceled => error.Cancelled,
        error.NotDir, error.SymLinkLoop => true,
        else => true,
    };
    defer directory.close(io);
    const file = directory.openFile(io, settings_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => false,
        error.Canceled => error.Cancelled,
        else => true,
    };
    file.close(io);
    return true;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    project_trust: ProjectTrust.Decision,
) LoadError!Snapshot {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var diagnostic_buffer: [2]Diagnostic = undefined;
    var diagnostic_count: usize = 0;
    const global = try loadGlobal(
        allocator,
        scratch.allocator(),
        io,
        paths,
        &diagnostic_buffer,
        &diagnostic_count,
    );
    var project: Source = .empty;
    if (project_trust == .trusted) {
        project = try loadProject(
            allocator,
            scratch.allocator(),
            io,
            paths,
            &diagnostic_buffer,
            &diagnostic_count,
        );
    }

    var effective_project = project;
    if (!mergedFits(global, effective_project)) {
        appendDiagnostic(&diagnostic_buffer, &diagnostic_count, .project, .invalid);
        effective_project = .empty;
    }
    return composeSnapshot(
        allocator,
        global,
        effective_project,
        diagnostic_buffer[0..diagnostic_count],
    );
}

pub fn setGlobalDefaultModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    provider: []const u8,
    model: []const u8,
) MutationError!void {
    try hardenExistingGlobalSettings(io, paths);
    var mutation = try beginMutationWithFaults(io, paths, .none());
    defer mutation.deinit();
    return mutation.setDefaultModel(allocator, provider, model);
}

fn hardenExistingGlobalSettings(io: std.Io, paths: *const ZiPaths) MutationError!void {
    if (comptime builtin.os.tag == .windows) return;
    var directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => {},
        error.NotDir, error.SymLinkLoop => error.UnsafeGlobalSettingsStorage,
        else => error.SettingsReadFailed,
    };
    defer directory.close(io);
    const file = directory.openFile(io, settings_file_name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => {},
        error.IsDir, error.NotDir, error.SymLinkLoop => error.UnsafeGlobalSettingsStorage,
        else => error.SettingsReadFailed,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.SettingsReadFailed;
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafeGlobalSettingsStorage;
    if (stat.permissions.toMode() & 0o777 == 0o600) return;
    file.setPermissions(io, PrivateFileStore.private_file_permissions) catch
        return error.SettingsWriteFailed;
}

fn beginMutationWithFaults(
    io: std.Io,
    paths: *const ZiPaths,
    faults: Faults,
) MutationError!Mutation {
    const store = PrivateFileStore.beginMutation(
        io,
        paths.home,
        paths.global_agent,
        lock_file_name,
        faults,
    ) catch |failure| return mapMutationBeginFailure(failure);
    return .{ .store = store };
}

fn loadGlobal(
    allocator: std.mem.Allocator,
    json_allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    diagnostics: *[2]Diagnostic,
    diagnostic_count: *usize,
) LoadError!Source {
    var directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.Canceled => error.Cancelled,
        error.FileNotFound => settledSource(diagnostics, diagnostic_count, .global, .missing),
        error.NotDir, error.SymLinkLoop => settledSource(diagnostics, diagnostic_count, .global, .unsafe),
        else => settledSource(diagnostics, diagnostic_count, .global, .unreadable),
    };
    defer directory.close(io);

    const outcome = try Prompt.BoundedTextFile.loadOptional(
        allocator,
        io,
        directory,
        settings_file_name,
        max_document_bytes,
    );
    return switch (outcome) {
        .missing => settledSource(diagnostics, diagnostic_count, .global, .missing),
        .too_large => settledSource(diagnostics, diagnostic_count, .global, .too_large),
        .invalid => settledSource(diagnostics, diagnostic_count, .global, .invalid),
        .unsafe => settledSource(diagnostics, diagnostic_count, .global, .unsafe),
        .unreadable => settledSource(diagnostics, diagnostic_count, .global, .unreadable),
        .loaded => |source| loaded: {
            defer allocator.free(source);
            break :loaded parseSource(allocator, json_allocator, source) catch |failure| switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSource => settledSource(diagnostics, diagnostic_count, .global, .invalid),
            };
        },
    };
}

fn loadProject(
    allocator: std.mem.Allocator,
    json_allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    diagnostics: *[2]Diagnostic,
    diagnostic_count: *usize,
) LoadError!Source {
    var directory = std.Io.Dir.openDirAbsolute(io, paths.project, .{
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.Canceled => error.Cancelled,
        error.FileNotFound, error.NotDir => settledSource(
            diagnostics,
            diagnostic_count,
            .project,
            .missing,
        ),
        error.SymLinkLoop => settledSource(diagnostics, diagnostic_count, .project, .unsafe),
        else => settledSource(diagnostics, diagnostic_count, .project, .unreadable),
    };
    defer directory.close(io);

    const outcome = try Prompt.BoundedTextFile.loadOptional(
        allocator,
        io,
        directory,
        settings_file_name,
        max_document_bytes,
    );
    return switch (outcome) {
        .missing => settledSource(diagnostics, diagnostic_count, .project, .missing),
        .too_large => settledSource(diagnostics, diagnostic_count, .project, .too_large),
        .invalid => settledSource(diagnostics, diagnostic_count, .project, .invalid),
        .unsafe => settledSource(diagnostics, diagnostic_count, .project, .unsafe),
        .unreadable => settledSource(diagnostics, diagnostic_count, .project, .unreadable),
        .loaded => |source| loaded: {
            defer allocator.free(source);
            break :loaded parseSource(allocator, json_allocator, source) catch |failure| switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSource => settledSource(
                    diagnostics,
                    diagnostic_count,
                    .project,
                    .invalid,
                ),
            };
        },
    };
}

fn settledSource(
    diagnostics: *[2]Diagnostic,
    diagnostic_count: *usize,
    scope: Scope,
    kind: DiagnosticKind,
) Source {
    appendDiagnostic(diagnostics, diagnostic_count, scope, kind);
    return .empty;
}

fn appendDiagnostic(
    diagnostics: *[2]Diagnostic,
    diagnostic_count: *usize,
    scope: Scope,
    kind: DiagnosticKind,
) void {
    std.debug.assert(diagnostic_count.* < diagnostics.len);
    diagnostics[diagnostic_count.*] = .{ .scope = scope, .kind = kind };
    diagnostic_count.* += 1;
}

fn parseSource(
    allocator: std.mem.Allocator,
    json_allocator: std.mem.Allocator,
    source: []const u8,
) ParseError!Source {
    const value = try parseValue(allocator, json_allocator, source);
    return extractSource(json_allocator, value);
}

fn parseValue(
    allocator: std.mem.Allocator,
    json_allocator: std.mem.Allocator,
    source: []const u8,
) ParseError!std.json.Value {
    BoundedJson.validate(allocator, source, .{
        .document_bytes = max_document_bytes,
        .value_bytes = max_value_bytes,
        .depth = max_json_depth,
        .collection_items = max_collection_items,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSource,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, json_allocator, source, .{
        .allocate = .alloc_always,
        .max_value_len = max_value_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSource,
    };
}

fn extractSource(allocator: std.mem.Allocator, value: std.json.Value) ParseError!Source {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSource,
    };
    const default_provider = try optionalIdentifier(&object, "defaultProvider");
    const default_model = try optionalIdentifier(&object, "defaultModel");
    const default_thinking_level = try optionalThinkingLevel(&object, "defaultThinkingLevel");
    const model_thinking_levels = try optionalThinkingLevels(
        allocator,
        &object,
        "modelThinkingLevels",
    );
    const enabled_models = try optionalIdentifiers(allocator, &object, "enabledModels");

    const source: Source = .{
        .default_provider = default_provider,
        .default_model = default_model,
        .default_thinking_level = default_thinking_level,
        .model_thinking_levels = model_thinking_levels,
        .enabled_models = enabled_models,
    };
    if (!sourceFits(source)) return error.InvalidSource;
    return source;
}

fn optionalIdentifier(
    object: *const std.json.ObjectMap,
    name: []const u8,
) ParseError!?[]const u8 {
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidSource,
    };
    try validateIdentifier(text);
    return text;
}

fn optionalThinkingLevel(
    object: *const std.json.ObjectMap,
    name: []const u8,
) ParseError!?ThinkingLevel {
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidSource,
    };
    return std.meta.stringToEnum(ThinkingLevel, text) orelse error.InvalidSource;
}

fn optionalThinkingLevels(
    allocator: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    name: []const u8,
) ParseError!?[]const ModelThinkingLevel {
    const value = object.get(name) orelse return null;
    const map = switch (value) {
        .object => |map| map,
        else => return error.InvalidSource,
    };
    if (map.count() > max_thinking_levels) return error.InvalidSource;
    const entries = try allocator.alloc(ModelThinkingLevel, map.count());
    const keys = map.keys();
    const values = map.values();
    for (keys, values, entries) |key, level_value, *entry| {
        try validateIdentifier(key);
        const level_text = switch (level_value) {
            .string => |text| text,
            else => return error.InvalidSource,
        };
        entry.* = .{
            .model = key,
            .level = std.meta.stringToEnum(ThinkingLevel, level_text) orelse
                return error.InvalidSource,
        };
    }
    return entries;
}

fn optionalIdentifiers(
    allocator: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    name: []const u8,
) ParseError!?[]const []const u8 {
    const value = object.get(name) orelse return null;
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidSource,
    };
    if (array.items.len > max_enabled_models) return error.InvalidSource;
    const entries = try allocator.alloc([]const u8, array.items.len);
    for (array.items, entries) |item, *entry| {
        const text = switch (item) {
            .string => |text| text,
            else => return error.InvalidSource,
        };
        try validateIdentifier(text);
        entry.* = text;
    }
    return entries;
}

fn validateIdentifier(value: []const u8) ParseError!void {
    if (value.len == 0 or value.len > max_identifier_bytes or
        !std.unicode.utf8ValidateSlice(value) or std.mem.findScalar(u8, value, 0) != null)
    {
        return error.InvalidSource;
    }
    for (value) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return error.InvalidSource;
    }
}

fn sourceFits(source: Source) bool {
    if (source.model_thinking_levels) |entries| {
        if (entries.len > max_thinking_levels) return false;
    }
    if (source.enabled_models) |entries| {
        if (entries.len > max_enabled_models) return false;
    }
    return retainedBytes(source) != null;
}

fn mergedFits(global: Source, project: Source) bool {
    const global_entries = global.model_thinking_levels orelse &.{};
    const project_entries = project.model_thinking_levels orelse &.{};
    var merged_count = global_entries.len;
    for (project_entries) |entry| {
        if (findThinkingLevel(global_entries, entry.model) == null) merged_count += 1;
    }
    if (merged_count > max_thinking_levels) return false;

    const effective: Source = .{
        .default_provider = project.default_provider orelse global.default_provider,
        .default_model = project.default_model orelse global.default_model,
        .default_thinking_level = project.default_thinking_level orelse global.default_thinking_level,
        .enabled_models = project.enabled_models orelse global.enabled_models,
    };
    var total = retainedBytes(effective) orelse return false;
    for (global_entries) |entry| {
        total = addRetained(total, entry.model.len) orelse return false;
    }
    for (project_entries) |entry| {
        if (findThinkingLevel(global_entries, entry.model) == null) {
            total = addRetained(total, entry.model.len) orelse return false;
        }
    }
    return true;
}

fn retainedBytes(source: Source) ?usize {
    var total: usize = 0;
    if (source.default_provider) |value| total = addRetained(total, value.len) orelse return null;
    if (source.default_model) |value| total = addRetained(total, value.len) orelse return null;
    if (source.enabled_models) |entries| {
        for (entries) |entry| total = addRetained(total, entry.len) orelse return null;
    }
    if (source.model_thinking_levels) |entries| {
        for (entries) |entry| total = addRetained(total, entry.model.len) orelse return null;
    }
    return total;
}

fn addRetained(total: usize, amount: usize) ?usize {
    const next = std.math.add(usize, total, amount) catch return null;
    if (next > max_retained_bytes) return null;
    return next;
}

fn composeSnapshot(
    allocator: std.mem.Allocator,
    global: Source,
    project: Source,
    diagnostics: []const Diagnostic,
) error{OutOfMemory}!Snapshot {
    std.debug.assert(mergedFits(global, project));
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();

    const default_provider = try copyOptional(owned, project.default_provider orelse global.default_provider);
    const default_model = try copyOptional(owned, project.default_model orelse global.default_model);
    const enabled_models = try copyOptionalIdentifiers(
        owned,
        project.enabled_models orelse global.enabled_models,
    );
    const model_thinking_levels = try mergeThinkingLevels(
        owned,
        global.model_thinking_levels orelse &.{},
        project.model_thinking_levels orelse &.{},
    );
    const owned_diagnostics = try owned.dupe(Diagnostic, diagnostics);
    return .{
        .arena = arena,
        .default_provider = default_provider,
        .default_model = default_model,
        .default_thinking_level = project.default_thinking_level orelse global.default_thinking_level,
        .model_thinking_levels = model_thinking_levels,
        .enabled_models = enabled_models,
        .diagnostics = owned_diagnostics,
    };
}

fn copyOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) error{OutOfMemory}!?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn copyOptionalIdentifiers(
    allocator: std.mem.Allocator,
    maybe_values: ?[]const []const u8,
) error{OutOfMemory}!?[]const []const u8 {
    const values = maybe_values orelse return null;
    const copied = try allocator.alloc([]const u8, values.len);
    for (values, copied) |value, *entry| entry.* = try allocator.dupe(u8, value);
    return copied;
}

fn mergeThinkingLevels(
    allocator: std.mem.Allocator,
    global: []const ModelThinkingLevel,
    project: []const ModelThinkingLevel,
) error{OutOfMemory}![]const ModelThinkingLevel {
    var count = global.len;
    for (project) |entry| {
        if (findThinkingLevel(global, entry.model) == null) count += 1;
    }
    const merged = try allocator.alloc(ModelThinkingLevel, count);
    var cursor: usize = 0;
    for (global) |entry| {
        const effective = if (findThinkingLevel(project, entry.model)) |index| project[index] else entry;
        merged[cursor] = .{
            .model = try allocator.dupe(u8, effective.model),
            .level = effective.level,
        };
        cursor += 1;
    }
    for (project) |entry| {
        if (findThinkingLevel(global, entry.model) != null) continue;
        merged[cursor] = .{
            .model = try allocator.dupe(u8, entry.model),
            .level = entry.level,
        };
        cursor += 1;
    }
    return merged;
}

fn findThinkingLevel(entries: []const ModelThinkingLevel, model: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.model, model)) return index;
    }
    return null;
}

fn encodeValue(allocator: std.mem.Allocator, value: std.json.Value) MutationError![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.write(value) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
    if (encoded.len > max_document_bytes) {
        allocator.free(encoded);
        return error.InvalidGlobalSettings;
    }
    return encoded;
}

fn mapMutationBeginFailure(failure: PrivateFileStore.Error) MutationError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeGlobalSettingsStorage,
        else => error.SettingsLockFailed,
    };
}

fn mapMutationReadFailure(failure: PrivateFileStore.Error) MutationError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeGlobalSettingsStorage,
        else => error.SettingsReadFailed,
    };
}

fn mapMutationWriteFailure(failure: PrivateFileStore.Error) MutationError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeGlobalSettingsStorage,
        error.CommitIndeterminate => error.CommitIndeterminate,
        else => error.SettingsWriteFailed,
    };
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn testPaths(temporary: *std.testing.TmpDir, buffer: []u8) !ZiPaths {
    const root = try temporaryPath(temporary, buffer);
    return ZiPaths.init(std.testing.allocator, root, root);
}

fn writeGlobal(paths: *const ZiPaths, contents: []const u8) !void {
    var store = try PrivateFileStore.beginMutation(
        std.testing.io,
        paths.home,
        paths.global_agent,
        ".test-settings.lock",
        .none(),
    );
    defer store.deinit();
    try store.replace(settings_file_name, contents);
}

fn writeProject(temporary: *std.testing.TmpDir, contents: []const u8) !void {
    try temporary.dir.createDirPath(std.testing.io, ".zi");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/settings.json",
        .data = contents,
    });
}

fn diagnosticFor(snapshot: *const Snapshot, scope: Scope) ?DiagnosticKind {
    for (snapshot.diagnostics) |diagnostic| {
        if (diagnostic.scope == scope) return diagnostic.kind;
    }
    return null;
}

test "project settings source detection treats unsafe roots as present" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &root_buffer);
    defer paths.deinit();

    try std.testing.expect(!try hasProjectSource(std.testing.io, &paths));
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/settings.json",
        .data = "{}",
    });
    try std.testing.expect(try hasProjectSource(std.testing.io, &paths));

    try temporary.dir.deleteTree(std.testing.io, ".zi");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = ".zi", .data = "unsafe" });
    try std.testing.expect(try hasProjectSource(std.testing.io, &paths));
}

test "missing settings files contribute bounded diagnostics" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths, .trusted);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.default_provider == null);
    try std.testing.expect(snapshot.default_model == null);
    try std.testing.expectEqual(@as(usize, 2), snapshot.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.missing, diagnosticFor(&snapshot, .global).?);
    try std.testing.expectEqual(DiagnosticKind.missing, diagnosticFor(&snapshot, .project).?);
}

test "valid global settings are owned by the snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    try writeGlobal(&paths,
        \\{
        \\  "defaultProvider": "openai",
        \\  "defaultModel": "gpt-5",
        \\  "defaultThinkingLevel": "high",
        \\  "modelThinkingLevels": {"openai/gpt-5": "xhigh"},
        \\  "enabledModels": ["openai/*", "anthropic/claude-*"],
        \\  "theme": "dark"
        \\}
    );

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    try writeGlobal(&paths, "{}");
    paths.deinit();
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("openai", snapshot.default_provider.?);
    try std.testing.expectEqualStrings("gpt-5", snapshot.default_model.?);
    try std.testing.expectEqual(ThinkingLevel.high, snapshot.default_thinking_level.?);
    try std.testing.expectEqual(ThinkingLevel.xhigh, snapshot.modelThinkingLevel("openai/gpt-5").?);
    try std.testing.expectEqualStrings("openai/*", snapshot.enabled_models.?[0]);
    try std.testing.expectEqual(@as(usize, 0), snapshot.diagnostics.len);
}

test "trusted project settings replace values and merge model thinking levels" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths,
        \\{"defaultProvider":"global","defaultModel":"global-model",
        \\ "defaultThinkingLevel":"medium",
        \\ "modelThinkingLevels":{"shared/model":"low","global/model":"high"},
        \\ "enabledModels":["global/*"]}
    );
    try writeProject(&temporary,
        \\{"defaultProvider":"project","defaultThinkingLevel":"max",
        \\ "modelThinkingLevels":{"shared/model":"xhigh","project/model":"minimal"},
        \\ "enabledModels":["project/*","project/other"]}
    );

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths, .trusted);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("project", snapshot.default_provider.?);
    try std.testing.expectEqualStrings("global-model", snapshot.default_model.?);
    try std.testing.expectEqual(ThinkingLevel.max, snapshot.default_thinking_level.?);
    try std.testing.expectEqualStrings("project/*", snapshot.enabled_models.?[0]);
    try std.testing.expectEqual(@as(usize, 2), snapshot.enabled_models.?.len);
    try std.testing.expectEqual(ThinkingLevel.xhigh, snapshot.modelThinkingLevel("shared/model").?);
    try std.testing.expectEqual(ThinkingLevel.high, snapshot.modelThinkingLevel("global/model").?);
    try std.testing.expectEqual(ThinkingLevel.minimal, snapshot.modelThinkingLevel("project/model").?);
    try std.testing.expectEqual(@as(usize, 0), snapshot.diagnostics.len);
}

test "untrusted project settings are not read" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths, "{\"defaultModel\":\"global\"}");
    try temporary.dir.createDirPath(std.testing.io, ".zi/settings.json");

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("global", snapshot.default_model.?);
    try std.testing.expect(diagnosticFor(&snapshot, .project) == null);
}

test "malformed scopes fall back without destroying the other scope" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths, "{ malformed");
    try writeProject(&temporary, "{\"defaultModel\":\"project\"}");

    var project_survives = try load(std.testing.allocator, std.testing.io, &paths, .trusted);
    try std.testing.expectEqualStrings("project", project_survives.default_model.?);
    try std.testing.expectEqual(DiagnosticKind.invalid, diagnosticFor(&project_survives, .global).?);
    project_survives.deinit();

    try writeGlobal(&paths, "{\"defaultModel\":\"global\"}");
    try writeProject(&temporary, "{\"enabledModels\":[1]}");
    var global_survives = try load(std.testing.allocator, std.testing.io, &paths, .trusted);
    defer global_survives.deinit();
    try std.testing.expectEqualStrings("global", global_survives.default_model.?);
    try std.testing.expectEqual(DiagnosticKind.invalid, diagnosticFor(&global_survives, .project).?);
}

fn expectInvalidSource(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidSource,
        parseSource(std.testing.allocator, arena.allocator(), source),
    );
}

fn encodeEnabledModels(allocator: std.mem.Allocator, count: usize, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("enabledModels") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (0..count) |_| json.write(value) catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn encodeThinkingLevels(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("modelThinkingLevels") catch return error.OutOfMemory;
    json.beginObject() catch return error.OutOfMemory;
    for (0..count) |index| {
        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "provider/model-{d}", .{index});
        json.objectField(key) catch return error.OutOfMemory;
        json.write("low") catch return error.OutOfMemory;
    }
    json.endObject() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

test "settings parsing enforces independent bounds" {
    const overlong_identifier = "a" ** (max_identifier_bytes + 1);
    const overlong_source = "{\"defaultModel\":\"" ++ overlong_identifier ++ "\"}";
    try expectInvalidSource(overlong_source);

    const too_many_enabled = try encodeEnabledModels(
        std.testing.allocator,
        max_enabled_models + 1,
        "model",
    );
    defer std.testing.allocator.free(too_many_enabled);
    try expectInvalidSource(too_many_enabled);

    const too_many_levels = try encodeThinkingLevels(std.testing.allocator, max_thinking_levels + 1);
    defer std.testing.allocator.free(too_many_levels);
    try expectInvalidSource(too_many_levels);

    const maximum_identifier = "m" ** max_identifier_bytes;
    const too_many_retained = try encodeEnabledModels(
        std.testing.allocator,
        max_enabled_models,
        maximum_identifier,
    );
    defer std.testing.allocator.free(too_many_retained);
    var retained_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer retained_output.deinit();
    retained_output.writer.writeAll("{\"defaultProvider\":\"p\",\"enabledModels\":") catch
        return error.OutOfMemory;
    const enabled_value_start = std.mem.findScalar(u8, too_many_retained, '[').?;
    retained_output.writer.writeAll(too_many_retained[enabled_value_start .. too_many_retained.len - 1]) catch
        return error.OutOfMemory;
    retained_output.writer.writeByte('}') catch return error.OutOfMemory;
    const retained_source = try retained_output.toOwnedSlice();
    defer std.testing.allocator.free(retained_source);
    try expectInvalidSource(retained_source);

    const oversized_document = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(oversized_document);
    @memset(oversized_document, ' ');
    try expectInvalidSource(oversized_document);
}

test "global default model mutation preserves unknown fields" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths,
        \\{"defaultProvider":"old","defaultModel":"old-model",
        \\ "theme":"custom","future":{"nested":[1,true,"value"]},
        \\ "enabledModels":["old/*"]}
    );

    try setGlobalDefaultModel(
        std.testing.allocator,
        std.testing.io,
        &paths,
        "new-provider",
        "new-model",
    );
    const encoded = try PrivateFileStore.readFileAlloc(
        std.testing.allocator,
        std.testing.io,
        paths.home,
        paths.global_agent,
        settings_file_name,
        max_document_bytes,
    );
    defer std.testing.allocator.free(encoded.?);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded.?, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("new-provider", object.get("defaultProvider").?.string);
    try std.testing.expectEqualStrings("new-model", object.get("defaultModel").?.string);
    try std.testing.expectEqualStrings("custom", object.get("theme").?.string);
    try std.testing.expectEqualStrings(
        "value",
        object.get("future").?.object.get("nested").?.array.items[2].string,
    );
    try std.testing.expectEqualStrings("old/*", object.get("enabledModels").?.array.items[0].string);
}

test "global settings mutation distinguishes determinate and indeterminate failures" {
    const Fault = struct {
        const Self = @This();
        fail_at: Boundary,

        fn boundary(context: *anyopaque, point: Boundary) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (point == self.fail_at) return error.Injected;
        }

        fn faults(self: *Self) Faults {
            return .{ .context = self, .boundary_fn = boundary };
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths, "{\"defaultProvider\":\"old\",\"defaultModel\":\"old\"}");

    var before_replace: Fault = .{ .fail_at = .after_write };
    var failed = try beginMutationWithFaults(std.testing.io, &paths, before_replace.faults());
    try std.testing.expectError(
        error.SettingsWriteFailed,
        failed.setDefaultModel(std.testing.allocator, "new", "not-published"),
    );
    failed.deinit();
    var original = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    try std.testing.expectEqualStrings("old", original.default_model.?);
    original.deinit();

    var after_replace: Fault = .{ .fail_at = .after_replace };
    var indeterminate = try beginMutationWithFaults(std.testing.io, &paths, after_replace.faults());
    try std.testing.expectError(
        error.CommitIndeterminate,
        indeterminate.setDefaultModel(std.testing.allocator, "new", "published"),
    );
    indeterminate.deinit();
    var published = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    defer published.deinit();
    try std.testing.expectEqualStrings("published", published.default_model.?);
}

test "global settings reads do not require secret-file permissions" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
    try temporary.dir.createDir(
        std.testing.io,
        ".zi/agent",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const file = try temporary.dir.createFile(std.testing.io, ".zi/agent/settings.json", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    try file.writePositionalAll(std.testing.io, "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.6-sol\"}", 0);
    file.close(std.testing.io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    try std.testing.expectEqualStrings("openai", snapshot.default_provider.?);
    snapshot.deinit();

    try setGlobalDefaultModel(
        std.testing.allocator,
        std.testing.io,
        &paths,
        "openai-codex",
        "gpt-5.6-terra",
    );
    const stat = try temporary.dir.statFile(
        std.testing.io,
        ".zi/agent/settings.json",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var updated = try load(std.testing.allocator, std.testing.io, &paths, .untrusted);
    defer updated.deinit();
    try std.testing.expectEqualStrings("openai-codex", updated.default_provider.?);
}

fn decodeAndDeinit(allocator: std.mem.Allocator) !void {
    const source_text =
        \\{"defaultProvider":"provider","defaultModel":"model",
        \\ "defaultThinkingLevel":"high",
        \\ "modelThinkingLevels":{"provider/model":"xhigh"},
        \\ "enabledModels":["provider/*"]}
    ;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const source = try parseSource(allocator, scratch.allocator(), source_text);
    var snapshot = try composeSnapshot(allocator, source, .empty, &.{});
    snapshot.deinit();
}

test "settings decoding settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeAndDeinit, .{});
}

fn loadAndDeinit(allocator: std.mem.Allocator, paths: *const ZiPaths) !void {
    var snapshot = try load(allocator, std.testing.io, paths, .trusted);
    snapshot.deinit();
}

test "settings loading settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths = try testPaths(&temporary, &path_buffer);
    defer paths.deinit();
    try writeGlobal(&paths, "{\"defaultModel\":\"global\"}");
    try writeProject(&temporary, "{\"defaultProvider\":\"project\"}");

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadAndDeinit,
        .{&paths},
    );
}
