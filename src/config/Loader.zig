const std = @import("std");
const Document = @import("Document.zig");
const SecureOpen = @import("SecureOpen.zig");

const Loader = @This();

pub const maximum_path_bytes: usize = 4096;
pub const maximum_file_bytes: usize = 1024 * 1024;

pub const PathError = error{ OutOfMemory, InvalidPath, PathTooLong };

pub const PathInputs = struct {
    xdg_config_home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

pub const Tier = enum { config, state };

/// Builds an owned Zi path without consulting the process environment.
/// Empty XDG values fall back to HOME. Null means neither base is available.
pub fn buildPath(
    allocator: std.mem.Allocator,
    tier: Tier,
    inputs: PathInputs,
) PathError!?[]u8 {
    const xdg = switch (tier) {
        .config => inputs.xdg_config_home,
        .state => inputs.xdg_state_home,
    };
    const leaf = switch (tier) {
        .config => "config.json",
        .state => "state.json",
    };
    if (xdg) |base| if (base.len != 0) {
        const path = try joinValidated(allocator, base, "", leaf);
        return path;
    };
    const home = inputs.home orelse return null;
    if (home.len == 0) return null;
    const path = try joinValidated(
        allocator,
        home,
        if (tier == .config) ".config" else ".local/state",
        leaf,
    );
    return path;
}

pub fn configPath(allocator: std.mem.Allocator, inputs: PathInputs) PathError!?[]u8 {
    return buildPath(allocator, .config, inputs);
}

pub fn statePath(allocator: std.mem.Allocator, inputs: PathInputs) PathError!?[]u8 {
    return buildPath(allocator, .state, inputs);
}

fn joinValidated(
    allocator: std.mem.Allocator,
    base: []const u8,
    middle: []const u8,
    leaf: []const u8,
) PathError![]u8 {
    // Unlike hax's raw environment join, Zi requires bounded absolute UTF-8
    // process inputs. This is an explicit process-boundary safety narrowing.
    if (base.len == 0 or base[0] != '/' or
        std.mem.indexOfScalar(u8, base, 0) != null or
        !std.unicode.utf8ValidateSlice(base)) return error.InvalidPath;
    const tail_len = 1 + (if (middle.len == 0) 0 else middle.len + 1) +
        "zi/".len + leaf.len;
    if (base.len > maximum_path_bytes or tail_len > maximum_path_bytes - base.len)
        return error.PathTooLong;
    const path_len = base.len + tail_len;
    // std.fs reserves one byte for the sentinel passed to pathname syscalls.
    if (path_len >= std.fs.max_path_bytes) return error.PathTooLong;
    return if (middle.len == 0)
        std.fmt.allocPrint(allocator, "{s}/zi/{s}", .{ base, leaf })
    else
        std.fmt.allocPrint(allocator, "{s}/{s}/zi/{s}", .{ base, middle, leaf });
}

pub const Outcome = enum {
    loaded,
    missing,
    empty,
    invalid,
    oversize,
    unreadable,
    non_regular,

    pub fn isUnusable(self: Outcome) bool {
        return switch (self) {
            .invalid, .oversize, .unreadable, .non_regular => true,
            .loaded, .missing, .empty => false,
        };
    }
};

/// Allocator-owned, move-only tier result. The path and optional Document are
/// retained for diagnostics and must be released with deinit exactly once.
pub const Result = struct {
    path: []u8,
    outcome: Outcome,
    document: ?Document = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.document) |*document| document.deinit();
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Reads only a pre-statted regular file through a no-follow open. This is a
/// deliberate safety narrowing from hax: FIFOs, devices, directories, and
/// symbolic links are ignored rather than opened. OOM is the only fatal error.
pub fn loadTierFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    path: []const u8,
) error{OutOfMemory}!Result {
    const owned_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
    errdefer allocator.free(owned_path);

    const named_stat = secure_open.statFile(io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return resultWithoutDocument(owned_path, .missing),
        else => return resultWithoutDocument(owned_path, .unreadable),
    };
    if (named_stat.kind != .file) return resultWithoutDocument(owned_path, .non_regular);
    if (named_stat.size > maximum_file_bytes) return resultWithoutDocument(owned_path, .oversize);

    const file = secure_open.openFile(io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return resultWithoutDocument(owned_path, .missing),
        else => return resultWithoutDocument(owned_path, .unreadable),
    };
    defer file.close(io);
    const stat = file.stat(io) catch return resultWithoutDocument(owned_path, .unreadable);
    if (stat.kind != .file or stat.nlink == 0) return resultWithoutDocument(owned_path, .non_regular);
    if (stat.size > maximum_file_bytes) return resultWithoutDocument(owned_path, .oversize);

    // The buffer can contain API keys, headers, and prompt text. Route its
    // complete capacity through a wiping allocator so partial reads, read
    // errors, and future reallocations wipe every retired allocation.
    var wiping_allocator: Document.WipingAllocator = .{ .backing = allocator };
    const read_allocator = wiping_allocator.allocator();
    const buffer = read_allocator.alloc(u8, maximum_file_bytes + 1) catch return error.OutOfMemory;
    defer read_allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch
        return resultWithoutDocument(owned_path, .unreadable);
    if (count > maximum_file_bytes) return resultWithoutDocument(owned_path, .oversize);
    const bytes = buffer[0..count];
    if (isWhitespaceOnly(bytes)) return resultWithoutDocument(owned_path, .empty);

    const document = Document.parse(allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return resultWithoutDocument(owned_path, .invalid),
    };
    return .{ .path = owned_path, .outcome = .loaded, .document = document };
}

fn resultWithoutDocument(path: []u8, outcome: Outcome) Result {
    return .{ .path = path, .outcome = outcome };
}

fn isWhitespaceOnly(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isWhitespace(byte)) return false;
    return true;
}

pub const InitialTiers = struct {
    config: ?Result,
    state: ?Result,
    config_unusable: bool,

    pub fn deinit(self: *InitialTiers, allocator: std.mem.Allocator) void {
        if (self.config) |*result| result.deinit(allocator);
        if (self.state) |*result| result.deinit(allocator);
        self.* = undefined;
    }
};

/// Builds and loads the initial config and state tiers. State failures never
/// affect config_unusable and no warnings or environment reads occur here.
pub fn loadInitialTiers(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    inputs: PathInputs,
) (PathError || error{OutOfMemory})!InitialTiers {
    const config_path = try configPath(allocator, inputs);
    defer if (config_path) |path| allocator.free(path);
    const state_path = try statePath(allocator, inputs);
    defer if (state_path) |path| allocator.free(path);

    var config = if (config_path) |path| try loadTierFile(allocator, io, secure_open, path) else null;
    errdefer if (config) |*result| result.deinit(allocator);
    const state = if (state_path) |path| try loadTierFile(allocator, io, secure_open, path) else null;
    return .{
        .config = config,
        .state = state,
        .config_unusable = if (config) |result| result.outcome.isUnusable() else false,
    };
}

const TestSecureOpen = struct {
    directory: std.Io.Dir,
    base: []const u8,
    fail_open_oom: bool = false,
    open_substitute: ?[]const u8 = null,
    write_only: bool = false,

    fn relative(self: *TestSecureOpen, path: []const u8) SecureOpen.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, self.base) or path.len <= self.base.len or
            path[self.base.len] != '/') return error.InvalidPath;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File.Stat {
        const sub_path = try self.relative(path);
        return self.directory.statFile(io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Failed,
        };
    }

    pub fn openAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File {
        if (self.fail_open_oom) return error.OutOfMemory;
        const sub_path = self.open_substitute orelse try self.relative(path);
        return self.directory.openFile(io, sub_path, .{
            .mode = if (self.write_only) .write_only else .read_only,
        }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.Unreadable,
            else => error.Failed,
        };
    }
};

test "XDG paths take precedence and HOME fallback owns its bytes" {
    var xdg = [_]u8{ '/', 'x' };
    var home = [_]u8{ '/', 'h' };
    const config = (try configPath(std.testing.allocator, .{
        .xdg_config_home = &xdg,
        .home = &home,
    })).?;
    defer std.testing.allocator.free(config);
    xdg[1] = 'z';
    try std.testing.expectEqualStrings("/x/zi/config.json", config);

    const trailing = (try configPath(std.testing.allocator, .{
        .xdg_config_home = "/cfg///",
        .home = "/ignored",
    })).?;
    defer std.testing.allocator.free(trailing);
    try std.testing.expectEqualStrings("/cfg////zi/config.json", trailing);
    const root_path = (try configPath(std.testing.allocator, .{ .xdg_config_home = "/" })).?;
    defer std.testing.allocator.free(root_path);
    try std.testing.expectEqualStrings("//zi/config.json", root_path);
    const fallback = (try configPath(std.testing.allocator, .{
        .xdg_config_home = "",
        .home = "/home/me",
    })).?;
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("/home/me/.config/zi/config.json", fallback);

    const state = (try statePath(std.testing.allocator, .{ .home = "/home/me/" })).?;
    defer std.testing.allocator.free(state);
    try std.testing.expectEqualStrings("/home/me//.local/state/zi/state.json", state);
    try std.testing.expect((try configPath(std.testing.allocator, .{})) == null);
}

test "path validation rejects relative NUL invalid UTF-8 and oversized paths" {
    try std.testing.expectError(error.InvalidPath, configPath(std.testing.allocator, .{ .xdg_config_home = "tmp" }));
    try std.testing.expectError(
        error.InvalidPath,
        configPath(std.testing.allocator, .{ .xdg_config_home = "/a\x00b" }),
    );
    try std.testing.expectError(error.InvalidPath, configPath(std.testing.allocator, .{ .xdg_config_home = "/\xff" }));
    const long = "/" ++ "a" ** maximum_path_bytes;
    try std.testing.expectError(error.PathTooLong, configPath(std.testing.allocator, .{ .xdg_config_home = long }));
}

test "constructed config path reserves the physical sentinel byte before allocation" {
    const suffix_len = "/zi/config.json".len;
    if (std.fs.max_path_bytes > maximum_path_bytes or std.fs.max_path_bytes <= suffix_len) return;

    const last_base_len = std.fs.max_path_bytes - 1 - suffix_len;
    const last_base = try std.testing.allocator.alloc(u8, last_base_len);
    defer std.testing.allocator.free(last_base);
    @memset(last_base, 'x');
    last_base[0] = '/';
    const last_path = (try configPath(std.testing.allocator, .{ .xdg_config_home = last_base })).?;
    defer std.testing.allocator.free(last_path);
    try std.testing.expectEqual(std.fs.max_path_bytes - 1, last_path.len);

    const boundary_base = try std.testing.allocator.alloc(u8, last_base_len + 1);
    defer std.testing.allocator.free(boundary_base);
    @memset(boundary_base, 'x');
    boundary_base[0] = '/';
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.PathTooLong,
        configPath(failing.allocator(), .{ .xdg_config_home = boundary_base }),
    );
}

test "tier file missing empty valid malformed directory and oversize" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var secure_open_impl: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const secure_open = SecureOpen.Capability.from(&secure_open_impl);

    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ base, "missing" });
    defer std.testing.allocator.free(missing_path);
    var missing = try loadTierFile(std.testing.allocator, std.testing.io, secure_open, missing_path);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(.missing, missing.outcome);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = " \n\t" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid", .data = "{\"x\":1}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = "[]" });
    try tmp.dir.symLink(std.testing.io, "valid", "link", .{});
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    const over = try std.testing.allocator.alloc(u8, maximum_file_bytes + 1);
    defer std.testing.allocator.free(over);
    @memset(over, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "over", .data = over });

    const cases = [_]struct { name: []const u8, outcome: Outcome }{
        .{ .name = "empty", .outcome = .empty },
        .{ .name = "valid", .outcome = .loaded },
        .{ .name = "bad", .outcome = .invalid },
        .{ .name = "link", .outcome = .non_regular },
        .{ .name = "directory", .outcome = .non_regular },
        .{ .name = "over", .outcome = .oversize },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ base, case.name });
        defer std.testing.allocator.free(path);
        var result = try loadTierFile(std.testing.allocator, std.testing.io, secure_open, path);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.outcome, result.outcome);
        try std.testing.expectEqual(case.outcome == .loaded, result.document != null);
    }
}

fn exerciseLoadAllocationFailures(
    allocator: std.mem.Allocator,
    secure_open: SecureOpen.Capability,
    path: []const u8,
) !void {
    var result = try loadTierFile(allocator, std.testing.io, secure_open, path);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.loaded, result.outcome);
}

test "tier load handles every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid", .data = "{\"key\":\"value\"}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "valid", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var secure_open_impl: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLoadAllocationFailures,
        .{ SecureOpen.Capability.from(&secure_open_impl), path },
    );
}

test "injected open OOM propagates and opened kind drift is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "valid", .data = "{}" });
    try tmp.dir.createDir(std.testing.io, "replacement", .default_dir);
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "valid" });
    defer std.testing.allocator.free(path);

    var implementation: TestSecureOpen = .{
        .directory = tmp.dir,
        .base = base,
        .fail_open_oom = true,
    };
    const secure_open = SecureOpen.Capability.from(&implementation);
    try std.testing.expectError(
        error.OutOfMemory,
        loadTierFile(std.testing.allocator, std.testing.io, secure_open, path),
    );

    implementation.fail_open_oom = false;
    implementation.open_substitute = "replacement";
    var result = try loadTierFile(std.testing.allocator, std.testing.io, secure_open, path);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.non_regular, result.outcome);
}

const ReadBufferObserver = struct {
    backing: std.mem.Allocator,
    target_frees: usize = 0,
    target_freed_zeroed: bool = true,

    fn allocator(self: *ReadBufferObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ReadBufferObserver = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *ReadBufferObserver = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ReadBufferObserver = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *ReadBufferObserver = @ptrCast(@alignCast(context));
        if (memory.len == maximum_file_bytes + 1) {
            self.target_frees += 1;
            self.target_freed_zeroed = self.target_freed_zeroed and std.mem.allEqual(u8, memory, 0);
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn observeTierRead(
    bytes: []const u8,
    write_only: bool,
    expected: Outcome,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tier", .data = bytes });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "tier" });
    defer std.testing.allocator.free(path);
    var access: TestSecureOpen = .{
        .directory = tmp.dir,
        .base = base,
        .write_only = write_only,
    };
    var observer: ReadBufferObserver = .{ .backing = std.testing.allocator };
    var result = try loadTierFile(
        observer.allocator(),
        std.testing.io,
        SecureOpen.Capability.from(&access),
        path,
    );
    defer result.deinit(observer.allocator());
    try std.testing.expectEqual(expected, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), observer.target_frees);
    try std.testing.expect(observer.target_freed_zeroed);
}

test "tier read buffer is wiped after normal parse" {
    try observeTierRead("{\"api_key\":\"READ_SECRET\"}", false, .loaded);
}

test "tier read buffer is wiped after invalid JSON" {
    try observeTierRead("{\"api_key\":\"READ_SECRET\"", false, .invalid);
}

test "tier read buffer is wiped after read error" {
    try observeTierRead("{\"api_key\":\"READ_SECRET\"}", true, .unreadable);
}
