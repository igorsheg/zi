const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../agent/root.zig");
const text = @import("../text/root.zig");

const ProcessFacts = @This();

pub const os_release_max_bytes: usize = 64 * 1024;
pub const maximum_description_bytes: usize = 3 * os_release_max_bytes + 1024;

pub const Error = error{OutOfMemory};

pub const Options = struct {
    /// A borrowed PATH snapshot. Null and empty mean no searchable commands.
    path_env: ?[]const u8 = null,
    /// Test seams. Production callers should leave these at their defaults.
    os_release_primary: []const u8 = "/etc/os-release",
    os_release_fallback: []const u8 = "/usr/lib/os-release",
};

const ProbeState = struct {
    facts: agent.Context.ToolFacts,

    pub fn available(self: *ProbeState, name: []const u8) bool {
        if (std.mem.eql(u8, name, "rg")) return self.facts.rg;
        if (std.mem.eql(u8, name, "fd")) return self.facts.fd;
        if (std.mem.eql(u8, name, "jq")) return self.facts.jq;
        if (std.mem.eql(u8, name, "gh")) return self.facts.gh;
        if (std.mem.eql(u8, name, "python3")) return self.facts.python3;
        if (std.mem.eql(u8, name, "node")) return self.facts.node;
        if (std.mem.eql(u8, name, "magick")) return self.facts.magick;
        return false;
    }
};

allocator: std.mem.Allocator,
os_description: []u8,
probe_state: *ProbeState,

/// Collects an owned, stable process snapshot. No environment lookup or child
/// process is performed. `path_env` is borrowed only for this call.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_env: ?[]const u8,
) Error!ProcessFacts {
    return initWithOptions(allocator, io, .{ .path_env = path_env });
}

pub fn initWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) Error!ProcessFacts {
    const description = try collectOsDescription(allocator, io, options);
    errdefer allocator.free(description);
    const probe_state = try allocator.create(ProbeState);
    errdefer allocator.destroy(probe_state);
    probe_state.* = .{ .facts = collectToolFacts(io, options.path_env orelse "") };
    return .{
        .allocator = allocator,
        .os_description = description,
        .probe_state = probe_state,
    };
}

pub fn deinit(self: *ProcessFacts) void {
    self.allocator.destroy(self.probe_state);
    self.allocator.free(self.os_description);
    self.* = undefined;
}

/// Returns the sanitized OS description borrowed until `deinit`. The slice
/// remains stable when this move-only ProcessFacts handle is moved.
pub fn osDescription(self: *const ProcessFacts) []const u8 {
    return self.os_description;
}

pub fn toolFacts(self: *const ProcessFacts) agent.Context.ToolFacts {
    return self.probe_state.facts;
}

/// Returns an erased probe whose address remains valid when ProcessFacts is
/// moved. It borrows the heap state owned by this value until `deinit`.
pub fn toolProbe(self: *const ProcessFacts) agent.EnvironmentDiscovery.ToolProbe {
    return .from(self.probe_state);
}

fn collectToolFacts(io: std.Io, path: []const u8) agent.Context.ToolFacts {
    return .{
        .rg = commandAvailable(io, path, "rg"),
        .fd = commandAvailable(io, path, "fd"),
        .jq = commandAvailable(io, path, "jq"),
        .gh = commandAvailable(io, path, "gh"),
        .python3 = commandAvailable(io, path, "python3"),
        .node = commandAvailable(io, path, "node"),
        .magick = commandAvailable(io, path, "magick"),
    };
}

fn commandAvailable(io: std.Io, path: []const u8, name: []const u8) bool {
    var candidate: [std.fs.max_path_bytes]u8 = undefined;
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |directory| {
        // Deliberate security narrowing from execvp: empty and relative entries
        // are ignored, so a PATH snapshot can never select from ambient cwd.
        if (directory.len == 0 or directory[0] != '/' or
            std.mem.findScalar(u8, directory, 0) != null) continue;
        const separator_len: usize = if (directory.len == 1 or directory[directory.len - 1] == '/') 0 else 1;
        const needed = std.math.add(usize, directory.len, separator_len + name.len) catch continue;
        if (needed > candidate.len) continue;
        @memcpy(candidate[0..directory.len], directory);
        var end = directory.len;
        if (separator_len != 0) {
            candidate[end] = '/';
            end += 1;
        }
        @memcpy(candidate[end..needed], name);
        if (regularExecutable(io, candidate[0..needed])) return true;
    }
    return false;
}

fn regularExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.access(.cwd(), io, path, .{ .execute = true }) catch return false;
    const stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn collectOsDescription(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) Error![]u8 {
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);

    var distribution: ?[]u8 = null;
    if (std.mem.eql(u8, sysname, "Linux")) {
        distribution = try linuxDistribution(allocator, io, options);
    }
    defer if (distribution) |value| allocator.free(value);

    return formatOsDescription(allocator, sysname, release, distribution);
}

fn formatOsDescription(
    allocator: std.mem.Allocator,
    sysname: []const u8,
    release: []const u8,
    distribution: ?[]const u8,
) Error![]u8 {
    const raw = if (distribution) |value|
        try std.fmt.allocPrint(allocator, "{s} (Linux {s})", .{ value, release })
    else if (std.mem.eql(u8, sysname, "Darwin"))
        try std.fmt.allocPrint(allocator, "macOS (Darwin {s})", .{release})
    else
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ sysname, release });
    defer allocator.free(raw);
    return text.Utf8.sanitize(allocator, raw, maximum_description_bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => unreachable,
    };
}

fn linuxDistribution(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) Error!?[]u8 {
    const primary = readOsRelease(allocator, io, options.os_release_primary) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return readFallback(allocator, io, options.os_release_fallback),
        error.Unavailable => return null,
    };
    defer allocator.free(primary);
    return parseOsRelease(allocator, primary);
}

fn readFallback(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!?[]u8 {
    const bytes = readOsRelease(allocator, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir, error.Unavailable => return null,
    };
    defer allocator.free(bytes);
    return parseOsRelease(allocator, bytes);
}

const ReadError = error{ OutOfMemory, FileNotFound, NotDir, Unavailable };

fn readOsRelease(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ReadError![]u8 {
    // Production paths and injected test paths are trusted namespaces. The
    // pre-stat prevents an accidental FIFO/device from blocking on open. A
    // namespace swap remains within that explicit trust boundary; the opened
    // handle is still checked again before it is read.
    const path_stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        else => error.Unavailable,
    };
    if (path_stat.kind != .file or path_stat.size > os_release_max_bytes) return error.Unavailable;
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        else => error.Unavailable,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.Unavailable;
    if (stat.kind != .file or stat.size > os_release_max_bytes) return error.Unavailable;
    const length = std.math.cast(usize, stat.size) orelse return error.Unavailable;
    const capacity = std.math.add(usize, length, 1) catch return error.Unavailable;
    const allocation = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
    errdefer allocator.free(allocation);
    const count = file.readPositionalAll(io, allocation, 0) catch return error.Unavailable;
    if (count != length) return error.Unavailable;
    return allocator.realloc(allocation, length) catch return error.OutOfMemory;
}

/// Parses one complete, non-truncated os-release file. Duplicate keys use the
/// last value. Quotes are removed only when paired; backslash removes itself
/// and quotes the next byte except inside single quotes.
pub fn parseOsRelease(allocator: std.mem.Allocator, bytes: []const u8) Error!?[]u8 {
    const pretty = try lastValue(allocator, bytes, "PRETTY_NAME");
    if (pretty) |value| return value;

    const name = try lastValue(allocator, bytes, "NAME") orelse return null;
    errdefer allocator.free(name);
    const version = try lastValue(allocator, bytes, "VERSION");
    if (version) |value| {
        defer allocator.free(value);
        const combined = try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, value });
        allocator.free(name);
        return combined;
    }
    return name;
}

fn lastValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    key: []const u8,
) Error!?[]u8 {
    var value: ?[]u8 = null;
    errdefer if (value) |owned| allocator.free(owned);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len <= key.len or !std.mem.eql(u8, line[0..key.len], key) or line[key.len] != '=') continue;
        const replacement = try decodeValue(allocator, line[key.len + 1 ..]);
        if (value) |owned| allocator.free(owned);
        value = replacement;
    }
    return value;
}

fn decodeValue(allocator: std.mem.Allocator, input: []const u8) Error!?[]u8 {
    var value = std.mem.trimStart(u8, input, " \t");
    value = std.mem.trimEnd(u8, value, "\r \t");
    var quote: u8 = 0;
    if (value.len >= 2 and (value[0] == '\'' or value[0] == '"') and value[value.len - 1] == value[0]) {
        quote = value[0];
        value = value[1 .. value.len - 1];
    }
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] == '\\' and quote != '\'' and index + 1 < value.len) index += 1;
        try output.append(allocator, value[index]);
    }
    if (output.items.len == 0) return null;
    return @as(?[]u8, try output.toOwnedSlice(allocator));
}

comptime {
    switch (builtin.os.tag) {
        .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => {},
        else => @compileError("cli.ProcessFacts supports only Zi's Unix product targets"),
    }
}

fn expectRelease(input: []const u8, expected: ?[]const u8) !void {
    const parsed = try parseOsRelease(std.testing.allocator, input);
    defer if (parsed) |value| std.testing.allocator.free(value);
    if (expected) |value|
        try std.testing.expectEqualStrings(value, parsed.?)
    else
        try std.testing.expect(parsed == null);
}

test "os-release parser pins hax quoting fallback and duplicate rules" {
    try expectRelease("NAME=ignored\nPRETTY_NAME=\"Test Linux 1.0\"\n", "Test Linux 1.0");
    try expectRelease("NAME='Test Linux'\nVERSION=\"2 (Tree)\"\n", "Test Linux 2 (Tree)");
    try expectRelease("PRETTY_NAME=\"Test \\\"Linux\\\"\"\n", "Test \"Linux\"");
    try expectRelease("PRETTY_NAME='a\\b'\n", "a\\b");
    try expectRelease("PRETTY_NAME=old\nPRETTY_NAME=new\n", "new");
    try expectRelease("PRETTY_NAME=old\nPRETTY_NAME=\"\"\nNAME=fallback\n", "fallback");
    try expectRelease("ID=test\n", null);
}

fn exerciseParserAllocations(allocator: std.mem.Allocator) !void {
    const parsed = try parseOsRelease(
        allocator,
        "PRETTY_NAME=old\nPRETTY_NAME=\n" ++
            "NAME=old\nNAME=Test\nVERSION=0\nVERSION=1\\ 2\n",
    );
    if (parsed) |value| allocator.free(value);
}

test "os-release parser releases all partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseParserAllocations, .{});
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

fn createFifo(path: []const u8, mode: c_uint) !void {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(path_z.ptr, mode));
}

test "os-release reads are capped and primary existence is exclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary", .data = "ID=primary\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fallback", .data = "PRETTY_NAME=fallback\n" });
    const primary = try tmp.dir.realPathFileAlloc(std.testing.io, "primary", std.testing.allocator);
    defer std.testing.allocator.free(primary);
    const fallback = try tmp.dir.realPathFileAlloc(std.testing.io, "fallback", std.testing.allocator);
    defer std.testing.allocator.free(fallback);
    try std.testing.expect((try linuxDistribution(std.testing.allocator, std.testing.io, .{
        .os_release_primary = primary,
        .os_release_fallback = fallback,
    })) == null);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary", .data = "x" ** (os_release_max_bytes + 1) });
    try std.testing.expect((try linuxDistribution(std.testing.allocator, std.testing.io, .{
        .os_release_primary = primary,
        .os_release_fallback = fallback,
    })) == null);
    try tmp.dir.deleteFile(std.testing.io, "primary");
    const selected = (try linuxDistribution(std.testing.allocator, std.testing.io, .{
        .os_release_primary = primary,
        .os_release_fallback = fallback,
    })).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("fallback", selected);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "primary", .data = "file" });
    const not_directory = try std.fmt.allocPrint(std.testing.allocator, "{s}/child", .{primary});
    defer std.testing.allocator.free(not_directory);
    const selected_not_dir = (try linuxDistribution(std.testing.allocator, std.testing.io, .{
        .os_release_primary = not_directory,
        .os_release_fallback = fallback,
    })).?;
    defer std.testing.allocator.free(selected_not_dir);
    try std.testing.expectEqualStrings("fallback", selected_not_dir);

    const fifo_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/fifo", .{std.fs.path.dirname(fallback).?});
    defer std.testing.allocator.free(fifo_path);
    try createFifo(fifo_path, 0o700);
    try std.testing.expectError(
        error.Unavailable,
        readOsRelease(std.testing.allocator, std.testing.io, fifo_path),
    );
}

test "OS description sanitizes invalid distribution bytes" {
    const description = try formatOsDescription(std.testing.allocator, "Linux", "6.0", "Bad\xffLinux\x00");
    defer std.testing.allocator.free(description);
    try std.testing.expectEqualStrings("Bad\xef\xbf\xbdLinux\xef\xbf\xbd (Linux 6.0)", description);
}

test "owned OS description sanitizes invalid os-release bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "release",
        .data = "PRETTY_NAME=Bad\xffLinux\x00\n",
    });
    const release = try tmp.dir.realPathFileAlloc(std.testing.io, "release", std.testing.allocator);
    defer std.testing.allocator.free(release);
    var facts = try initWithOptions(std.testing.allocator, std.testing.io, .{
        .path_env = "",
        .os_release_primary = release,
        .os_release_fallback = release,
    });
    defer facts.deinit();
    try std.testing.expect(std.unicode.utf8ValidateSlice(facts.osDescription()));
    try std.testing.expect(std.mem.indexOf(u8, facts.osDescription(), "Bad\xef\xbf\xbdLinux\xef\xbf\xbd") != null);
}

test "absent and empty PATH never use a target or ambient default" {
    var absent = try init(std.testing.allocator, std.testing.io, null);
    defer absent.deinit();
    var empty = try init(std.testing.allocator, std.testing.io, "");
    defer empty.deinit();
    const expected: agent.Context.ToolFacts = .{};
    try std.testing.expectEqualDeep(expected, absent.toolFacts());
    try std.testing.expectEqualDeep(expected, empty.toolFacts());
}

test "tool facts use executable regular files and ignore unsafe PATH entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "first/rg", .data = "not executable" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second/rg", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second/jq", .data = "#!/bin/sh\n" });
    const first = try tmp.dir.realPathFileAlloc(std.testing.io, "first", std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try tmp.dir.realPathFileAlloc(std.testing.io, "second", std.testing.allocator);
    defer std.testing.allocator.free(second);
    const fifo = try std.fmt.allocPrint(std.testing.allocator, "{s}/fd", .{second});
    defer std.testing.allocator.free(fifo);
    try createFifo(fifo, 0o700);
    for ([_]struct { name: []const u8, mode: std.posix.mode_t }{
        .{ .name = "second/rg", .mode = 0o700 },
        .{ .name = "second/jq", .mode = 0o100 },
    }) |entry| {
        const file = try tmp.dir.openFile(std.testing.io, entry.name, .{});
        defer file.close(std.testing.io);
        try file.setPermissions(std.testing.io, .fromMode(entry.mode));
    }
    const path = try std.fmt.allocPrint(std.testing.allocator, ":relative:{s}:{s}", .{ first, second });
    defer std.testing.allocator.free(path);

    var facts = try init(std.testing.allocator, std.testing.io, path);
    const probe = facts.toolProbe();
    const copied = facts.toolFacts();
    var moved = facts;
    defer moved.deinit();
    try std.testing.expect(copied.rg);
    try std.testing.expect(copied.jq);
    try std.testing.expect(!copied.fd);
    try std.testing.expect(probe.available("rg"));
    try std.testing.expect(!probe.available("unknown"));
}
