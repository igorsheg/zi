const std = @import("std");
const resource_types = @import("../resources/types.zig");
const lua_runtime = @import("lua_runtime.zig");
const lua_tool = @import("lua_tool.zig");
const runner_mod = @import("runner.zig");
const tool_def = @import("../tools/definition.zig");
const abort_signal_mod = @import("../../zio/root.zig").abort;
const agent_protocol = @import("../../agent/types.zig");
const ai = @import("../../ai/root.zig");
const extension_ui = @import("ui.zig");
const session_core = @import("../../session/root.zig");
const event_bridge = @import("event_bridge.zig");

const log = std.log.scoped(.extensions);

/// Max extension file size. 1 MiB is absurdly generous for a Lua
/// script; anything larger is almost certainly a mistake (binary
/// in the wrong dir, runaway generator). Capping here keeps the
/// read path bounded without needing streaming.
const MAX_EXTENSION_SIZE: usize = 1024 * 1024;
const BUILTIN_EXTENSION_SOURCE =
    "return function(zi)\n" ++
    "  zi.__register_builtin_tools()\n" ++
    "end\n";

pub const ExtensionSource = resource_types.ExtensionSource;
pub const StaticExtensionRoot = resource_types.StaticExtensionRoot;

/// Discovered extension descriptor. Strings owned by the allocator passed to discover().
pub const LoadedExtension = struct {
    id: []const u8, // basename without .lua, or dir name for init.lua
    path: []const u8, // absolute path to the .lua file to load
    source: ExtensionSource,
    provenance: resource_types.ExtensionProvenance,
};

/// Options for extension discovery.
pub const DiscoverOptions = struct {
    allocator: std.mem.Allocator,
    roots: []const StaticExtensionRoot,
};

/// Track seen IDs within a source to avoid duplicates.
const SeenIds = struct {
    ids: std.ArrayListUnmanaged([]const u8) = .empty,

    fn contains(self: *const SeenIds, id: []const u8) bool {
        for (self.ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }

    fn add(self: *SeenIds, allocator: std.mem.Allocator, id: []const u8) !void {
        const duped = try allocator.dupe(u8, id);
        errdefer allocator.free(duped);
        try self.ids.append(allocator, duped);
    }

    fn deinit(self: *SeenIds, allocator: std.mem.Allocator) void {
        for (self.ids.items) |id| allocator.free(id);
        self.ids.deinit(allocator);
    }
};

/// Discover all extensions from the caller-provided canonical root list.
/// Caller owns returned slice and all strings. Use freeExtensions() to clean up.
/// Built-in extensions are handled as virtual roots.
pub fn discover(opts: DiscoverOptions) ![]LoadedExtension {
    var results: std.ArrayListUnmanaged(LoadedExtension) = .empty;
    var seen: SeenIds = .{};
    defer seen.deinit(opts.allocator);

    for (opts.roots) |root| {
        switch (root.kind) {
            .runtime_root => {
                const ext_dir = try std.fs.path.join(opts.allocator, &.{ root.path, "extensions" });
                defer opts.allocator.free(ext_dir);
                try scanDirectory(opts.allocator, ext_dir, root, &results, &seen);
            },
            .synthetic_extension => try loadSyntheticExtension(opts.allocator, root, &results, &seen),
            .builtin => {
                const builtin_id = try opts.allocator.dupe(u8, "builtins");
                errdefer opts.allocator.free(builtin_id);
                try results.append(opts.allocator, .{
                    .id = builtin_id,
                    .path = try opts.allocator.dupe(u8, "<builtin>"),
                    .source = root.source,
                    .provenance = .{
                        .runtime_root_id = try opts.allocator.dupe(u8, root.runtime_root_id),
                        .extension_id = builtin_id,
                        .state_owner_id = try opts.allocator.dupe(u8, root.state_owner_id),
                        .root_kind = root.kind,
                    },
                });
                try seen.add(opts.allocator, "builtins");
            },
        }
    }

    return results.toOwnedSlice(opts.allocator);
}

/// Free all strings and the slice itself.
pub fn freeExtensions(allocator: std.mem.Allocator, list: []LoadedExtension) void {
    for (list) |ext| {
        allocator.free(ext.id);
        allocator.free(ext.path);
        allocator.free(ext.provenance.runtime_root_id);
        allocator.free(ext.provenance.state_owner_id);
    }
    allocator.free(list);
}

fn extensionStateOwnerId(
    allocator: std.mem.Allocator,
    runtime_root_id: []const u8,
    extension_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ runtime_root_id, extension_id });
}

/// Load a synthetic single-extension root. Error if path doesn't exist.
fn loadSyntheticExtension(
    allocator: std.mem.Allocator,
    root: StaticExtensionRoot,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    std.Io.Dir.accessAbsolute(std.Options.debug_io, root.path, .{}) catch |err| {
        log.warn("synthetic extension path not found: {s} ({s})", .{ root.path, @errorName(err) });
        return err;
    };

    const id = extensionIdFromSyntheticPath(root.path);
    if (seen.contains(id)) {
        log.debug("skipping duplicate synthetic extension id in {s}: {s}", .{ @tagName(root.source), id });
        return;
    }

    const abs_path = try syntheticExtensionFilePath(allocator, root.path);
    errdefer allocator.free(abs_path);

    const duped_id = try allocator.dupe(u8, id);
    errdefer allocator.free(duped_id);

    try seen.add(allocator, id);
    try results.append(allocator, .{
        .id = duped_id,
        .path = abs_path,
        .source = root.source,
        .provenance = .{
            .runtime_root_id = try allocator.dupe(u8, root.runtime_root_id),
            .extension_id = duped_id,
            .state_owner_id = try extensionStateOwnerId(allocator, root.runtime_root_id, duped_id),
            .root_kind = root.kind,
        },
    });
}

fn syntheticExtensionFilePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, path, ".lua")) return realPathAbsoluteDupe(allocator, path);

    const init_path = try std.fs.path.join(allocator, &.{ path, "init.lua" });
    defer allocator.free(init_path);
    std.Io.Dir.accessAbsolute(std.Options.debug_io, init_path, .{}) catch return realPathAbsoluteDupe(allocator, path);
    return realPathAbsoluteDupe(allocator, init_path);
}

fn realPathAbsoluteDupe(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const resolved_z = try std.Io.Dir.realPathFileAbsoluteAlloc(std.Options.debug_io, path, allocator);
    defer allocator.free(resolved_z);
    return allocator.dupe(u8, resolved_z);
}

fn extensionIdFromSyntheticPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "init.lua")) {
        const parent = std.fs.path.dirname(path) orelse path;
        return std.fs.path.basename(parent);
    }
    if (std.mem.endsWith(u8, basename, ".lua")) return basename[0 .. basename.len - 4];
    return basename;
}

/// Scan a directory for .lua files and foo/init.lua patterns.
fn scanDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    root: StaticExtensionRoot,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // graceful: missing dir = no extensions
        else => {
            log.warn("failed to open extension dir {s}: {s}", .{ dir_path, @errorName(err) });
            return;
        },
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (entry.name[0] == '.') continue; // skip dotfiles

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
                const id = entry.name[0 .. entry.name.len - 4];
                if (seen.contains(id)) {
                    log.debug("skipping duplicate extension id in {s}: {s}", .{ @tagName(root.source), id });
                    continue;
                }
                try addExtension(allocator, id, full_path, root, results, seen);
            },
            .directory => {
                // Check for <dir>/init.lua
                const init_path = try std.fs.path.join(allocator, &.{ full_path, "init.lua" });
                defer allocator.free(init_path);

                std.Io.Dir.accessAbsolute(std.Options.debug_io, init_path, .{}) catch continue; // no init.lua, skip

                if (seen.contains(entry.name)) {
                    log.debug("skipping duplicate extension id in {s}: {s}", .{ @tagName(root.source), entry.name });
                    continue;
                }
                try addExtension(allocator, entry.name, init_path, root, results, seen);
            },
            else => continue,
        }
    }
}

/// Add an extension to results, duplicating strings.
fn addExtension(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    root: StaticExtensionRoot,
    results: *std.ArrayListUnmanaged(LoadedExtension),
    seen: *SeenIds,
) !void {
    const duped_id = try allocator.dupe(u8, id);
    errdefer allocator.free(duped_id);

    const duped_path = try allocator.dupe(u8, path);
    errdefer allocator.free(duped_path);

    try seen.add(allocator, id);
    try results.append(allocator, .{
        .id = duped_id,
        .path = duped_path,
        .source = root.source,
        .provenance = .{
            .runtime_root_id = try allocator.dupe(u8, root.runtime_root_id),
            .extension_id = duped_id,
            .state_owner_id = try extensionStateOwnerId(allocator, root.runtime_root_id, duped_id),
            .root_kind = root.kind,
        },
    });
}

// ── Factory execution ───────────────────────────────────────────────
//
// v1 model matches the spec: an extension chunk returns a factory
// function and the host calls `factory(zi)` against the shared Lua
// state. Extensions are NOT sandboxed — they share one state — but
// registrations are attributed to the extension currently being loaded
// via the runner's temporary load context.
//
// Ordering matches `discover` output: explicit → user → project. The
// tool/command registries are first-registered-wins, so a user override
// of a project tool arrives at registration BEFORE the project version
// and silently drops it. Event handlers are additive and run in
// registration order.

pub const LoadStats = struct {
    attempted: u32 = 0,
    loaded: u32 = 0,
    failed: u32 = 0,
};

/// Read each discovered extension file and execute it against `state`.
/// Per-file read or Lua errors are logged and skipped — one broken
/// extension does not prevent the others from loading. Returns a small
/// stat bundle for the caller to log.
///
/// Caller must have already installed `zi.*` on the state (via
/// `extensions/api.zig:installZiTable`) before calling this.
pub fn loadAll(
    allocator: std.mem.Allocator,
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    list: []const LoadedExtension,
    builtin_definitions: []const tool_def.ToolDefinition,
) LoadStats {
    var stats: LoadStats = .{};
    for (list) |ext| {
        stats.attempted += 1;
        if (ext.source == .builtin) {
            loadBuiltinExtension(state, runner, ext, builtin_definitions) catch |err| {
                log.warn("builtin extension load failed: {s} ({s}): {s}", .{
                    ext.id,
                    ext.path,
                    @errorName(err),
                });
                stats.failed += 1;
                continue;
            };
        } else {
            loadOne(allocator, state, runner, ext) catch |err| {
                log.warn("extension load failed: {s} ({s}): {s}", .{
                    ext.id,
                    ext.path,
                    @errorName(err),
                });
                stats.failed += 1;
                continue;
            };
        }
        stats.loaded += 1;
        log.debug("extension loaded: {s} [{s}]", .{ ext.id, @tagName(ext.source) });
    }
    return stats;
}

fn loadBuiltinExtension(
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    ext: LoadedExtension,
    builtin_definitions: []const tool_def.ToolDefinition,
) !void {
    if (builtin_definitions.len == 0) return;

    const chunk_name_buf = try std.fmt.allocPrint(runner.allocator, "@{s}", .{ext.path});
    defer runner.allocator.free(chunk_name_buf);
    const chunk_name = try runner.allocator.dupeZ(u8, chunk_name_buf);
    defer runner.allocator.free(chunk_name);

    const load_source: runner_mod.ExtensionLoadSource = .{
        .kind = sourceKindString(ext.source),
        .id = ext.id,
        .path = ext.path,
        .provenance = ext.provenance,
    };
    runner.beginLoadContext(load_source);
    defer runner.endLoadContext();
    runner.setModuleContext(state, ext.provenance);

    try state.loadChunk(BUILTIN_EXTENSION_SOURCE, chunk_name);
    const chunk_call_rc = lua_runtime.c.lua_pcallk(state.L, 0, 1, 0, 0, null);
    if (chunk_call_rc != lua_runtime.c.LUA_OK) return lua_runtime.mapCallError(state.L, chunk_call_rc);

    if (lua_runtime.c.lua_type(state.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
        lua_runtime.c.lua_pop(state.L, 1);
        return error.ExtensionFactoryExpectedFunction;
    }

    _ = lua_runtime.c.lua_getglobal(state.L, "zi");
    if (lua_runtime.c.lua_type(state.L, -1) != lua_runtime.c.LUA_TTABLE) {
        lua_runtime.c.lua_pop(state.L, 2);
        return error.LuaRuntime;
    }

    const factory_call_rc = lua_runtime.c.lua_pcallk(state.L, 1, 0, 0, 0, null);
    if (factory_call_rc != lua_runtime.c.LUA_OK) return lua_runtime.mapCallError(state.L, factory_call_rc);
    try runner.recordLoadedExtension(ext.provenance);
}

fn loadOne(
    allocator: std.mem.Allocator,
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    ext: LoadedExtension,
) !void {
    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, ext.path, .{});
    defer file.close(std.Options.debug_io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &read_buf);
    const src = try file_reader.interface.allocRemaining(allocator, .limited(MAX_EXTENSION_SIZE));
    defer allocator.free(src);

    const chunk_name_buf = try std.fmt.allocPrint(allocator, "@{s}", .{ext.path});
    defer allocator.free(chunk_name_buf);
    const chunk_name = try allocator.dupeZ(u8, chunk_name_buf);
    defer allocator.free(chunk_name);

    runner.assertOnLuaThread();

    const load_source: runner_mod.ExtensionLoadSource = .{
        .kind = sourceKindString(ext.source),
        .id = ext.id,
        .path = ext.path,
        .provenance = ext.provenance,
    };

    runner.beginLoadContext(load_source);
    defer runner.endLoadContext();

    // Record the module root before execution so that `require` in
    // top-level code and the factory resolve truthfully.
    runner.recordModuleRoot(ext.provenance.state_owner_id, ext.path) catch |err| {
        log.warn("failed to record module root for {s}: {s}", .{ ext.id, @errorName(err) });
    };
    runner.setModuleContext(state, ext.provenance);

    // Step 1: execute the chunk itself. Spec-shaped extensions return
    // a factory function from top level.
    try state.loadChunk(src, chunk_name);
    const chunk_call_rc = lua_runtime.c.lua_pcallk(state.L, 0, 1, 0, 0, null);
    if (chunk_call_rc != lua_runtime.c.LUA_OK) return lua_runtime.mapCallError(state.L, chunk_call_rc);

    if (lua_runtime.c.lua_type(state.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
        lua_runtime.c.lua_pop(state.L, 1);
        return error.ExtensionFactoryExpectedFunction;
    }

    // Step 2: call the returned factory with the shared `zi` table.
    _ = lua_runtime.c.lua_getglobal(state.L, "zi");
    if (lua_runtime.c.lua_type(state.L, -1) != lua_runtime.c.LUA_TTABLE) {
        lua_runtime.c.lua_pop(state.L, 2);
        return error.LuaRuntime;
    }

    const factory_call_rc = lua_runtime.c.lua_pcallk(state.L, 1, 0, 0, 0, null);
    if (factory_call_rc != lua_runtime.c.LUA_OK) return lua_runtime.mapCallError(state.L, factory_call_rc);
    runner.recordLoadedExtension(ext.provenance) catch |err| {
        log.warn("failed to record loaded extension provenance for {s}: {s}", .{ ext.id, @errorName(err) });
    };
}

fn sourceKindString(source: ExtensionSource) []const u8 {
    return switch (source) {
        .explicit => "explicit",
        .user => "user",
        .project => "project",
        .builtin => "builtin",
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const api = @import("api.zig");
const dispatch_mod = @import("dispatch.zig");

test "discover finds runtime extensions and preserves explicit-before-runtime precedence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "foo.lua", .data = "-- foo" });
    try ext_dir.createDir(std.Options.debug_io, "bar", .default_dir);
    var bar_dir = try ext_dir.openDir(std.Options.debug_io, "bar", .{});
    try bar_dir.writeFile(std.Options.debug_io, .{ .sub_path = "init.lua", .data = "-- bar" });
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "explicit_ext.lua", .data = "-- explicit" });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);
    const explicit_path = try std.fs.path.join(allocator, &.{ tmp_path, "explicit_ext.lua" });
    defer allocator.free(explicit_path);

    const roots = [_]StaticExtensionRoot{
        .{ .source = .explicit, .path = explicit_path, .kind = .synthetic_extension, .runtime_root_id = explicit_path, .state_owner_id = explicit_path },
        .{ .source = .user, .path = tmp_path, .kind = .runtime_root, .runtime_root_id = tmp_path, .state_owner_id = tmp_path },
    };
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    try std.testing.expectEqual(@as(usize, 3), exts.len);
    try std.testing.expectEqualStrings("explicit_ext", exts[0].id);
    try std.testing.expectEqual(ExtensionSource.explicit, exts[0].source);

    var found_foo = false;
    var found_bar = false;
    for (exts[1..]) |ext| {
        if (std.mem.eql(u8, ext.id, "foo")) found_foo = std.mem.endsWith(u8, ext.path, "foo.lua");
        if (std.mem.eql(u8, ext.id, "bar")) found_bar = std.mem.endsWith(u8, ext.path, "bar/init.lua");
    }
    try std.testing.expect(found_foo);
    try std.testing.expect(found_bar);
}

test "discover maps synthetic bundled extensions to init.lua with parent directory id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "bundle_ext", .default_dir);
    var bundle_dir = try tmp.dir.openDir(std.Options.debug_io, "bundle_ext", .{});
    defer bundle_dir.close(std.Options.debug_io);
    try bundle_dir.writeFile(std.Options.debug_io, .{ .sub_path = "init.lua", .data = "-- bundled" });

    const bundle_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "bundle_ext", allocator);
    defer allocator.free(bundle_path);
    const roots = [_]StaticExtensionRoot{.{ .source = .explicit, .path = bundle_path, .kind = .synthetic_extension, .runtime_root_id = bundle_path, .state_owner_id = bundle_path }};

    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    try std.testing.expectEqual(@as(usize, 1), exts.len);
    try std.testing.expectEqualStrings("bundle_ext", exts[0].id);
    try std.testing.expect(std.mem.endsWith(u8, exts[0].path, "bundle_ext/init.lua"));
}

test "loadAll executes discovered .lua files and registrations land" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    const hello_src =
        "return function(zi)\n" ++
        "  _loaded = true\n" ++
        "  zi.on(\"message_end\", function(e, ctx) end)\n" ++
        "end\n";
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "hello.lua", .data = hello_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);
    try std.testing.expectEqual(@as(usize, 1), exts.len);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expectEqual(@as(u32, 0), stats.failed);

    try state.doString("assert(_loaded == true)", "verify");
    try std.testing.expectEqual(@as(usize, 1), runner.event_registry.handlers(.message_end).len);
    try std.testing.expectEqualStrings(exts[0].path, runner.event_registry.handlers(.message_end)[0].source_id);
}

test "loadAll continues after a broken extension" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "broken.lua", .data = "this is not valid lua !!!" });
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "good.lua", .data = "return function(zi) _good = 42 end" });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 2), stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expectEqual(@as(u32, 1), stats.failed);

    // Good extension still ran despite broken sibling.
    try state.doString("assert(_good == 42)", "verify");
}

test "loadAll continues after a factory-time failure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    try ext_dir.writeFile(std.Options.debug_io, .{
        .sub_path = "broken.lua",
        .data = "return function(zi)\n" ++
            "  error(\"factory blew up\")\n" ++
            "end\n",
    });
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "good.lua", .data = "return function(zi) _good = 42 end" });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);

    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 2), stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expectEqual(@as(u32, 1), stats.failed);

    try state.doString("assert(_good == 42)", "verify");
}

test "loadAll calls factory with zi and stamps source provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    const prov_src =
        "return function(zi)\n" ++
        "  zi.register_tool({\n" ++
        "    name = \"demo\",\n" ++
        "    description = \"demo tool\",\n" ++
        "    parameters = { type = \"object\", properties = {} },\n" ++
        "    execute = function(params, ctx)\n" ++
        "      return { ok = true }\n" ++
        "    end,\n" ++
        "  })\n" ++
        "  zi.on(\"message_end\", function() end)\n" ++
        "end\n";
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "provenance.lua", .data = prov_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    const tool = runner.tool_registry.get("demo").?;
    try std.testing.expectEqualStrings("user", tool.source.kind);
    try std.testing.expectEqualStrings(exts[0].path, tool.source.id);
    const expected_state_owner = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ tmp_path, exts[0].id });
    defer allocator.free(expected_state_owner);

    try std.testing.expect(tool.source.provenance != null);
    try std.testing.expectEqualStrings(tmp_path, tool.source.provenance.?.runtime_root_id);
    try std.testing.expectEqualStrings("provenance", tool.source.provenance.?.extension_id);
    try std.testing.expectEqualStrings(expected_state_owner, tool.source.provenance.?.state_owner_id);

    const handler = runner.event_registry.handlers(.message_end)[0];
    try std.testing.expectEqualStrings(exts[0].path, handler.source_id);
    try std.testing.expect(handler.provenance != null);
    try std.testing.expectEqualStrings(tmp_path, handler.provenance.?.runtime_root_id);
    try std.testing.expectEqualStrings("provenance", handler.provenance.?.extension_id);
    try std.testing.expectEqualStrings(expected_state_owner, handler.provenance.?.state_owner_id);

    const loaded = runner.findLoadedExtensionByStateOwner(expected_state_owner) orelse return error.MissingLoadedExtensionProvenance;
    try std.testing.expectEqualStrings(tmp_path, loaded.runtime_root_id);
    try std.testing.expectEqualStrings("provenance", loaded.extension_id);
    try std.testing.expectEqualStrings(expected_state_owner, loaded.state_owner_id);
}

test "example hello extension loads and greets through the tool boundary" {
    const allocator = std.testing.allocator;
    const hello_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "examples/extensions/hello.lua", allocator);
    defer allocator.free(hello_path);

    var state_owner_buf: [256]u8 = undefined;
    const state_owner_id = try std.fmt.bufPrint(&state_owner_buf, "example::{s}", .{"hello"});
    const ext = LoadedExtension{
        .id = "hello",
        .path = hello_path,
        .source = .user,
        .provenance = .{
            .runtime_root_id = "examples/extensions",
            .extension_id = "hello",
            .state_owner_id = state_owner_id,
            .root_kind = .runtime_root,
        },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, &.{ext}, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    const ext_tool = runner.tool_registry.get("greet") orelse return error.MissingHelloTool;
    const tool = try lua_tool.buildAgentTool(allocator, &runner, ext_tool.*);

    var args_obj: std.json.ObjectMap = .{};
    defer args_obj.deinit(allocator);
    try args_obj.put(allocator, "name", .{ .string = "zi" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = tool.execute(tool.ctx, arena.allocator(), "hello-1", .{ .object = args_obj }, abort_signal_mod.AbortSignal.none, null, null);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings("Hello, zi!", result.content[0].text.text);
}

test "example commands extension dispatches through host-owned command ui" {
    const allocator = std.testing.allocator;
    const commands_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "examples/extensions/commands.lua", allocator);
    defer allocator.free(commands_path);

    var state_owner_buf: [256]u8 = undefined;
    const state_owner_id = try std.fmt.bufPrint(&state_owner_buf, "example::{s}", .{"commands"});
    const ext = LoadedExtension{
        .id = "commands",
        .path = commands_path,
        .source = .user,
        .provenance = .{
            .runtime_root_id = "examples/extensions",
            .extension_id = "commands",
            .state_owner_id = state_owner_id,
            .root_kind = .runtime_root,
        },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    var store = CommandExampleStore{};
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try runner.bindRuntime(.{
        .session = @ptrCast(&store),
        .get_model = &commandExampleGetModel,
        .is_idle = &commandExampleIsIdle,
        .abort = &commandExampleAbort,
        .has_pending_messages = &commandExampleHasPendingMessages,
        .get_context_usage = &commandExampleGetContextUsage,
        .get_system_prompt = &commandExampleGetSystemPrompt,
        .get_binding_info = &commandExampleGetBindingInfo,
        .publish_report = &CommandExampleStore.publishReport,
    }, &provider_registry);
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, &.{ext}, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expect(runner.command_registry.getByVisibleName("hello") != null);

    try runner.dispatchCommand("hello", "matrix");
    const report = store.report orelse return error.MissingCommandReport;
    try std.testing.expectEqualStrings("hello-command", report.id);
    try std.testing.expectEqualStrings("Hello command", report.title);
    try std.testing.expect(report.transient);
    try std.testing.expectEqual(@as(usize, 1), report.lines.len);
    try std.testing.expectEqual(@as(usize, 1), report.lines[0].len);
    try std.testing.expectEqualStrings("Hello, matrix!", report.lines[0][0].text);
}

const CommandExampleStore = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    report: ?extension_ui.Report = null,
    editor_action: ?extension_ui.EditorAction = null,
    ui_publications: std.ArrayList(extension_ui.UiPublication) = .empty,

    fn deinit(self: *CommandExampleStore) void {
        if (self.editor_action) |*action| action.deinit(self.allocator);
        self.editor_action = null;
        for (self.ui_publications.items) |*ui_publication| ui_publication.deinit(self.allocator);
        self.ui_publications.deinit(self.allocator);
    }

    fn publishReport(session: *anyopaque, report: extension_ui.Report) anyerror!void {
        const self: *CommandExampleStore = @ptrCast(@alignCast(session));
        self.report = report;
    }

    fn publishEditorAction(session: *anyopaque, action: extension_ui.EditorAction) anyerror!void {
        const self: *CommandExampleStore = @ptrCast(@alignCast(session));
        if (self.editor_action) |*existing| existing.deinit(self.allocator);
        self.editor_action = try extension_ui.EditorAction.clone(self.allocator, action);
    }

    fn publishUi(session: *anyopaque, update: extension_ui.UiPublication) anyerror!void {
        const self: *CommandExampleStore = @ptrCast(@alignCast(session));
        const cloned = try extension_ui.UiPublication.clone(self.allocator, update);
        try self.ui_publications.append(self.allocator, cloned);
    }
};

fn commandExampleGetModel(_: *anyopaque) agent_protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = .{ .custom = "test-api" },
        .provider = .{ .custom = "test-provider" },
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn commandExampleIsIdle(_: *anyopaque) bool {
    return true;
}

fn commandExampleAbort(_: *anyopaque) void {}

fn commandExampleHasPendingMessages(_: *anyopaque) bool {
    return false;
}

fn commandExampleGetContextUsage(_: *anyopaque) ?session_core.context_usage.ContextUsage {
    return null;
}

fn commandExampleGetSystemPrompt(_: *anyopaque) []const u8 {
    return "system";
}

fn commandExampleGetBindingInfo(_: *anyopaque) runner_mod.ExtensionBindingInfo {
    return .{
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    };
}

fn commandExampleAssistantMessage() ai.protocol.AssistantMessage {
    return .{
        .content = &.{},
        .api = .{ .custom = "test-api" },
        .provider = .{ .custom = "test-provider" },
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

test "example status line extension updates status across session and turn events" {
    const allocator = std.testing.allocator;
    const status_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "examples/extensions/status_line.lua", allocator);
    defer allocator.free(status_path);

    var state_owner_buf: [256]u8 = undefined;
    const state_owner_id = try std.fmt.bufPrint(&state_owner_buf, "example::{s}", .{"status_line"});
    const ext = LoadedExtension{
        .id = "status_line",
        .path = status_path,
        .source = .user,
        .provenance = .{
            .runtime_root_id = "examples/extensions",
            .extension_id = "status_line",
            .state_owner_id = state_owner_id,
            .root_kind = .runtime_root,
        },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    var store = CommandExampleStore{ .allocator = allocator };
    defer store.deinit();
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try runner.bindRuntime(.{
        .session = @ptrCast(&store),
        .get_model = &commandExampleGetModel,
        .is_idle = &commandExampleIsIdle,
        .abort = &commandExampleAbort,
        .has_pending_messages = &commandExampleHasPendingMessages,
        .get_context_usage = &commandExampleGetContextUsage,
        .get_system_prompt = &commandExampleGetSystemPrompt,
        .get_binding_info = &commandExampleGetBindingInfo,
        .publish_ui = &CommandExampleStore.publishUi,
    }, &provider_registry);
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, &.{ext}, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    try event_bridge.dispatchSessionStart(.{
        .runner = &runner,
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    }, null, .startup, null);
    try std.testing.expectEqual(extension_ui.UiPublicationKind.status, store.ui_publications.items[0].kind);
    try std.testing.expectEqualStrings("status-demo", store.ui_publications.items[0].id);
    try std.testing.expectEqualStrings("Ready", store.ui_publications.items[0].text.?);

    try event_bridge.handleAgentEvent(&runner, .{ .turn_start = {} });
    try std.testing.expectEqual(extension_ui.UiPublicationKind.status, store.ui_publications.items[1].kind);
    try std.testing.expectEqualStrings("status-demo", store.ui_publications.items[1].id);
    try std.testing.expectEqualStrings("● Turn 1...", store.ui_publications.items[1].text.?);

    try event_bridge.handleAgentEvent(&runner, .{ .turn_end = .{
        .message = .{ .assistant = commandExampleAssistantMessage() },
        .tool_results = &.{},
    } });
    try std.testing.expectEqual(extension_ui.UiPublicationKind.status, store.ui_publications.items[2].kind);
    try std.testing.expectEqualStrings("status-demo", store.ui_publications.items[2].id);
    try std.testing.expectEqualStrings("✓ Turn 1 complete", store.ui_publications.items[2].text.?);
}

test "example custom header extension publishes a semantic report" {
    const allocator = std.testing.allocator;
    const header_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "examples/extensions/custom_header.lua", allocator);
    defer allocator.free(header_path);

    var state_owner_buf: [256]u8 = undefined;
    const state_owner_id = try std.fmt.bufPrint(&state_owner_buf, "example::{s}", .{"custom_header"});
    const ext = LoadedExtension{
        .id = "custom_header",
        .path = header_path,
        .source = .user,
        .provenance = .{
            .runtime_root_id = "examples/extensions",
            .extension_id = "custom_header",
            .state_owner_id = state_owner_id,
            .root_kind = .runtime_root,
        },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    var store = CommandExampleStore{ .allocator = allocator };
    defer store.deinit();
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try runner.bindRuntime(.{
        .session = @ptrCast(&store),
        .get_model = &commandExampleGetModel,
        .is_idle = &commandExampleIsIdle,
        .abort = &commandExampleAbort,
        .has_pending_messages = &commandExampleHasPendingMessages,
        .get_context_usage = &commandExampleGetContextUsage,
        .get_system_prompt = &commandExampleGetSystemPrompt,
        .get_binding_info = &commandExampleGetBindingInfo,
        .publish_report = &CommandExampleStore.publishReport,
    }, &provider_registry);
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, &.{ext}, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    try event_bridge.dispatchSessionStart(.{
        .runner = &runner,
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    }, null, .startup, null);

    const report = store.report orelse return error.MissingReport;
    try std.testing.expectEqualStrings("welcome", report.id);
    try std.testing.expectEqualStrings("zi coding agent", report.title);
    try std.testing.expectEqualStrings("Welcome. Extension UI is semantic and host-owned.", report.lines[0][0].text);
    try std.testing.expect(report.transient);
}

test "example qna extension writes a question prompt through editor actions" {
    const allocator = std.testing.allocator;
    const qna_path = try std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, "examples/extensions/qna.lua", allocator);
    defer allocator.free(qna_path);

    var state_owner_buf: [256]u8 = undefined;
    const state_owner_id = try std.fmt.bufPrint(&state_owner_buf, "example::{s}", .{"qna"});
    const ext = LoadedExtension{
        .id = "qna",
        .path = qna_path,
        .source = .user,
        .provenance = .{
            .runtime_root_id = "examples/extensions",
            .extension_id = "qna",
            .state_owner_id = state_owner_id,
            .root_kind = .runtime_root,
        },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    var store = CommandExampleStore{ .allocator = allocator };
    defer store.deinit();
    var provider_registry = ai.provider.Registry.init(allocator);
    defer provider_registry.deinit();
    try runner.bindRuntime(.{
        .session = @ptrCast(&store),
        .get_model = &commandExampleGetModel,
        .is_idle = &commandExampleIsIdle,
        .abort = &commandExampleAbort,
        .has_pending_messages = &commandExampleHasPendingMessages,
        .get_context_usage = &commandExampleGetContextUsage,
        .get_system_prompt = &commandExampleGetSystemPrompt,
        .get_binding_info = &commandExampleGetBindingInfo,
        .publish_editor_action = &CommandExampleStore.publishEditorAction,
    }, &provider_registry);
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, &.{ext}, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expect(runner.command_registry.getByVisibleName("qna") != null);

    try runner.dispatchCommand("qna", "What changed?");
    const action = store.editor_action orelse return error.MissingEditorAction;
    try std.testing.expectEqual(.set_text, action.kind);
    try std.testing.expectEqualStrings(state_owner_id, action.state_owner_id);
    try std.testing.expectEqualStrings("Question: What changed?\n\nAnswer: ", action.text.?);
}

test "loadAll stamps provenance on top-level registrations outside factory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    const top_level_src =
        "zi.on(\"message_end\", function() end)\n" ++
        "return function(zi)\n" ++
        "end\n";
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "toplevel.lua", .data = top_level_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());
    api.installZiTable(&state, &runner);

    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    const handler = runner.event_registry.handlers(.message_end)[0];
    try std.testing.expectEqualStrings(exts[0].path, handler.source_id);
    try std.testing.expect(handler.provenance != null);
    try std.testing.expectEqualStrings(tmp_path, handler.provenance.?.runtime_root_id);
    try std.testing.expectEqualStrings("toplevel", handler.provenance.?.extension_id);
    const expected_state_owner = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ tmp_path, exts[0].id });
    defer allocator.free(expected_state_owner);
    try std.testing.expectEqualStrings(expected_state_owner, handler.provenance.?.state_owner_id);
}

test "bundled extension requires private helper resolved from directory module root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    try ext_dir.createDir(std.Options.debug_io, "bar", .default_dir);
    var bar_dir = try ext_dir.openDir(std.Options.debug_io, "bar", .{});
    try bar_dir.writeFile(std.Options.debug_io, .{ .sub_path = "helper.lua", .data = "_bar_helper_loaded = true\n" });
    const ext_src =
        "require(\"helper\")\n" ++
        "return function(zi) end\n";
    try bar_dir.writeFile(std.Options.debug_io, .{ .sub_path = "init.lua", .data = ext_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    try state.doString("assert(_bar_helper_loaded == true)", "verify");
}

test "shared lua root resolves before later root in canonical order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    const ext_src =
        "local s = require(\"shared_helper\")\n" ++
        "_shared_value = s\n" ++
        "return function(zi) end\n";
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "ext.lua", .data = ext_src });

    try tmp.dir.createDir(std.Options.debug_io, "lua", .default_dir);
    var lua_dir = try tmp.dir.openDir(std.Options.debug_io, "lua", .{});
    try lua_dir.writeFile(std.Options.debug_io, .{ .sub_path = "shared_helper.lua", .data = "return 'first'\n" });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);

    // Prime shared lua paths so the extension can resolve shared modules.
    const shared_path = try std.fs.path.join(allocator, &.{ tmp_path, "lua" });
    defer allocator.free(shared_path);
    var shared_buf: std.ArrayList(u8) = .empty;
    defer shared_buf.deinit(allocator);
    try shared_buf.print(allocator, "{s}/?.lua;{s}/?/init.lua", .{ shared_path, shared_path });
    runner.shared_lua_paths = try allocator.dupe(u8, shared_buf.items);

    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    try state.doString("assert(_shared_value == 'first')", "verify");
}

test "event handler dispatch inherits extension module context for require" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    try ext_dir.createDir(std.Options.debug_io, "evt", .default_dir);
    var evt_dir = try ext_dir.openDir(std.Options.debug_io, "evt", .{});
    try evt_dir.writeFile(std.Options.debug_io, .{ .sub_path = "helper.lua", .data = "_evt_helper_loaded = true\n" });
    const ext_src =
        "zi.on(\"message_end\", function(event, ctx)\n" ++
        "  require(\"helper\")\n" ++
        "end)\n" ++
        "return function(zi) end\n";
    try evt_dir.writeFile(std.Options.debug_io, .{ .sub_path = "init.lua", .data = ext_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    const stats = loadAll(allocator, &state, &runner, exts, &.{});
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);

    // Build a payload table on the main stack: { name = "ping" }
    lua_runtime.c.lua_createtable(state.L, 0, 1);
    _ = lua_runtime.c.lua_pushlstring(state.L, "ping", 4);
    lua_runtime.c.lua_setfield(state.L, -2, "name");

    try dispatch_mod.dispatchObserver(&state, &runner, .message_end, -1);
    lua_runtime.c.lua_pop(state.L, 1);

    try state.doString("assert(_evt_helper_loaded == true)", "verify");
}

test "builtin tools register with builtin source through extension loader" {
    const allocator = std.testing.allocator;

    const params = std.json.Value{ .object = .{} };
    const builtin_defs = try allocator.alloc(tool_def.ToolDefinition, 1);
    defer {
        allocator.free(builtin_defs[0].name);
        allocator.free(builtin_defs[0].label);
        allocator.free(builtin_defs[0].description);
        var p = builtin_defs[0].parameters.object;
        p.deinit(allocator);
        allocator.free(builtin_defs);
    }
    builtin_defs[0] = .{
        .name = try allocator.dupe(u8, "bash"),
        .label = try allocator.dupe(u8, "bash"),
        .description = try allocator.dupe(u8, "test bash"),
        .parameters = params,
        .impl = .{ .builtin = .{ .execute = undefined } },
        .source = .{ .kind = "builtin", .id = "bash" },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.builtin_tool_definitions = builtin_defs;
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    const ext = LoadedExtension{
        .id = try allocator.dupe(u8, "builtins"),
        .path = try allocator.dupe(u8, "<builtin>"),
        .source = .builtin,
        .provenance = .{
            .runtime_root_id = try allocator.dupe(u8, "builtin"),
            .extension_id = try allocator.dupe(u8, "builtins"),
            .state_owner_id = try allocator.dupe(u8, "builtin"),
            .root_kind = .builtin,
        },
    };
    defer {
        allocator.free(ext.id);
        allocator.free(ext.path);
        allocator.free(ext.provenance.runtime_root_id);
        allocator.free(ext.provenance.extension_id);
        allocator.free(ext.provenance.state_owner_id);
    }

    const stats = loadAll(allocator, &state, &runner, &.{ext}, builtin_defs);
    try std.testing.expectEqual(@as(u32, 1), stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expectEqual(@as(u32, 0), stats.failed);

    const tool = runner.tool_registry.get("bash").?;
    try std.testing.expectEqualStrings("builtin", tool.source.kind);
}

test "user extension wins precedence over builtin with same name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.Options.debug_io, "extensions", .default_dir);
    var ext_dir = try tmp.dir.openDir(std.Options.debug_io, "extensions", .{});
    const user_src =
        "return function(zi)\n" ++
        "  zi.register_tool({\n" ++
        "    name = \"bash\",\n" ++
        "    description = \"user bash\",\n" ++
        "    parameters = { type = \"object\", properties = {} },\n" ++
        "    execute = function(params, ctx)\n" ++
        "      return { ok = true }\n" ++
        "    end,\n" ++
        "  })\n" ++
        "end\n";
    try ext_dir.writeFile(std.Options.debug_io, .{ .sub_path = "bash.lua", .data = user_src });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    const params = std.json.Value{ .object = .{} };
    const builtin_defs = try allocator.alloc(tool_def.ToolDefinition, 1);
    defer {
        allocator.free(builtin_defs[0].name);
        allocator.free(builtin_defs[0].label);
        allocator.free(builtin_defs[0].description);
        var p = builtin_defs[0].parameters.object;
        p.deinit(allocator);
        allocator.free(builtin_defs);
    }
    builtin_defs[0] = .{
        .name = try allocator.dupe(u8, "bash"),
        .label = try allocator.dupe(u8, "bash"),
        .description = try allocator.dupe(u8, "builtin bash"),
        .parameters = params,
        .impl = .{ .builtin = .{ .execute = undefined } },
        .source = .{ .kind = "builtin", .id = "bash" },
    };

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.builtin_tool_definitions = builtin_defs;
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    // Load user extension first
    const user_stats = loadAll(allocator, &state, &runner, exts, builtin_defs);
    try std.testing.expectEqual(@as(u32, 1), user_stats.loaded);

    // Load builtin extension after user
    const builtin_ext = LoadedExtension{
        .id = try allocator.dupe(u8, "builtins"),
        .path = try allocator.dupe(u8, "<builtin>"),
        .source = .builtin,
        .provenance = .{
            .runtime_root_id = try allocator.dupe(u8, "builtin"),
            .extension_id = try allocator.dupe(u8, "builtins"),
            .state_owner_id = try allocator.dupe(u8, "builtin"),
            .root_kind = .builtin,
        },
    };
    defer {
        allocator.free(builtin_ext.id);
        allocator.free(builtin_ext.path);
        allocator.free(builtin_ext.provenance.runtime_root_id);
        allocator.free(builtin_ext.provenance.extension_id);
        allocator.free(builtin_ext.provenance.state_owner_id);
    }

    const builtin_stats = loadAll(allocator, &state, &runner, &.{builtin_ext}, builtin_defs);
    try std.testing.expectEqual(@as(u32, 1), builtin_stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), builtin_stats.loaded);
    try std.testing.expectEqual(@as(u32, 0), builtin_stats.failed);

    // User version should win (first-registered-wins)
    const tool = runner.tool_registry.get("bash").?;
    try std.testing.expectEqualStrings("user", tool.source.kind);
}

test "builtin registration bridge rejects calls outside builtin load context" {
    const allocator = std.testing.allocator;

    var state = try lua_runtime.LuaState.init(allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(allocator, 0);
    defer runner.deinit();
    runner.attachLuaState(&state);
    api.installZiTable(&state, &runner);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    try state.doString(
        \\local ok = pcall(function()
        \\  zi.__register_builtin_tools()
        \\end)
        \\assert(ok == false)
    , "verify_builtin_bridge_private");
}
