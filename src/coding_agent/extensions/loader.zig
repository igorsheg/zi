const std = @import("std");
const resource_types = @import("../resources/types.zig");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");

const log = std.log.scoped(.extensions);

/// Max extension file size. 1 MiB is absurdly generous for a Lua
/// script; anything larger is almost certainly a mistake (binary
/// in the wrong dir, runaway generator). Capping here keeps the
/// read path bounded without needing streaming.
const MAX_EXTENSION_SIZE: usize = 1024 * 1024;

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
/// Built-in extensions are NOT handled here (skip for C1).
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
    std.fs.accessAbsolute(root.path, .{}) catch |err| {
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
    if (std.mem.endsWith(u8, path, ".lua")) return std.fs.realpathAlloc(allocator, path);

    const init_path = try std.fs.path.join(allocator, &.{ path, "init.lua" });
    defer allocator.free(init_path);
    std.fs.accessAbsolute(init_path, .{}) catch return std.fs.realpathAlloc(allocator, path);
    return std.fs.realpathAlloc(allocator, init_path);
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
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // graceful: missing dir = no extensions
        else => {
            log.warn("failed to open extension dir {s}: {s}", .{ dir_path, @errorName(err) });
            return;
        },
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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

                std.fs.accessAbsolute(init_path, .{}) catch continue; // no init.lua, skip

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
) LoadStats {
    var stats: LoadStats = .{};
    for (list) |ext| {
        stats.attempted += 1;
        loadOne(allocator, state, runner, ext) catch |err| {
            log.warn("extension load failed: {s} ({s}): {s}", .{
                ext.id,
                ext.path,
                @errorName(err),
            });
            stats.failed += 1;
            continue;
        };
        stats.loaded += 1;
        log.debug("extension loaded: {s} [{s}]", .{ ext.id, @tagName(ext.source) });
    }
    return stats;
}

fn loadOne(
    allocator: std.mem.Allocator,
    state: *lua_runtime.LuaState,
    runner: *runner_mod.ExtensionRunner,
    ext: LoadedExtension,
) !void {
    const file = try std.fs.openFileAbsolute(ext.path, .{});
    defer file.close();
    const src = try file.readToEndAlloc(allocator, MAX_EXTENSION_SIZE);
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

    // Step 1: execute the chunk itself. Spec-shaped extensions return
    // a factory function from top level.
    try state.loadChunk(src, chunk_name);
    const chunk_call_rc = lua_runtime.c.lua_pcallk(state.L, 0, 1, 0, 0, null);
    if (chunk_call_rc != lua_runtime.c.LUA_OK) return lua_runtime.mapCallError(state.L, chunk_call_rc);
    errdefer lua_runtime.c.lua_pop(state.L, 1);

    if (lua_runtime.c.lua_type(state.L, -1) != lua_runtime.c.LUA_TFUNCTION) {
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

test "discover finds foo.lua and bar/init.lua in a temp dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create extensions directory structure
    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});

    // foo.lua (single-file extension)
    try ext_dir.writeFile(.{ .sub_path = "foo.lua", .data = "-- foo extension" });

    // bar/init.lua (directory extension)
    try ext_dir.makeDir("bar");
    var bar_dir = try ext_dir.openDir("bar", .{});
    try bar_dir.writeFile(.{ .sub_path = "init.lua", .data = "-- bar extension" });

    // Get absolute path to the extensions dir
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const opts = DiscoverOptions{
        .allocator = allocator,
        .roots = &roots,
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    // Should find exactly 2 extensions
    try std.testing.expectEqual(@as(usize, 2), exts.len);

    // Verify we found both foo and bar (order depends on filesystem iteration)
    var found_foo = false;
    var found_bar = false;
    for (exts) |ext| {
        if (std.mem.eql(u8, ext.id, "foo")) {
            found_foo = true;
            try std.testing.expectEqual(ExtensionSource.user, ext.source);
            try std.testing.expect(std.mem.endsWith(u8, ext.path, "foo.lua"));
        } else if (std.mem.eql(u8, ext.id, "bar")) {
            found_bar = true;
            try std.testing.expectEqual(ExtensionSource.user, ext.source);
            try std.testing.expect(std.mem.endsWith(u8, ext.path, "bar/init.lua"));
        }
    }
    try std.testing.expect(found_foo);
    try std.testing.expect(found_bar);
}

test "discover returns empty when directories missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .user,
        .path = tmp_path,
        .kind = .runtime_root,
        .runtime_root_id = tmp_path,
        .state_owner_id = tmp_path,
    }};
    const opts = DiscoverOptions{
        .allocator = allocator,
        .roots = &roots,
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    try std.testing.expectEqual(@as(usize, 0), exts.len);
}

test "explicit paths come first in result order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create user extensions dir with one extension
    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
    try ext_dir.writeFile(.{ .sub_path = "user_ext.lua", .data = "-- user" });

    // Create explicit extension file
    try tmp.dir.writeFile(.{ .sub_path = "explicit_ext.lua", .data = "-- explicit" });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const explicit_path = try std.fs.path.join(allocator, &.{ tmp_path, "explicit_ext.lua" });
    defer allocator.free(explicit_path);

    const roots = [_]StaticExtensionRoot{
        .{ .source = .explicit, .path = explicit_path, .kind = .synthetic_extension, .runtime_root_id = explicit_path, .state_owner_id = explicit_path },
        .{ .source = .user, .path = tmp_path, .kind = .runtime_root, .runtime_root_id = tmp_path, .state_owner_id = tmp_path },
    };
    const opts = DiscoverOptions{
        .allocator = allocator,
        .roots = &roots,
    };

    const exts = try discover(opts);
    defer freeExtensions(allocator, exts);

    // Should have exactly 2 extensions, explicit first
    try std.testing.expectEqual(@as(usize, 2), exts.len);
    try std.testing.expectEqualStrings("explicit_ext", exts[0].id);
    try std.testing.expectEqual(ExtensionSource.explicit, exts[0].source);
    try std.testing.expectEqualStrings("user_ext", exts[1].id);
    try std.testing.expectEqual(ExtensionSource.user, exts[1].source);
}

test "discover derives synthetic bundled extension id from parent dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("bundle_ext");
    var bundle_dir = try tmp.dir.openDir("bundle_ext", .{});
    defer bundle_dir.close();
    try bundle_dir.writeFile(.{ .sub_path = "init.lua", .data = "-- bundled" });

    const init_path = try tmp.dir.realpathAlloc(allocator, "bundle_ext/init.lua");
    defer allocator.free(init_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .explicit,
        .path = init_path,
        .kind = .synthetic_extension,
        .runtime_root_id = init_path,
        .state_owner_id = init_path,
    }};

    const exts = try discover(.{ .allocator = allocator, .roots = &roots });
    defer freeExtensions(allocator, exts);

    try std.testing.expectEqual(@as(usize, 1), exts.len);
    try std.testing.expectEqualStrings("bundle_ext", exts[0].id);
    try std.testing.expectEqual(ExtensionSource.explicit, exts[0].source);
}

test "discover loads synthetic bundled extension from directory path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("bundle_ext");
    var bundle_dir = try tmp.dir.openDir("bundle_ext", .{});
    defer bundle_dir.close();
    try bundle_dir.writeFile(.{ .sub_path = "init.lua", .data = "-- bundled" });

    const bundle_path = try tmp.dir.realpathAlloc(allocator, "bundle_ext");
    defer allocator.free(bundle_path);

    const roots = [_]StaticExtensionRoot{.{
        .source = .explicit,
        .path = bundle_path,
        .kind = .synthetic_extension,
        .runtime_root_id = bundle_path,
        .state_owner_id = bundle_path,
    }};

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

    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
    const hello_src =
        "return function(zi)\n" ++
        "  _loaded = true\n" ++
        "  zi.on(\"message_end\", function(e, ctx) end)\n" ++
        "end\n";
    try ext_dir.writeFile(.{ .sub_path = "hello.lua", .data = hello_src });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
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
    const stats = loadAll(allocator, &state, &runner, exts);
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

    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
    try ext_dir.writeFile(.{ .sub_path = "broken.lua", .data = "this is not valid lua !!!" });
    try ext_dir.writeFile(.{ .sub_path = "good.lua", .data = "return function(zi) _good = 42 end" });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
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
    const stats = loadAll(allocator, &state, &runner, exts);
    try std.testing.expectEqual(@as(u32, 2), stats.attempted);
    try std.testing.expectEqual(@as(u32, 1), stats.loaded);
    try std.testing.expectEqual(@as(u32, 1), stats.failed);

    // Good extension still ran despite broken sibling.
    try state.doString("assert(_good == 42)", "verify");
}

test "loadAll calls factory with zi and stamps source provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
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
    try ext_dir.writeFile(.{ .sub_path = "provenance.lua", .data = prov_src });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
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

    const stats = loadAll(allocator, &state, &runner, exts);
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

test "loadAll stamps provenance on top-level registrations outside factory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("extensions");
    var ext_dir = try tmp.dir.openDir("extensions", .{});
    const top_level_src =
        "zi.on(\"message_end\", function() end)\n" ++
        "return function(zi)\n" ++
        "end\n";
    try ext_dir.writeFile(.{ .sub_path = "toplevel.lua", .data = top_level_src });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
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

    const stats = loadAll(allocator, &state, &runner, exts);
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
