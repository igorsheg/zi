const std = @import("std");

/// Bounded JSONL line decoder.
///
/// Owner: `Decoder` owns the partial-line buffer and oversize discard state.
/// Ingress: byte chunks through `feed`.
/// Egress: complete line slices through `Sink.emit`; diagnostics through
/// `Sink.err`.
/// Bound: `Options.max_line_bytes`; oversize lines are discarded until the next
/// newline so framing can resynchronize.
pub const ErrorKind = enum { line_too_long };

pub const Options = struct {
    max_line_bytes: usize = 1024 * 1024,
    trim_cr: bool = true,
    skip_empty: bool = true,
};

pub const Sink = struct {
    ptr: *anyopaque,
    emit: *const fn (ptr: *anyopaque, line: []const u8) void,
    err: ?*const fn (ptr: *anyopaque, kind: ErrorKind, data: []const u8) void = null,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    options: Options,
    discarding: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) Decoder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, chunk: []const u8, sink: Sink) !void {
        var start: usize = 0;
        while (start < chunk.len) {
            if (self.discarding) {
                if (std.mem.indexOfScalar(u8, chunk[start..], '\n')) |off| {
                    self.discarding = false;
                    start += off + 1;
                    continue;
                }
                return;
            }

            if (std.mem.indexOfScalar(u8, chunk[start..], '\n')) |off| {
                const segment = chunk[start .. start + off];
                try self.acceptSegment(segment, true, sink);
                start += off + 1;
            } else {
                try self.acceptSegment(chunk[start..], false, sink);
                return;
            }
        }
    }

    pub fn flush(self: *Decoder, sink: Sink) void {
        if (self.discarding) {
            self.discarding = false;
            self.buffer.clearRetainingCapacity();
            return;
        }
        if (self.buffer.items.len == 0) return;
        self.emitLine(self.buffer.items, sink);
        self.buffer.clearRetainingCapacity();
    }

    fn acceptSegment(self: *Decoder, segment: []const u8, ends_line: bool, sink: Sink) !void {
        if (self.buffer.items.len + segment.len > self.options.max_line_bytes) {
            if (sink.err) |err| err(sink.ptr, .line_too_long, segment);
            self.buffer.clearRetainingCapacity();
            self.discarding = !ends_line;
            return;
        }
        if (self.buffer.items.len > 0) {
            try self.buffer.appendSlice(self.allocator, segment);
            if (ends_line) {
                self.emitLine(self.buffer.items, sink);
                self.buffer.clearRetainingCapacity();
            }
            return;
        }
        if (ends_line) self.emitLine(segment, sink) else try self.buffer.appendSlice(self.allocator, segment);
    }

    fn emitLine(self: *Decoder, raw: []const u8, sink: Sink) void {
        var line = raw;
        if (self.options.trim_cr and line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (self.options.skip_empty and std.mem.trim(u8, line, " \t\r\n").len == 0) return;
        sink.emit(sink.ptr, line);
    }
};

const testing = std.testing;
const Collector = struct {
    lines: std.ArrayList([]const u8) = .empty,
    errors: usize = 0,
    allocator: std.mem.Allocator,
    fn emit(ptr: *anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.lines.append(self.allocator, self.allocator.dupe(u8, line) catch return) catch return;
    }
    fn err(ptr: *anyopaque, _: ErrorKind, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.errors += 1;
    }
    fn sink(self: *@This()) Sink {
        return .{ .ptr = self, .emit = emit, .err = err };
    }
    fn deinit(self: *@This()) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
};

test "jsonl decoder frames split lines crlf tail and oversize resync" {
    var c = Collector{ .allocator = testing.allocator };
    defer c.deinit();
    var d = Decoder.init(testing.allocator, .{ .max_line_bytes = 5 });
    defer d.deinit();
    try d.feed("a", c.sink());
    try d.feed("b\r\ncd\nabcdef", c.sink());
    try d.feed("ghi\nzz\n", c.sink());
    try d.feed("tail", c.sink());
    d.flush(c.sink());
    try testing.expectEqual(@as(usize, 1), c.errors);
    try testing.expectEqual(@as(usize, 4), c.lines.items.len);
    try testing.expectEqualStrings("ab", c.lines.items[0]);
    try testing.expectEqualStrings("cd", c.lines.items[1]);
    try testing.expectEqualStrings("zz", c.lines.items[2]);
    try testing.expectEqualStrings("tail", c.lines.items[3]);
}
