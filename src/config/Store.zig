const std = @import("std");
const Document = @import("Document.zig");

const Store = @This();

pub const default_sentinel = "(default)";

pub const Setting = struct {
    env_var: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    keep_empty: bool = false,
};

/// Borrowed setting metadata. The implementation and returned strings must
/// outlive every Store call.
pub const SettingRegistry = struct {
    context: *const anyopaque,
    find_fn: *const fn (*const anyopaque, []const u8) ?Setting,

    pub fn find(self: SettingRegistry, key: []const u8) ?Setting {
        return self.find_fn(self.context, key);
    }

    pub fn from(implementation: anytype) SettingRegistry {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("SettingRegistry.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn find(context: *const anyopaque, key: []const u8) ?Setting {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.find(key);
            }
        };
        return .{ .context = implementation, .find_fn = Adapter.find };
    }
};

/// Borrowed environment view. It deliberately has no ambient getenv fallback.
pub const Environment = struct {
    context: *const anyopaque,
    get_fn: *const fn (*const anyopaque, []const u8) ?[]const u8,

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        return self.get_fn(self.context, name);
    }

    pub fn from(implementation: anytype) Environment {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Environment.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn get(context: *const anyopaque, name: []const u8) ?[]const u8 {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.get(name);
            }
        };
        return .{ .context = implementation, .get_fn = Adapter.get };
    }
};

/// Canonical IDs are borrowed only until the next callback. Store copies the
/// first result before requesting the second. Omit this collaborator for exact
/// byte identity.
pub const ProviderCanonicalizer = struct {
    context: *const anyopaque,
    canonical_fn: *const fn (*const anyopaque, []const u8) []const u8,

    pub fn canonical(self: ProviderCanonicalizer, id: []const u8) []const u8 {
        return self.canonical_fn(self.context, id);
    }

    pub fn from(implementation: anytype) ProviderCanonicalizer {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("ProviderCanonicalizer.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn canonical(context: *const anyopaque, id: []const u8) []const u8 {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.canonical(id);
            }
        };
        return .{ .context = implementation, .canonical_fn = Adapter.canonical };
    }
};

pub const Source = enum {
    run,
    conversation,
    env,
    state,
    config,
    default,

    pub fn label(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// Allocator-owned, move-only resolution result. Call deinit exactly once.
pub const Result = struct {
    value: ?[]u8,
    source: Source,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.value) |value| {
            @memset(value, 0);
            allocator.free(value);
        }
        self.* = undefined;
    }
};

pub const Options = struct {
    file: ?*const Document = null,
    state: ?*const Document = null,
    conversation: ?*const Document = null,
    run: ?*const Document = null,
    registry: SettingRegistry,
    environment: Environment,
    provider_canonicalizer: ?ProviderCanonicalizer = null,
};

file: ?*const Document,
state: ?*const Document,
conversation: ?*const Document,
run: ?*const Document,
registry: SettingRegistry,
environment: Environment,
provider_canonicalizer: ?ProviderCanonicalizer,

/// Store borrows every Document and collaborator for its entire lifetime.
pub fn init(options: Options) Store {
    return .{
        .file = options.file,
        .state = options.state,
        .conversation = options.conversation,
        .run = options.run,
        .registry = options.registry,
        .environment = options.environment,
        .provider_canonicalizer = options.provider_canonicalizer,
    };
}

pub fn read(self: Store, allocator: std.mem.Allocator, key: []const u8) !Result {
    const setting = self.registry.find(key);
    return self.resolve(allocator, key, .{
        .skip_empty = if (setting) |row| !row.keep_empty else false,
    });
}

pub fn readBelowRun(self: Store, allocator: std.mem.Allocator, key: []const u8) !Result {
    const setting = self.registry.find(key);
    return self.resolve(allocator, key, .{
        .skip_empty = if (setting) |row| !row.keep_empty else false,
        .skip_run = true,
    });
}

pub fn readNonempty(self: Store, allocator: std.mem.Allocator, key: []const u8) !Result {
    return self.resolve(allocator, key, .{ .skip_empty = true });
}

/// Resolves a provider-bound key as if `provider` were the active run-tier
/// provider. The explicit provider governs conversation/state/config bindings;
/// the run tier remains intentionally unbound.
pub fn readForProvider(
    self: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
    provider: []const u8,
) !Result {
    const setting = self.registry.find(key);
    return self.resolve(allocator, key, .{
        .skip_empty = if (setting) |row| !row.keep_empty else false,
        .active_provider = provider,
    });
}

/// Reports an explicit value of any JSON type or configured environment value.
/// Registry defaults do not count.
pub fn hasExplicit(self: Store, key: []const u8) bool {
    if (self.run) |document| if (document.getRaw(key) != null) return true;
    if (self.conversation) |document| if (document.getRaw(key) != null) return true;
    if (self.registry.find(key)) |setting| if (setting.env_var) |name| {
        if (self.environment.get(name) != null) return true;
    };
    if (self.state) |document| if (document.getRaw(key) != null) return true;
    if (self.file) |document| if (document.getRaw(key) != null) return true;
    return false;
}

pub fn defaultValue(self: Store, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const setting = self.registry.find(key) orelse return null;
    const value = setting.default_value orelse return null;
    return allocator.dupe(u8, value);
}

/// Returns a borrowed verbatim JSON node. State wins over the config file.
pub fn rawNode(self: Store, key: []const u8) ?*const std.json.Value {
    if (self.state) |state| if (state.getRaw(key)) |node| return node;
    if (self.file) |file| return file.getRaw(key);
    return null;
}

/// Returns owned names in config-file order followed by unseen state names.
pub fn objectKeys(
    self: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
) ![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |name| allocator.free(name);
        result.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    if (self.file) |file| try appendDocumentKeys(allocator, file, key, &result, &seen);
    if (self.state) |state| try appendDocumentKeys(allocator, state, key, &result, &seen);
    return result.toOwnedSlice(allocator);
}

pub fn freeObjectKeys(allocator: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |key| allocator.free(key);
    allocator.free(keys);
}

const ResolveOptions = struct {
    skip_empty: bool,
    skip_run: bool = false,
    active_provider: ?[]const u8 = null,
};

fn resolve(
    self: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
    options: ResolveOptions,
) error{OutOfMemory}!Result {
    const setting = self.registry.find(key);

    if (!options.skip_run) {
        if (try self.documentCandidate(
            allocator,
            self.run,
            key,
            options.skip_empty,
            false,
            options.active_provider,
        )) |value| {
            return self.finish(allocator, value, .run, setting);
        }
    }
    if (try self.documentCandidate(
        allocator,
        self.conversation,
        key,
        options.skip_empty,
        true,
        options.active_provider,
    )) |value| return self.finish(allocator, value, .conversation, setting);

    if (setting) |row| if (row.env_var) |name| {
        if (self.environment.get(name)) |borrowed| {
            if (!options.skip_empty or borrowed.len != 0) {
                const value = try allocator.dupe(u8, borrowed);
                return self.finish(allocator, value, .env, setting);
            }
        }
    };

    if (try self.documentCandidate(
        allocator,
        self.state,
        key,
        options.skip_empty,
        true,
        options.active_provider,
    )) |value| {
        return self.finish(allocator, value, .state, setting);
    }
    if (try self.documentCandidate(
        allocator,
        self.file,
        key,
        options.skip_empty,
        true,
        options.active_provider,
    )) |value| {
        return self.finish(allocator, value, .config, setting);
    }
    return defaultResult(allocator, setting);
}

fn documentCandidate(
    self: Store,
    allocator: std.mem.Allocator,
    document: ?*const Document,
    key: []const u8,
    skip_empty: bool,
    check_binding: bool,
    active_provider: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    const tier = document orelse return null;
    const value = try tier.getString(allocator, key) orelse return null;
    errdefer allocator.free(value);
    if (skip_empty and value.len == 0) {
        allocator.free(value);
        return null;
    }
    if (check_binding and isProviderBoundKey(key) and
        !try self.providerBindingAllows(allocator, tier, active_provider))
    {
        allocator.free(value);
        return null;
    }
    return value;
}

fn providerBindingAllows(
    self: Store,
    allocator: std.mem.Allocator,
    tier: *const Document,
    active_provider: ?[]const u8,
) error{OutOfMemory}!bool {
    const bound = try tier.getString(allocator, "provider") orelse return true;
    defer allocator.free(bound);
    if (bound.len == 0) return true;

    var resolved_active: ?Result = null;
    defer if (resolved_active) |*value| value.deinit(allocator);
    const active_value = active_provider orelse blk: {
        resolved_active = try self.resolve(allocator, "provider", .{ .skip_empty = false });
        break :blk resolved_active.?.value orelse return false;
    };
    if (active_value.len == 0) return false;

    if (self.provider_canonicalizer) |canonicalizer| {
        const left_borrowed = canonicalizer.canonical(active_value);
        const left = try allocator.dupe(u8, left_borrowed);
        defer allocator.free(left);
        const right = canonicalizer.canonical(bound);
        return std.mem.eql(u8, left, right);
    }
    return std.mem.eql(u8, active_value, bound);
}

fn finish(
    self: Store,
    allocator: std.mem.Allocator,
    value: []u8,
    source: Source,
    setting: ?Setting,
) !Result {
    _ = self;
    if (!std.mem.eql(u8, value, default_sentinel)) return .{ .value = value, .source = source };
    allocator.free(value);
    const default_value = if (setting) |row| row.default_value else null;
    return .{
        .value = if (default_value) |text| try allocator.dupe(u8, text) else null,
        .source = source,
    };
}

fn defaultResult(allocator: std.mem.Allocator, setting: ?Setting) !Result {
    const value = if (setting) |row| row.default_value else null;
    return .{
        .value = if (value) |text| try allocator.dupe(u8, text) else null,
        .source = .default,
    };
}

fn isProviderBoundKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "model") or std.mem.eql(u8, key, "effort");
}

fn appendDocumentKeys(
    allocator: std.mem.Allocator,
    document: *const Document,
    key: []const u8,
    result: *std.ArrayList([]u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const keys = try document.objectKeys(allocator, key);
    defer Document.freeObjectKeys(allocator, keys);
    for (keys) |name| {
        if (seen.contains(name)) continue;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try seen.put(allocator, owned, {});
        errdefer _ = seen.remove(owned);
        try result.append(allocator, owned);
    }
}

const TestRegistry = struct {
    rows: []const TestRow,

    const TestRow = struct { key: []const u8, setting: Setting };

    fn find(self: *const TestRegistry, key: []const u8) ?Setting {
        for (self.rows) |row| if (std.mem.eql(u8, row.key, key)) return row.setting;
        return null;
    }
};

const TestEnvironment = struct {
    entries: []const Entry,

    const Entry = struct { name: []const u8, value: []const u8 };

    fn get(self: *const TestEnvironment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }
};

fn expectRead(store: Store, key: []const u8, expected: ?[]const u8, source: Source) !void {
    var result = try store.read(std.testing.allocator, key);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(source, result.source);
    if (expected) |text| {
        try std.testing.expect(result.value != null);
        try std.testing.expectEqualStrings(text, result.value.?);
    } else try std.testing.expect(result.value == null);
}

fn parseTestDocument(bytes: []const u8) !Document {
    return Document.parse(std.testing.allocator, bytes, .{});
}

test "tier precedence and below-run reads" {
    var file = try parseTestDocument("{\"x\":\"file\"}");
    defer file.deinit();
    var state = try parseTestDocument("{\"x\":\"state\"}");
    defer state.deinit();
    var conversation = try parseTestDocument("{\"x\":\"conversation\"}");
    defer conversation.deinit();
    var run = try parseTestDocument("{\"x\":\"run\"}");
    defer run.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{.{
        .key = "x",
        .setting = .{ .env_var = "X", .default_value = "default" },
    }} };
    const environment_impl: TestEnvironment = .{ .entries = &.{.{ .name = "X", .value = "env" }} };
    const store = Store.init(.{
        .file = &file,
        .state = &state,
        .conversation = &conversation,
        .run = &run,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
    });
    try expectRead(store, "x", "run", .run);
    var below = try store.readBelowRun(std.testing.allocator, "x");
    defer below.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("conversation", below.value.?);
    try std.testing.expectEqual(Source.conversation, below.source);
}

test "environment precedes state and file and defaults remain last" {
    var file = try parseTestDocument("{\"x\":\"file\"}");
    defer file.deinit();
    var state = try parseTestDocument("{\"x\":\"state\"}");
    defer state.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "x", .setting = .{ .env_var = "X", .default_value = "default" } },
        .{ .key = "y", .setting = .{ .default_value = "default-y" } },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{.{ .name = "X", .value = "env" }} };
    const store = Store.init(.{
        .file = &file,
        .state = &state,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
    });
    try expectRead(store, "x", "env", .env);
    try expectRead(store, "y", "default-y", .default);
    try expectRead(store, "unknown", null, .default);
}

test "keep-empty, nonempty read, and default sentinel" {
    var run = try parseTestDocument(
        "{\"kept\":\"\",\"skipped\":\"\",\"sentinel\":\"(default)\",\"none\":\"(default)\"}",
    );
    defer run.deinit();
    var file = try parseTestDocument("{\"kept\":\"lower\",\"skipped\":\"lower\"}");
    defer file.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "kept", .setting = .{ .keep_empty = true } },
        .{ .key = "skipped", .setting = .{} },
        .{ .key = "sentinel", .setting = .{ .default_value = "factory" } },
        .{ .key = "none", .setting = .{} },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    const store = Store.init(.{
        .file = &file,
        .run = &run,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
    });
    try expectRead(store, "kept", "", .run);
    try expectRead(store, "skipped", "lower", .config);
    try expectRead(store, "sentinel", "factory", .run);
    try expectRead(store, "none", null, .run);
    var nonempty = try store.readNonempty(std.testing.allocator, "kept");
    defer nonempty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("lower", nonempty.value.?);
}

const AliasCanonicalizer = struct {
    fn canonical(_: *const AliasCanonicalizer, id: []const u8) []const u8 {
        return if (std.mem.eql(u8, id, "llama.cpp")) "llamacpp" else id;
    }
};

test "provider-bound model and effort use canonical aliases" {
    var file = try parseTestDocument(
        "{\"provider\":\"llama.cpp\",\"model\":\"file-model\",\"effort\":\"high\"}",
    );
    defer file.deinit();
    var state = try parseTestDocument(
        "{\"provider\":\"other\",\"model\":\"wrong-model\",\"effort\":\"low\"}",
    );
    defer state.deinit();
    var run = try parseTestDocument("{\"provider\":\"llamacpp\"}");
    defer run.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "provider", .setting = .{} },
        .{ .key = "model", .setting = .{ .default_value = "default-model" } },
        .{ .key = "effort", .setting = .{} },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    const aliases: AliasCanonicalizer = .{};
    const store = Store.init(.{
        .file = &file,
        .state = &state,
        .run = &run,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
        .provider_canonicalizer = .from(&aliases),
    });
    try expectRead(store, "model", "file-model", .config);
    try expectRead(store, "effort", "high", .config);
}

test "conversation binding applies but run binding is intentionally ignored" {
    var conversation = try parseTestDocument(
        "{\"provider\":\"other\",\"model\":\"conversation-model\"}",
    );
    defer conversation.deinit();
    var run = try parseTestDocument("{\"provider\":\"active\",\"model\":\"run-model\"}");
    defer run.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "provider", .setting = .{} },
        .{ .key = "model", .setting = .{ .default_value = "default-model" } },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    const store = Store.init(.{
        .conversation = &conversation,
        .run = &run,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
    });
    try expectRead(store, "model", "run-model", .run);
    var below = try store.readBelowRun(std.testing.allocator, "model");
    defer below.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("default-model", below.value.?);
    try std.testing.expectEqual(Source.default, below.source);
}

test "raw node is state-first and object keys are file-first union" {
    var file = try parseTestDocument(
        "{\"block\":{\"one\":1,\"shared\":1},\"block.flat\":true}",
    );
    defer file.deinit();
    var state = try parseTestDocument(
        "{\"block\":{\"shared\":2,\"two\":2},\"block.last.value\":3}",
    );
    defer state.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{} };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    const store = Store.init(.{
        .file = &file,
        .state = &state,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
    });
    const raw = store.rawNode("block").?;
    try std.testing.expectEqual(@as(i64, 2), raw.object.get("shared").?.integer);
    const keys = try store.objectKeys(std.testing.allocator, "block");
    defer Store.freeObjectKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 5), keys.len);
    const expected_keys = [_][]const u8{ "one", "shared", "flat", "two", "last" };
    for (keys, &expected_keys) |actual, expected| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var file = try Document.parse(
        allocator,
        "{\"provider\":\"llama.cpp\",\"model\":\"m\",\"object\":{\"a\":1},\"object.b\":2}",
        .{},
    );
    defer file.deinit();
    var state = try Document.parse(allocator, "{\"object\":{\"a\":2,\"c\":3}}", .{});
    defer state.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "provider", .setting = .{} },
        .{ .key = "model", .setting = .{ .default_value = "fallback" } },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    const aliases: AliasCanonicalizer = .{};
    const store = Store.init(.{
        .file = &file,
        .state = &state,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
        .provider_canonicalizer = .from(&aliases),
    });
    var resolved = try store.read(allocator, "model");
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("m", resolved.value.?);
    const keys = try store.objectKeys(allocator, "object");
    defer Store.freeObjectKeys(allocator, keys);
    try std.testing.expectEqual(@as(usize, 3), keys.len);
}

test "owned results survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

const ScratchCanonicalizer = struct {
    buffer: *[16]u8,

    fn canonical(self: *const ScratchCanonicalizer, id: []const u8) []const u8 {
        @memcpy(self.buffer[0..id.len], id);
        return self.buffer[0..id.len];
    }
};

test "provider canonicalization copies callback scratch before the next call" {
    var file = try parseTestDocument("{\"provider\":\"bbbb\",\"model\":\"wrong\"}");
    defer file.deinit();
    var run = try parseTestDocument("{\"provider\":\"aaaa\"}");
    defer run.deinit();
    const registry_impl: TestRegistry = .{ .rows = &.{
        .{ .key = "provider", .setting = .{} },
        .{ .key = "model", .setting = .{ .default_value = "default" } },
    } };
    const environment_impl: TestEnvironment = .{ .entries = &.{} };
    var buffer: [16]u8 = undefined;
    const canonicalizer: ScratchCanonicalizer = .{ .buffer = &buffer };
    const store = Store.init(.{
        .file = &file,
        .run = &run,
        .registry = .from(&registry_impl),
        .environment = .from(&environment_impl),
        .provider_canonicalizer = .from(&canonicalizer),
    });
    try expectRead(store, "model", "default", .default);
}
