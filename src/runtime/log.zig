const std = @import("std");

pub const ThreadLabel = enum {
    unlabeled,
    main,
    runtime,
    agent,
    ai,
    session,
    @"test",
};

pub const Sink = enum {
    disabled,
    stderr,
    file,
    stderr_and_file,
};

pub const Options = struct {
    io: std.Io,
    sink: Sink = .stderr,
    min_level: std.log.Level = .info,
    file_path: ?[]const u8 = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    path: ?[]const u8 = null,

    pub fn deinit(self: *Session) void {
        state.shutdown();
        if (self.path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator, options: Options) !Session {
    state.shutdown();

    var session: Session = .{ .allocator = allocator };
    errdefer session.deinit();

    var file: ?std.Io.File = null;
    if (options.sink == .file or options.sink == .stderr_and_file) {
        const path = options.file_path orelse return error.MissingLogFilePath;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        file = try std.Io.Dir.cwd().createFile(options.io, owned_path, .{ .truncate = true });
        session.path = owned_path;
    }

    state.configure(.{
        .io = options.io,
        .min_level = options.min_level,
        .stderr = options.sink == .stderr or options.sink == .stderr_and_file,
        .file = file,
    });

    std.log.info("log initialized", .{});
    return session;
}

pub fn setThreadLabel(label: ThreadLabel) void {
    thread_label = label;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!state.enabled(level)) return;

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch "log message too large";

    var line_buf: [1400]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d} {s} {s} {s}: {s}\n", .{
        std.Io.Timestamp.now(state.io(), .real).toMilliseconds(),
        level.asText(),
        @tagName(scope),
        @tagName(thread_label),
        msg,
    }) catch return;

    state.write(line);
}

threadlocal var thread_label: ThreadLabel = .unlabeled;
var state: State = .{};

const State = struct {
    mutex: std.Io.Mutex = .init,
    configured: bool = false,
    io_value: ?std.Io = null,
    min_level: std.log.Level = .info,
    stderr: bool = false,
    file: ?std.Io.File = null,

    const Configure = struct {
        io: std.Io,
        min_level: std.log.Level,
        stderr: bool,
        file: ?std.Io.File,
    };

    fn configure(self: *State, config: Configure) void {
        self.mutex.lockUncancelable(config.io);
        defer self.mutex.unlock(config.io);
        self.io_value = config.io;
        self.min_level = config.min_level;
        self.stderr = config.stderr;
        self.file = config.file;
        self.configured = true;
    }

    fn shutdown(self: *State) void {
        const io_value = self.io_value orelse return;
        self.mutex.lockUncancelable(io_value);
        defer self.mutex.unlock(io_value);
        if (self.file) |file| file.close(io_value);
        self.file = null;
        self.stderr = false;
        self.configured = false;
    }

    fn enabled(self: *State, comptime level: std.log.Level) bool {
        const io_value = self.io_value orelse return false;
        self.mutex.lockUncancelable(io_value);
        defer self.mutex.unlock(io_value);
        if (!self.configured) return true;
        return rank(level) >= rank(self.min_level);
    }

    fn io(self: *State) std.Io {
        return self.io_value orelse std.debug.panic("log io requested before runtime log init", .{});
    }

    fn write(self: *State, line: []const u8) void {
        const io_value = self.io_value orelse return;
        self.mutex.lockUncancelable(io_value);
        defer self.mutex.unlock(io_value);

        if (!self.configured) {
            writeStderr(io_value, line);
            return;
        }
        if (self.stderr) writeStderr(io_value, line);
        if (self.file) |file| file.writeStreamingAll(io_value, line) catch {};
    }
};

fn writeStderr(io: std.Io, line: []const u8) void {
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, line) catch {};
}

fn rank(level: std.log.Level) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

test "runtime log writes to file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "zi.log", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "zi.log", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var session = try init(std.testing.allocator, .{ .io = std.Options.debug_io, .sink = .file, .file_path = path });
    defer session.deinit();

    logFn(.info, .test_scope, "hello {s}", .{"runtime"});

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "hello runtime") != null);
}
