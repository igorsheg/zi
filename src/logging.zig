const std = @import("std");
const storage = @import("storage.zig");

pub const SinkMode = enum {
    stderr_only,
    file_only,
    stderr_and_file,
    disabled,
};

pub const SinkOptions = struct {
    stderr: bool = false,
    file: bool = false,
    file_path: ?[]const u8 = null,
};

pub fn sinkOptionsFromMode(mode: SinkMode) SinkOptions {
    return switch (mode) {
        .stderr_only => .{ .stderr = true },
        .file_only => .{ .file = true },
        .stderr_and_file => .{ .stderr = true, .file = true },
        .disabled => .{},
    };
}

pub const ThreadLabel = enum {
    unlabeled,
    main,
    tui,
    agent,
    login,
    system_worker,
    ai_worker,
    session_index,
    zio_worker,
    process_engine,
    cancel_waiter,
    batch,
    @"test",
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    log_path: ?[]const u8,

    pub fn deinit(self: *Session) void {
        runtime.shutdown();
        if (self.log_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub const InitOptions = struct {
    io: std.Io = std.Options.debug_io,
    sinks: SinkOptions,
    min_level: std.log.Level = .info,
    agent_dir_override: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Session {
    runtime.shutdown();

    var session = Session{
        .allocator = allocator,
        .log_path = null,
    };
    errdefer session.deinit();

    if (options.sinks.file) {
        const path = if (options.sinks.file_path) |explicit|
            try allocator.dupe(u8, explicit)
        else blk: {
            const dir = try storage.getLogDiagnosticsDir(allocator, options.agent_dir_override);
            defer allocator.free(dir);
            try std.Io.Dir.cwd().createDirPath(options.io, dir);

            const file_name = try std.fmt.allocPrint(allocator, "zi-{d}.log", .{std.Io.Timestamp.now(options.io, .real).toMilliseconds()});
            defer allocator.free(file_name);
            break :blk try std.fs.path.join(allocator, &.{ dir, file_name });
        };
        errdefer allocator.free(path);

        const file = try createFile(options.io, path);
        errdefer file.close(options.io);

        session.log_path = path;
        runtime.configure(options.io, options.sinks, options.min_level, file, session.log_path);
    } else {
        runtime.configure(options.io, options.sinks, options.min_level, null, null);
    }

    runtime.emitBootLine(session.log_path);
    return session;
}

pub fn writeSnapshotFile(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    return writeSnapshotFileWithIo(std.Options.debug_io, allocator, agent_dir_override);
}

pub fn writeSnapshotFileWithIo(io: std.Io, allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const dir = try storage.getLogDiagnosticsDir(allocator, agent_dir_override);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file_name = try std.fmt.allocPrint(allocator, "recent-{d}.log", .{std.Io.Timestamp.now(io, .real).toMilliseconds()});
    defer allocator.free(file_name);

    const path = try std.fs.path.join(allocator, &.{ dir, file_name });
    errdefer allocator.free(path);

    const file = try createFile(io, path);
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try runtime.writeSnapshot(&writer.interface);
    try writer.end();
    return path;
}

pub fn setThreadLabel(label: ThreadLabel) void {
    current_thread_label = label;
}

pub fn currentLogPath() ?[]const u8 {
    return runtime.currentLogPath();
}

pub fn writeSnapshotFileDefault(allocator: std.mem.Allocator) ![]const u8 {
    return writeSnapshotFileWithIo(runtime.io, allocator, null);
}

pub fn recentSnapshotAlloc(allocator: std.mem.Allocator) ![]u8 {
    return runtime.recentSnapshotAlloc(allocator);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!runtime.isConfigured()) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }
    if (!runtime.shouldLog(level)) return;

    var message_buf: [max_message_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, format, args) catch "log message too large";

    var line_buf: [max_line_bytes]u8 = undefined;
    const line = formatLineText(&line_buf, .{
        .timestamp_ms = std.Io.Timestamp.now(runtime.io, .real).toMilliseconds(),
        .level = level.asText(),
        .scope_name = @tagName(scope),
        .thread_label = @tagName(current_thread_label),
        .message = message,
    });

    runtime.emitLine(line);
}

const max_message_bytes = 512;
const max_line_bytes = 768;
const max_recent_entries = 128;

threadlocal var current_thread_label: ThreadLabel = .unlabeled;
var runtime: Runtime = .{};

const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    configured: bool = false,
    min_level: std.log.Level = .info,
    stderr_enabled: bool = false,
    file: ?std.Io.File = null,
    log_path: ?[]const u8 = null,
    recent: RingBuffer = .{},
    io: std.Io = std.Options.debug_io,

    fn configure(self: *Runtime, io: std.Io, sinks: SinkOptions, min_level: std.log.Level, file: ?std.Io.File, log_path: ?[]const u8) void {
        self.io = io;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.configured = true;
        self.min_level = min_level;
        self.stderr_enabled = sinks.stderr;
        self.file = file;
        self.log_path = log_path;
        self.recent.clear();
    }

    fn shutdown(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file) |file| file.close(self.io);
        self.file = null;
        self.log_path = null;
        self.stderr_enabled = false;
        self.configured = false;
        self.recent.clear();
    }

    fn isConfigured(self: *Runtime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.configured;
    }

    fn emitBootLine(self: *Runtime, log_path: ?[]const u8) void {
        if (!self.isConfigured()) return;

        var message_buf: [max_message_bytes]u8 = undefined;
        const message = if (log_path) |path|
            std.fmt.bufPrint(&message_buf, "logging initialized → {s}", .{path}) catch "logging initialized"
        else
            "logging initialized";

        var line_buf: [max_line_bytes]u8 = undefined;
        const line = formatLineText(&line_buf, .{
            .timestamp_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
            .level = "info",
            .scope_name = "logging",
            .thread_label = @tagName(current_thread_label),
            .message = message,
        });
        self.emitLine(line);
    }

    fn shouldLog(self: *Runtime, comptime level: std.log.Level) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return levelRank(level) >= levelRank(self.min_level);
    }

    fn currentLogPath(self: *Runtime) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.log_path;
    }

    fn emitLine(self: *Runtime, line: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.emitLineLocked(line);
    }

    fn emitLineLocked(self: *Runtime, line: []const u8) void {
        self.recent.append(line);

        if (self.file) |file| {
            var buf: [1024]u8 = undefined;
            var writer = file.writer(self.io, &buf);
            writer.interface.writeAll(line) catch {};
            writer.interface.writeAll("\n") catch {};
            writer.end() catch {};
        }
        if (self.stderr_enabled) writeStderrLine(line);
    }

    fn writeSnapshot(self: *Runtime, writer: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try writer.writeAll("zi recent logs\n");
        try writer.print("generated_at_unix_ms: {d}\n\n", .{std.Io.Timestamp.now(self.io, .real).toMilliseconds()});
        try self.recent.writeAll(writer);
    }

    fn recentSnapshotAlloc(self: *Runtime, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeSnapshot(&out.writer);
        return out.toOwnedSlice();
    }
};

const RingBuffer = struct {
    entries: [max_recent_entries]Entry = [_]Entry{.{}} ** max_recent_entries,
    next_index: usize = 0,
    count: usize = 0,

    fn clear(self: *RingBuffer) void {
        self.next_index = 0;
        self.count = 0;
        for (&self.entries) |*entry| entry.clear();
    }

    fn append(self: *RingBuffer, line: []const u8) void {
        self.entries[self.next_index].set(line);
        self.next_index = (self.next_index + 1) % self.entries.len;
        self.count = @min(self.count + 1, self.entries.len);
    }

    fn writeAll(self: *const RingBuffer, writer: *std.Io.Writer) !void {
        const start = if (self.count == self.entries.len) self.next_index else 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (start + i) % self.entries.len;
            const entry = self.entries[idx];
            if (entry.len == 0) continue;
            try writer.writeAll(entry.slice());
            try writer.writeByte('\n');
        }
    }
};

const Entry = struct {
    len: u16 = 0,
    bytes: [max_line_bytes]u8 = [_]u8{0} ** max_line_bytes,

    fn clear(self: *Entry) void {
        self.len = 0;
    }

    fn set(self: *Entry, line: []const u8) void {
        const n = @min(line.len, self.bytes.len);
        @memcpy(self.bytes[0..n], line[0..n]);
        self.len = @intCast(n);
    }

    fn slice(self: *const Entry) []const u8 {
        return self.bytes[0..self.len];
    }
};

const FormatFields = struct {
    timestamp_ms: i64,
    level: []const u8,
    scope_name: []const u8,
    thread_label: []const u8,
    message: []const u8,
};

fn formatLineText(buf: *[max_line_bytes]u8, fields: FormatFields) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d} [{s}] [{s}] [{s}] {s}",
        .{ fields.timestamp_ms, fields.level, fields.scope_name, fields.thread_label, fields.message },
    ) catch std.fmt.bufPrint(
        buf,
        "{d} [error] [logging] [{s}] log message too large",
        .{ fields.timestamp_ms, fields.thread_label },
    ) catch "log message too large";
}

fn levelRank(level: std.log.Level) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn writeStderrLine(line: []const u8) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print("{s}\n", .{line}) catch {};
}

fn createFile(io: std.Io, path: []const u8) !std.Io.File {
    const flags: std.Io.Dir.CreateFileOptions = .{ .truncate = true };
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.createFileAbsolute(io, path, flags);
    return std.Io.Dir.cwd().createFile(io, path, flags);
}

test "min level filters file output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var orig = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer orig.close(std.testing.io);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentDir(std.testing.io, orig) catch {};

    var session = try init(std.testing.allocator, .{
        .io = std.testing.io,
        .sinks = .{ .file = true, .file_path = "filtered.log" },
        .min_level = .warn,
    });
    defer session.deinit();

    logFn(.debug, .test_scope, "hidden", .{});
    logFn(.warn, .test_scope, "visible", .{});

    var buf: [4096]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(std.testing.io, "filtered.log", &buf);
    try std.testing.expect(std.mem.indexOf(u8, contents, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "visible") != null);
}

test "current log path is exposed while session is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var orig = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer orig.close(std.testing.io);
    try std.process.setCurrentDir(std.testing.io, tmp.dir);
    defer std.process.setCurrentDir(std.testing.io, orig) catch {};

    var session = try init(std.testing.allocator, .{
        .io = std.testing.io,
        .sinks = .{ .file = true, .file_path = "active.log" },
    });
    defer session.deinit();

    try std.testing.expect(currentLogPath() != null);
    try std.testing.expectEqualStrings("active.log", currentLogPath().?);
}

test "ring buffer keeps newest entries" {
    var ring: RingBuffer = .{};
    var i: usize = 0;
    while (i < max_recent_entries + 2) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line-{d}", .{i});
        ring.append(line);
    }

    try std.testing.expectEqual(@as(usize, max_recent_entries), ring.count);
    try std.testing.expectEqualStrings("line-2", ring.entries[ring.next_index].slice());
}
