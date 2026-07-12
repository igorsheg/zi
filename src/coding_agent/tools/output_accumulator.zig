const std = @import("std");
const output_tail = @import("output_tail.zig");

const default_temp_file_prefix = "zi-output";

pub const Snapshot = struct {
    content: []const u8,
    dropped_bytes: usize,
    dropped_lines: usize,
    last_line_partial: bool,
    total_bytes: usize,
    total_lines: usize,
    truncated: bool,
    full_output_path: ?[]const u8 = null,
};

pub const Options = struct {
    max_bytes: usize,
    max_lines: usize,
    temp_dir: ?[]const u8 = null,
    temp_file_prefix: []const u8 = default_temp_file_prefix,
};

pub const OutputAccumulator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    tail: []u8 = &.{},
    raw_prefix: std.ArrayList(u8) = .empty,
    raw_prefix_discarded: bool = false,
    full_output_path: ?[]u8 = null,
    full_output_file: ?std.Io.File = null,
    dropped_bytes: usize = 0,
    dropped_lines: usize = 0,
    last_line_partial: bool = false,
    total_bytes: usize = 0,
    completed_lines: usize = 0,
    current_line_has_bytes: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) OutputAccumulator {
        std.debug.assert(options.max_bytes > 0);
        std.debug.assert(options.max_lines > 0);
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn deinit(self: *OutputAccumulator) void {
        self.finish();
        self.allocator.free(self.tail);
        self.raw_prefix.deinit(self.allocator);
        if (self.full_output_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn append(self: *OutputAccumulator, bytes: []const u8) !void {
        std.debug.assert(!self.finished);
        try self.rememberFullOutput(bytes);
        self.total_bytes += bytes.len;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.completed_lines += 1;
                self.current_line_has_bytes = false;
            } else {
                self.current_line_has_bytes = true;
            }
        }
        const next = try output_tail.appendTail(self.allocator, self.tail, bytes, .{
            .max_bytes = self.options.max_bytes,
            .max_lines = self.options.max_lines,
        });
        errdefer self.allocator.free(next.bytes);
        self.allocator.free(self.tail);
        self.tail = next.bytes;
        self.dropped_bytes += next.dropped_bytes;
        self.dropped_lines += next.dropped_lines;
        self.last_line_partial = next.last_line_partial;
        if (self.isTruncated()) try self.ensureFullOutputFile();
    }

    pub fn finish(self: *OutputAccumulator) void {
        if (self.finished) return;
        self.finished = true;
        if (self.full_output_file) |file| {
            file.close(self.io);
            self.full_output_file = null;
        }
    }

    pub fn snapshot(self: OutputAccumulator) Snapshot {
        const truncated = self.isTruncated();
        return .{
            .content = self.tail,
            .dropped_bytes = self.dropped_bytes,
            .dropped_lines = self.dropped_lines,
            .last_line_partial = self.last_line_partial,
            .total_bytes = self.total_bytes,
            .total_lines = self.totalLines(),
            .truncated = truncated,
            .full_output_path = if (truncated) self.full_output_path else null,
        };
    }

    pub fn totalLines(self: OutputAccumulator) usize {
        return self.completed_lines + @intFromBool(self.current_line_has_bytes);
    }

    fn isTruncated(self: OutputAccumulator) bool {
        return self.total_bytes > self.options.max_bytes or self.totalLines() > self.options.max_lines;
    }

    fn rememberFullOutput(self: *OutputAccumulator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.full_output_file) |file| {
            file.writeStreamingAll(self.io, bytes) catch {
                self.disableFullOutputFile(file);
            };
            return;
        }
        if (!self.raw_prefix_discarded) try self.raw_prefix.appendSlice(self.allocator, bytes);
    }

    fn ensureFullOutputFile(self: *OutputAccumulator) !void {
        if (self.full_output_file != null or self.full_output_path != null or self.raw_prefix_discarded) return;
        const temp_dir = self.options.temp_dir orelse {
            self.discardRawPrefix();
            return;
        };
        if (!std.fs.path.isAbsolute(temp_dir)) {
            self.discardRawPrefix();
            return;
        }

        const created = self.createFullOutputFile(temp_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.discardRawPrefix();
                return;
            },
        };
        errdefer {
            created.file.close(self.io);
            self.allocator.free(created.path);
        }
        if (self.raw_prefix.items.len > 0) {
            created.file.writeStreamingAll(self.io, self.raw_prefix.items) catch {
                created.file.close(self.io);
                self.allocator.free(created.path);
                self.discardRawPrefix();
                return;
            };
        }
        self.discardRawPrefix();
        self.full_output_path = created.path;
        self.full_output_file = created.file;
    }

    fn disableFullOutputFile(self: *OutputAccumulator, file: std.Io.File) void {
        file.close(self.io);
        self.full_output_file = null;
        if (self.full_output_path) |path| {
            self.allocator.free(path);
            self.full_output_path = null;
        }
        self.discardRawPrefix();
    }

    const CreatedFile = struct {
        path: []u8,
        file: std.Io.File,
    };

    fn createFullOutputFile(self: *OutputAccumulator, temp_dir: []const u8) !CreatedFile {
        const stamp = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        var attempt: usize = 0;
        while (attempt < 64) : (attempt += 1) {
            const basename = try std.fmt.allocPrint(self.allocator, "{s}-{d}-{d}.log", .{ self.options.temp_file_prefix, stamp, attempt });
            defer self.allocator.free(basename);
            const path = try std.fs.path.join(self.allocator, &.{ temp_dir, basename });
            errdefer self.allocator.free(path);
            const file = std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            return .{ .path = path, .file = file };
        }
        return error.PathAlreadyExists;
    }

    fn discardRawPrefix(self: *OutputAccumulator) void {
        self.raw_prefix.deinit(self.allocator);
        self.raw_prefix = .empty;
        self.raw_prefix_discarded = true;
    }
};

test "output accumulator keeps bounded tail and totals" {
    var acc = OutputAccumulator.init(std.testing.allocator, std.testing.io, .{ .max_bytes = 20, .max_lines = 2 });
    defer acc.deinit();
    try acc.append("one\ntwo\nthree\nfour");
    acc.finish();
    const snap = acc.snapshot();
    try std.testing.expectEqualStrings("three\nfour", snap.content);
    try std.testing.expect(snap.truncated);
    try std.testing.expectEqual(@as(usize, 4), snap.total_lines);
}

test "output accumulator spills full output once truncated" {
    var fixture = try @import("test_support.zig").Fixture.init("repo");
    defer fixture.deinit();

    var acc = OutputAccumulator.init(std.testing.allocator, std.testing.io, .{
        .max_bytes = 16,
        .max_lines = 2,
        .temp_dir = fixture.cwd(),
        .temp_file_prefix = "zi-bash-test",
    });
    defer acc.deinit();
    try acc.append("one\ntwo\nthree\n");
    acc.finish();

    const snap = acc.snapshot();
    const path = snap.full_output_path orelse return error.MissingFullOutputPath;
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const len = try file.length(std.testing.io);
    const data = try std.testing.allocator.alloc(u8, @intCast(len));
    defer std.testing.allocator.free(data);
    const read_len = try file.readPositionalAll(std.testing.io, data, 0);
    try std.testing.expectEqual(data.len, read_len);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", data);
}

test "output accumulator still returns tail when spill path is unavailable" {
    var acc = OutputAccumulator.init(std.testing.allocator, std.testing.io, .{
        .max_bytes = 8,
        .max_lines = 2,
        .temp_dir = "relative-temp-dir",
    });
    defer acc.deinit();

    try acc.append("one\ntwo\nthree\n");
    acc.finish();
    const snap = acc.snapshot();
    try std.testing.expect(snap.truncated);
    try std.testing.expect(snap.full_output_path == null);
    try std.testing.expectEqualStrings("three", snap.content);
}
