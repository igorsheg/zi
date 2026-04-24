const std = @import("std");
const storage = @import("storage.zig");

pub const SinkMode = enum {
    stderr_only,
    file_only,
    stderr_and_file,
    disabled,
};

pub const ThreadLabel = enum {
    unlabeled,
    main,
    tui,
    agent,
    login,
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
    sink_mode: SinkMode,
    agent_dir_override: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Session {
    runtime.shutdown();

    var session = Session{
        .allocator = allocator,
        .log_path = null,
    };
    errdefer session.deinit();

    if (wantsFile(options.sink_mode)) {
        const dir = try storage.getLogDiagnosticsDir(allocator, options.agent_dir_override);
        defer allocator.free(dir);
        try std.fs.cwd().makePath(dir);

        const file_name = try std.fmt.allocPrint(allocator, "zi-{d}.log", .{std.time.milliTimestamp()});
        defer allocator.free(file_name);

        const path = try std.fs.path.join(allocator, &.{ dir, file_name });
        errdefer allocator.free(path);

        const file = try createFile(path);
        errdefer file.close();

        session.log_path = path;
        runtime.configure(options.sink_mode, file);
    } else {
        runtime.configure(options.sink_mode, null);
    }

    runtime.emitBootLine(session.log_path);
    return session;
}

pub fn writeSnapshotFile(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const dir = try storage.getLogDiagnosticsDir(allocator, agent_dir_override);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const file_name = try std.fmt.allocPrint(allocator, "recent-{d}.log", .{std.time.milliTimestamp()});
    defer allocator.free(file_name);

    const path = try std.fs.path.join(allocator, &.{ dir, file_name });
    errdefer allocator.free(path);

    const file = try createFile(path);
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try runtime.writeSnapshot(&writer.interface);
    try writer.end();
    return path;
}

pub fn setThreadLabel(label: ThreadLabel) void {
    current_thread_label = label;
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

    var message_buf: [max_message_bytes]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, format, args) catch "log message too large";

    var line_buf: [max_line_bytes]u8 = undefined;
    const line = formatLineText(&line_buf, .{
        .timestamp_ms = std.time.milliTimestamp(),
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
    mutex: std.Thread.Mutex = .{},
    configured: bool = false,
    stderr_enabled: bool = false,
    file: ?std.fs.File = null,
    recent: RingBuffer = .{},

    fn configure(self: *Runtime, sink_mode: SinkMode, file: ?std.fs.File) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.configured = true;
        self.stderr_enabled = wantsStderr(sink_mode);
        self.file = file;
        self.recent.clear();
    }

    fn shutdown(self: *Runtime) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file) |file| file.close();
        self.file = null;
        self.stderr_enabled = false;
        self.configured = false;
        self.recent.clear();
    }

    fn isConfigured(self: *Runtime) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
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
            .timestamp_ms = std.time.milliTimestamp(),
            .level = "info",
            .scope_name = "logging",
            .thread_label = @tagName(current_thread_label),
            .message = message,
        });
        self.emitLine(line);
    }

    fn emitLine(self: *Runtime, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.emitLineLocked(line);
    }

    fn emitLineLocked(self: *Runtime, line: []const u8) void {
        self.recent.append(line);

        if (self.file) |file| {
            file.writeAll(line) catch {};
            file.writeAll("\n") catch {};
        }
        if (self.stderr_enabled) writeStderrLine(line);
    }

    fn writeSnapshot(self: *Runtime, writer: *std.Io.Writer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try writer.writeAll("zi recent logs\n");
        try writer.print("generated_at_unix_ms: {d}\n\n", .{std.time.milliTimestamp()});
        try self.recent.writeAll(writer);
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

fn wantsFile(mode: SinkMode) bool {
    return switch (mode) {
        .file_only, .stderr_and_file => true,
        .stderr_only, .disabled => false,
    };
}

fn wantsStderr(mode: SinkMode) bool {
    return switch (mode) {
        .stderr_only, .stderr_and_file => true,
        .file_only, .disabled => false,
    };
}

fn writeStderrLine(line: []const u8) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    stderr.print("{s}\n", .{line}) catch {};
}

fn createFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{});
    return std.fs.cwd().createFile(path, .{});
}

test "formatLineText includes metadata" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = formatLineText(&buf, .{
        .timestamp_ms = 42,
        .level = "warning",
        .scope_name = "storage",
        .thread_label = "agent",
        .message = "hello",
    });

    try std.testing.expectEqualStrings("42 [warning] [storage] [agent] hello", line);
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
