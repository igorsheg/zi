const std = @import("std");
const output_cap = @import("OutputCap.zig");
const text = @import("../text/root.zig");

pub const drain_limit: usize = 16 * 1024 * 1024;
pub const head_divisor: usize = 8;
const memory_cap_max: usize = drain_limit - 64 * 1024;

pub const Options = struct {
    memory_cap: usize = 64 * 1024,
    model_bytes: usize = output_cap.default_output_bytes,
    model_lines: usize = output_cap.maximum_lines,
    result_bytes: usize = 256 * 1024,
    temp_directory: []const u8 = ".zig-cache/tmp",
};

pub const StopReason = enum { none, timeout, interrupt, orphaned };
pub const Status = union(enum) { exited: u8, signaled: u8 };

pub const FinishOptions = struct {
    reason: StopReason = .none,
    timeout_ms: i64 = 0,
    status: Status = .{ .exited = 0 },
};

pub const Error = error{ OutOfMemory, CaptureLimitExceeded, ResultTooLarge };

/// Owns captured bytes and any spill file. `deinit` closes and unlinks the spill.
pub const BashOutput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    memory: std.ArrayList(u8) = .empty,
    file: ?std.Io.File = null,
    path: ?[]u8 = null,
    spilled: bool = false,
    write_failed: bool = false,
    total_bytes: usize = 0,
    newline_count: usize = 0,
    has_partial_line: bool = false,
    binary: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) BashOutput {
        var bounded = options;
        bounded.memory_cap = @min(@min(options.memory_cap, options.model_bytes), memory_cap_max);
        bounded.model_bytes = @min(options.model_bytes, drain_limit);
        bounded.model_lines = @min(options.model_lines, output_cap.maximum_lines);
        return .{ .allocator = allocator, .io = io, .options = bounded };
    }

    pub fn deinit(self: *BashOutput) void {
        self.memory.deinit(self.allocator);
        if (self.file) |file| file.close(self.io);
        if (self.path) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| {
                std.log.warn("unlinking bash spill: {s}", .{@errorName(err)});
            };
            self.allocator.free(path);
        }
        self.* = undefined;
    }

    /// Appends one producer chunk. A chunk that crosses the hard drain limit is rejected whole.
    pub fn append(self: *BashOutput, data: []const u8) Error!void {
        if (data.len > drain_limit -| self.total_bytes) return error.CaptureLimitExceeded;
        if (data.len == 0) return;

        const newlines = countNewlines(data);
        const new_line_count = self.newline_count + newlines + @intFromBool(data[data.len - 1] != '\n');
        if (!self.spilled and self.memory.items.len + data.len <= self.options.memory_cap and
            new_line_count <= self.options.model_lines)
        {
            try self.memory.appendSlice(self.allocator, data);
        } else {
            if (!self.spilled) try self.spill();
            if (!self.write_failed) {
                if (self.file) |file| {
                    file.writeStreamingAll(self.io, data) catch {
                        self.write_failed = true;
                    };
                }
            }
        }
        self.total_bytes += data.len;
        self.newline_count += newlines;
        self.has_partial_line = data[data.len - 1] != '\n';
        self.binary = self.binary or std.mem.findScalar(u8, data, 0) != null;
    }

    pub fn size(self: *const BashOutput) usize {
        return self.total_bytes;
    }

    pub fn rawLineCount(self: *const BashOutput) usize {
        return self.newline_count + @intFromBool(self.has_partial_line);
    }

    pub fn savedPath(self: *const BashOutput) ?[]const u8 {
        return self.path;
    }

    /// Returns an owned, model-facing body and suffix. The spill remains valid until `deinit`.
    pub fn finish(self: *BashOutput, finish_options: FinishOptions) Error![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        if (!self.binary) try self.buildBody(&result);
        try appendSuffix(
            self.allocator,
            &result,
            self.options.result_bytes,
            self.total_bytes,
            self.binary,
            result.items.len > 0,
            finish_options,
        );
        return result.toOwnedSlice(self.allocator);
    }

    fn spill(self: *BashOutput) Error!void {
        self.spilled = true;
        const opened = self.openTemp() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.write_failed = true;
                return;
            },
        };
        self.file = opened.file;
        self.path = opened.path;
        if (self.memory.items.len > 0) {
            opened.file.writeStreamingAll(self.io, self.memory.items) catch {
                self.write_failed = true;
                return;
            };
            self.memory.deinit(self.allocator);
            self.memory = .empty;
        }
    }

    const Opened = struct { file: std.Io.File, path: []u8 };

    fn openTemp(self: *BashOutput) !Opened {
        var random: [12]u8 = undefined;
        var encoded: [48]u8 = undefined;
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            self.io.random(&random);
            const name = std.fmt.bufPrint(&encoded, "bash-{x}.log", .{random}) catch unreachable;
            const path = try std.fs.path.join(self.allocator, &.{ self.options.temp_directory, name });
            errdefer self.allocator.free(path);
            const file = std.Io.Dir.cwd().createFile(self.io, path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.allocator.free(path);
                    continue;
                },
                else => return err,
            };
            return .{ .file = file, .path = path };
        }
        return error.PathAlreadyExists;
    }

    fn buildBody(self: *BashOutput, body: *std.ArrayList(u8)) Error!void {
        if (!self.spilled) {
            return appendSanitized(self.allocator, body, self.memory.items, self.options.result_bytes);
        }
        const line_count = self.rawLineCount();
        if (self.file == null or self.write_failed) {
            var kept_lines: usize = 0;
            if (self.memory.items.len > 0) {
                try appendSanitized(self.allocator, body, self.memory.items, self.options.result_bytes);
                kept_lines = countNewlines(self.memory.items) +
                    @intFromBool(self.memory.items[self.memory.items.len - 1] != '\n');
            }
            var marker_buffer: [256]u8 = undefined;
            const marker = try boundedPrint(
                "\n[output truncated: last {d} of {d} lines, {f} of {f}; " ++
                    "full output unavailable (temp file write failed)]",
                &marker_buffer,
                .{
                    kept_lines,
                    line_count,
                    formatByteSize(self.memory.items.len),
                    formatByteSize(self.total_bytes),
                },
            );
            return appendSanitizedMarker(self.allocator, body, marker, self.options.result_bytes);
        }

        const file = self.file.?;
        const head_cap_bytes = self.options.model_bytes / head_divisor;
        const head_cap_lines = self.options.model_lines / head_divisor;
        const tail_cap_bytes = self.options.model_bytes - head_cap_bytes;
        const tail_cap_lines = self.options.model_lines - head_cap_lines;
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(self.allocator);
        const tail_kept = readTail(
            self.allocator,
            self.io,
            file,
            0,
            self.total_bytes,
            tail_cap_bytes,
            tail_cap_lines,
            &tail,
        ) catch {
            return self.appendReadFailure(body, line_count);
        };
        const tail_offset = self.total_bytes - tail_kept.bytes;
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(self.allocator);
        const head_kept: Kept = readHead(
            self.allocator,
            self.io,
            file,
            0,
            head_cap_bytes,
            head_cap_lines,
            tail_offset,
            &head,
        ) catch .{};
        const omitted_lines = line_count -| (head_kept.lines + tail_kept.lines);
        const gap_bytes = tail_offset -| head_kept.bytes;
        if (head_kept.lines > 0 and gap_bytes > 0) {
            try appendSanitized(self.allocator, body, head.items, self.options.result_bytes);
            var marker_buffer: [std.fs.max_path_bytes + 192]u8 = undefined;
            const marker = if (omitted_lines > 0)
                try boundedPrint(
                    "... [output truncated: omitted {d} of {d} lines " ++
                        "(kept first {d}, last {d}); full output temporarily saved to {s}] ...\n",
                    &marker_buffer,
                    .{ omitted_lines, line_count, head_kept.lines, tail_kept.lines, self.path.? },
                )
            else
                try boundedPrint(
                    "... [output truncated: omitted {f} mid-line; " ++
                        "full output temporarily saved to {s}] ...\n",
                    &marker_buffer,
                    .{ formatByteSize(gap_bytes), self.path.? },
                );
            try appendSanitizedMarker(self.allocator, body, marker, self.options.result_bytes);
            return appendSanitized(self.allocator, body, tail.items, self.options.result_bytes);
        }

        tail.clearRetainingCapacity();
        const full_tail = readTail(
            self.allocator,
            self.io,
            file,
            0,
            self.total_bytes,
            self.options.model_bytes,
            self.options.model_lines,
            &tail,
        ) catch {
            return self.appendReadFailure(body, line_count);
        };
        try appendSanitized(self.allocator, body, tail.items, self.options.result_bytes);
        var marker_buffer: [std.fs.max_path_bytes + 192]u8 = undefined;
        const marker = try boundedPrint(
            "\n[output truncated: last {d} of {d} lines, {f} of {f}; " ++
                "full output temporarily saved to {s}]",
            &marker_buffer,
            .{
                full_tail.lines,
                line_count,
                formatByteSize(full_tail.bytes),
                formatByteSize(self.total_bytes),
                self.path.?,
            },
        );
        try appendSanitizedMarker(self.allocator, body, marker, self.options.result_bytes);
    }

    fn appendReadFailure(self: *BashOutput, body: *std.ArrayList(u8), lines: usize) Error!void {
        var marker_buffer: [128]u8 = undefined;
        const marker = try boundedPrint(
            "\n[output truncated: {d} lines, full output unavailable (spill read failed)]",
            &marker_buffer,
            .{lines},
        );
        try appendSanitizedMarker(self.allocator, body, marker, self.options.result_bytes);
        self.discardSpill();
    }

    fn discardSpill(self: *BashOutput) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
        if (self.path) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| {
                std.log.warn("unlinking bash spill: {s}", .{@errorName(err)});
            };
            self.allocator.free(path);
        }
        self.path = null;
    }
};

const Kept = struct { bytes: usize = 0, lines: usize = 0 };

fn readHead(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    range_start: usize,
    cap_bytes: usize,
    cap_lines: usize,
    limit: usize,
    out: *std.ArrayList(u8),
) !Kept {
    const available = limit -| range_start;
    const amount = @min(cap_bytes, available);
    try out.resize(allocator, amount);
    const got = try file.readPositionalAll(io, out.items, range_start);
    out.shrinkRetainingCapacity(got);
    var last_newline = out.items.len;
    while (last_newline > 0 and out.items[last_newline - 1] != '\n') last_newline -= 1;
    if (last_newline == 0) {
        out.clearRetainingCapacity();
        return .{};
    }
    out.shrinkRetainingCapacity(last_newline);
    var lines = countNewlines(out.items);
    if (lines > cap_lines) {
        var offset: usize = 0;
        var seen: usize = 0;
        while (offset < out.items.len and seen < cap_lines) : (offset += 1) {
            if (out.items[offset] == '\n') seen += 1;
        }
        out.shrinkRetainingCapacity(offset);
        lines = cap_lines;
    }
    return .{ .bytes = out.items.len, .lines = lines };
}

fn readTail(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    range_start: usize,
    range_bytes: usize,
    cap_bytes: usize,
    cap_lines: usize,
    out: *std.ArrayList(u8),
) !Kept {
    const amount = @min(range_bytes, cap_bytes);
    const start = range_start + range_bytes - amount;
    var needs_alignment = false;
    if (start > range_start) {
        var previous: [1]u8 = undefined;
        needs_alignment = (try file.readPositionalAll(io, &previous, start - 1)) != 1 or previous[0] != '\n';
    }
    try out.resize(allocator, amount);
    const got = try file.readPositionalAll(io, out.items, start);
    out.shrinkRetainingCapacity(got);
    if (needs_alignment and out.items.len > 0) {
        if (std.mem.findScalar(u8, out.items, '\n')) |newline| {
            const skip = newline + 1;
            if (skip < out.items.len) replaceWithSuffix(out, skip);
        }
    }
    const newline_count = countNewlines(out.items);
    var lines = newline_count + @intFromBool(out.items.len > 0 and out.items[out.items.len - 1] != '\n');
    if (lines > cap_lines) {
        var skip_lines = lines - cap_lines;
        var offset: usize = 0;
        while (skip_lines > 0 and offset < out.items.len) : (offset += 1) {
            if (out.items[offset] == '\n') skip_lines -= 1;
        }
        replaceWithSuffix(out, offset);
        lines = cap_lines;
    }
    return .{ .bytes = out.items.len, .lines = lines };
}

fn replaceWithSuffix(out: *std.ArrayList(u8), offset: usize) void {
    @memmove(out.items[0 .. out.items.len - offset], out.items[offset..]);
    out.shrinkRetainingCapacity(out.items.len - offset);
}

fn appendSanitized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8, maximum: usize) Error!void {
    const remaining = maximum -| out.items.len;
    const clean = output_cap.capAndSanitize(
        allocator,
        data,
        output_cap.maximum_line_bytes,
        remaining,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.ResultTooLarge,
    };
    defer allocator.free(clean);
    try appendBounded(allocator, out, clean, maximum);
}

fn appendSanitizedMarker(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    marker: []const u8,
    maximum: usize,
) Error!void {
    const clean = text.Utf8.sanitize(allocator, marker, maximum -| out.items.len) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.ResultTooLarge,
    };
    defer allocator.free(clean);
    try appendBounded(allocator, out, clean, maximum);
}

pub fn formatSuffix(
    allocator: std.mem.Allocator,
    maximum: usize,
    total_bytes: usize,
    binary: bool,
    body_present: bool,
    options: FinishOptions,
) Error![]u8 {
    var suffix: std.ArrayList(u8) = .empty;
    errdefer suffix.deinit(allocator);
    try appendSuffix(allocator, &suffix, maximum, total_bytes, binary, body_present, options);
    return suffix.toOwnedSlice(allocator);
}

fn appendSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    maximum: usize,
    total_bytes: usize,
    binary: bool,
    body_present: bool,
    options: FinishOptions,
) Error!void {
    const before = out.items.len;
    if (binary) {
        var buffer: [64]u8 = undefined;
        const marker = try boundedPrint("[binary output suppressed: {f}]", &buffer, .{formatByteSize(total_bytes)});
        try appendBounded(allocator, out, marker, maximum);
    }
    switch (options.reason) {
        .interrupt => try appendBounded(allocator, out, "\n[interrupted]", maximum),
        .timeout => {
            var buffer: [64]u8 = undefined;
            const marker = try boundedPrint("\n[timed out after {f}]", &buffer, .{formatTimeout(options.timeout_ms)});
            try appendBounded(allocator, out, marker, maximum);
        },
        .none, .orphaned => switch (options.status) {
            .exited => |code| if (code != 0) {
                var buffer: [64]u8 = undefined;
                const marker = try boundedPrint("\n[exit {d}]", &buffer, .{code});
                try appendBounded(allocator, out, marker, maximum);
            },
            .signaled => |signal| {
                var buffer: [64]u8 = undefined;
                const marker = try boundedPrint("\n[signal {d}]", &buffer, .{signal});
                try appendBounded(allocator, out, marker, maximum);
            },
        },
    }
    if (options.reason == .orphaned) {
        var buffer: [192]u8 = undefined;
        const marker = try boundedPrint(
            "\n[orphaned processes killed after {f}: a task tracks its shell, " ++
                "so drop '&' or end the command with 'wait']",
            &buffer,
            .{formatTimeout(options.timeout_ms)},
        );
        try appendBounded(allocator, out, marker, maximum);
    }
    if (out.items.len == before and !body_present)
        try appendBounded(allocator, out, "(no output)", maximum);
}

fn boundedPrint(comptime format: []const u8, buffer: []u8, args: anytype) Error![]u8 {
    return std.fmt.bufPrint(buffer, format, args) catch error.ResultTooLarge;
}

fn appendBounded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8, maximum: usize) Error!void {
    if (bytes.len > maximum -| out.items.len) return error.ResultTooLarge;
    try out.appendSlice(allocator, bytes);
}

pub const ByteSize = struct {
    buffer: [16]u8,
    length: usize,
    pub fn format(self: ByteSize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.buffer[0..self.length]);
    }
};

pub fn formatByteSize(bytes: usize) ByteSize {
    var result: ByteSize = .{ .buffer = undefined, .length = 0 };
    const slice = if (bytes < 1024)
        std.fmt.bufPrint(&result.buffer, "{d}B", .{bytes}) catch unreachable
    else if (bytes < 10 * 1024)
        std.fmt.bufPrint(&result.buffer, "{d:.1}K", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch unreachable
    else if (bytes < 1024 * 1024)
        std.fmt.bufPrint(&result.buffer, "{d}K", .{(bytes + 512) / 1024}) catch unreachable
    else if (bytes < 10 * 1024 * 1024)
        std.fmt.bufPrint(
            &result.buffer,
            "{d:.1}M",
            .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)},
        ) catch unreachable
    else
        std.fmt.bufPrint(&result.buffer, "{d}M", .{(bytes + 512 * 1024) / (1024 * 1024)}) catch unreachable;
    result.length = slice.len;
    return result;
}

pub const Timeout = struct {
    buffer: [32]u8,
    length: usize,
    pub fn format(self: Timeout, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.buffer[0..self.length]);
    }
};

fn formatTimeout(milliseconds: i64) Timeout {
    var result: Timeout = .{ .buffer = undefined, .length = 0 };
    const slice = if (@rem(milliseconds, 1000) == 0)
        std.fmt.bufPrint(&result.buffer, "{d}s", .{@divTrunc(milliseconds, 1000)}) catch unreachable
    else
        std.fmt.bufPrint(&result.buffer, "{d}ms", .{milliseconds}) catch unreachable;
    result.length = slice.len;
    return result;
}

fn countNewlines(data: []const u8) usize {
    return std.mem.count(u8, data, "\n");
}

test "byte sizes and status suffixes match hax dialect" {
    try std.testing.expectEqualStrings("12B", formatByteSize(12).buffer[0..formatByteSize(12).length]);
    try std.testing.expectEqualStrings("1.2K", formatByteSize(1229).buffer[0..formatByteSize(1229).length]);
    try std.testing.expectEqualStrings("40K", formatByteSize(40 * 1024).buffer[0..formatByteSize(40 * 1024).length]);
    const one_and_half_megabytes = formatByteSize(1536 * 1024);
    try std.testing.expectEqualStrings(
        "1.5M",
        one_and_half_megabytes.buffer[0..one_and_half_megabytes.length],
    );

    const allocator = std.testing.allocator;
    const empty = try formatSuffix(allocator, 1024, 0, false, false, .{});
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("(no output)", empty);
    const timeout = try formatSuffix(allocator, 1024, 10, false, true, .{
        .reason = .timeout,
        .timeout_ms = 1500,
        .status = .{ .exited = 9 },
    });
    defer allocator.free(timeout);
    try std.testing.expectEqualStrings("\n[timed out after 1500ms]", timeout);
    const orphan = try formatSuffix(allocator, 1024, 0, false, false, .{
        .reason = .orphaned,
        .timeout_ms = 2000,
        .status = .{ .signaled = 9 },
    });
    defer allocator.free(orphan);
    try std.testing.expectEqualStrings(
        "\n[signal 9]\n[orphaned processes killed after 2s: " ++
            "a task tracks its shell, so drop '&' or end the command with 'wait']",
        orphan,
    );
}

test "in-memory output counts raw bytes and lines, caps lines, and sanitizes UTF-8" {
    var output = BashOutput.init(std.testing.allocator, std.testing.io, .{});
    defer output.deinit();
    try output.append("one\n");
    try output.append("abc\xff\n");
    var long: [505]u8 = @splat('x');
    try output.append(&long);
    try std.testing.expectEqual(@as(usize, 514), output.size());
    try std.testing.expectEqual(@as(usize, 3), output.rawLineCount());
    const result = try output.finish(.{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "one\nabc\xef\xbf\xbd\n"));
    try std.testing.expect(std.mem.endsWith(u8, result, "...[5 bytes elided]"));
}

test "NUL suppresses the whole body and reports raw size" {
    var output = BashOutput.init(std.testing.allocator, std.testing.io, .{});
    defer output.deinit();
    try output.append("abc\x00def");
    const result = try output.finish(.{ .status = .{ .exited = 2 } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[binary output suppressed: 7B]\n[exit 2]", result);
}

fn tempPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

test "spill retains exact head-tail shape and deinit unlinks saved file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tempPath(allocator, &tmp);
    defer allocator.free(directory);
    var output = BashOutput.init(allocator, std.testing.io, .{
        .memory_cap = 1,
        .model_bytes = 32,
        .model_lines = 8,
        .result_bytes = 4096,
        .temp_directory = directory,
    });
    try output.append("h0\nh1\nh2\nh3\nh4\nh5\nh6\nh7\nh8\nh9\n");
    const saved = try allocator.dupe(u8, output.savedPath().?);
    defer allocator.free(saved);
    const result = try output.finish(.{});
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(
        u8,
        result,
        "h0\n... [output truncated: omitted 2 of 10 lines " ++
            "(kept first 1, last 7); full output temporarily saved to ",
    ));
    try std.testing.expect(std.mem.endsWith(u8, result, "h3\nh4\nh5\nh6\nh7\nh8\nh9\n"));
    try std.Io.Dir.cwd().access(std.testing.io, saved, .{});
    output.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, saved, .{}));
}

test "long first line uses tail-only marker and raw-byte line cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tempPath(allocator, &tmp);
    defer allocator.free(directory);
    var output = BashOutput.init(allocator, std.testing.io, .{
        .memory_cap = 0,
        .model_bytes = 10,
        .model_lines = 8,
        .result_bytes = 4096,
        .temp_directory = directory,
    });
    defer output.deinit();
    try output.append("abcdefghijklmnopqrstuvwxyz");
    const result = try output.finish(.{});
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(
        u8,
        result,
        "qrstuvwxyz\n[output truncated: last 1 of 1 lines, 10B of 26B; " ++
            "full output temporarily saved to ",
    ));
}

test "hard capture limit rejects the crossing chunk without changing totals" {
    var output = BashOutput.init(std.testing.allocator, std.testing.io, .{});
    defer output.deinit();
    output.total_bytes = drain_limit - 1;
    output.newline_count = 7;
    try std.testing.expectError(error.CaptureLimitExceeded, output.append("xx"));
    try std.testing.expectEqual(drain_limit - 1, output.size());
    try std.testing.expectEqual(@as(usize, 7), output.rawLineCount());
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var output = BashOutput.init(allocator, std.testing.io, .{ .memory_cap = 1024 });
    defer output.deinit();
    try output.append("before\ninvalid \xff\n");
    const result = try output.finish(.{});
    allocator.free(result);
}

test "all in-memory allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

fn exerciseSpillAllocations(allocator: std.mem.Allocator, directory: []const u8) !void {
    var output = BashOutput.init(allocator, std.testing.io, .{
        .memory_cap = 1,
        .model_bytes = 32,
        .result_bytes = 4096,
        .temp_directory = directory,
    });
    defer output.deinit();
    try output.append("head\nbody\ntail\n");
    const result = try output.finish(.{});
    allocator.free(result);
}

test "spill and shaping allocation failures are leak-free and unlink files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tempPath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(directory);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSpillAllocations,
        .{directory},
    );
}

test "model byte cap also bounds the in-memory threshold" {
    var output = BashOutput.init(std.testing.allocator, std.testing.io, .{
        .memory_cap = 1024,
        .model_bytes = 4,
        .temp_directory = ".zig-cache/tmp",
    });
    defer output.deinit();
    try output.append("12345");
    try std.testing.expect(output.spilled);
    try std.testing.expect(output.savedPath() != null);
}
