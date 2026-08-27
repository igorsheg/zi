const std = @import("std");

pub const Kind = enum {
    content,
    raw,
};

pub const Error = error{
    OutOfMemory,
    OutputTooLarge,
};

/// Erased synchronous destination for Markdown output.
///
/// Payloads are borrowed for `emit`; `context` must outlive every synchronous
/// call made by its owner. `raw` bytes are renderer-owned terminal controls and
/// must bypass visible-width and pending-newline accounting.
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8, Kind) Error!void,

    pub fn emit(self: Sink, bytes: []const u8, kind: Kind) Error!void {
        if (bytes.len == 0) return;
        try self.emit_fn(self.context, bytes, kind);
    }

    pub fn from(implementation: anytype) Sink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("MarkdownOutput.Sink.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, bytes: []const u8, kind: Kind) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emit(bytes, kind);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

test "sink preserves borrowed bytes and output kind" {
    const Recorder = struct {
        const Self = @This();

        bytes: std.ArrayList(u8) = .empty,
        kinds: std.ArrayList(Kind) = .empty,

        fn deinit(self: *Self) void {
            self.bytes.deinit(std.testing.allocator);
            self.kinds.deinit(std.testing.allocator);
        }

        pub fn emit(self: *Self, bytes: []const u8, kind: Kind) Error!void {
            try self.bytes.appendSlice(std.testing.allocator, bytes);
            try self.kinds.append(std.testing.allocator, kind);
        }
    };

    var recorder: Recorder = .{};
    defer recorder.deinit();
    const sink = Sink.from(&recorder);
    try sink.emit("text", .content);
    try sink.emit("\x1b[1m", .raw);
    try sink.emit("", .content);

    try std.testing.expectEqualStrings("text\x1b[1m", recorder.bytes.items);
    try std.testing.expectEqualSlices(Kind, &.{ .content, .raw }, recorder.kinds.items);
}
