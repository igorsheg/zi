const std = @import("std");

const Frame = @This();

writer: *std.Io.Writer,
trailing_newlines: u2 = 0,

/// Borrows `writer` for synchronous normal-buffer presentation.
pub fn init(writer: *std.Io.Writer) Frame {
    return .{ .writer = writer };
}

/// Ensures the next block starts after two committed newlines.
pub fn openBlock(self: *Frame) std.Io.Writer.Error!void {
    while (self.trailing_newlines < 2) try self.writeByte('\n');
}

/// Publishes newline state after output which bypassed this coordinator.
pub fn syncExternal(self: *Frame, trailing_newlines: usize) void {
    self.trailing_newlines = @intCast(@min(trailing_newlines, 2));
}

pub fn writeAll(self: *Frame, bytes: []const u8) std.Io.Writer.Error!void {
    try self.writer.writeAll(bytes);
    if (bytes.len == 0) return;

    self.trailing_newlines = 0;
    var index = bytes.len;
    while (index != 0 and self.trailing_newlines < 2) {
        index -= 1;
        if (bytes[index] != '\n') break;
        self.trailing_newlines += 1;
    }
}

pub fn writeByte(self: *Frame, byte: u8) std.Io.Writer.Error!void {
    try self.writer.writeByte(byte);
    if (byte != '\n') {
        self.trailing_newlines = 0;
    } else if (self.trailing_newlines < 2) {
        self.trailing_newlines += 1;
    }
}

pub fn flush(self: *Frame) std.Io.Writer.Error!void {
    try self.writer.flush();
}

test "open block starts with two newlines" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame: Frame = .init(&output.writer);

    try frame.openBlock();

    try std.testing.expectEqualStrings("\n\n", output.written());
    try std.testing.expectEqual(@as(u2, 2), frame.trailing_newlines);
}

test "repeated block opens do not add space" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame: Frame = .init(&output.writer);

    try frame.openBlock();
    try frame.openBlock();

    try std.testing.expectEqualStrings("\n\n", output.written());
}

test "writes track trailing newlines and content" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame: Frame = .init(&output.writer);

    try frame.writeAll("heading\n");
    try std.testing.expectEqual(@as(u2, 1), frame.trailing_newlines);
    try frame.openBlock();
    try frame.writeByte('x');
    try std.testing.expectEqual(@as(u2, 0), frame.trailing_newlines);
    try frame.writeAll("");
    try std.testing.expectEqual(@as(u2, 0), frame.trailing_newlines);

    try std.testing.expectEqualStrings("heading\n\nx", output.written());
}

test "external synchronization controls block spacing" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame: Frame = .init(&output.writer);

    frame.syncExternal(1);
    try frame.openBlock();
    frame.syncExternal(2);
    try frame.openBlock();
    frame.syncExternal(0);
    try frame.openBlock();

    try std.testing.expectEqualStrings("\n\n\n", output.written());
}

test "newline tracking saturates at two" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var frame: Frame = .init(&output.writer);

    try frame.writeAll("\n\n\n\n");
    try std.testing.expectEqual(@as(u2, 2), frame.trailing_newlines);
    try frame.writeByte('\n');
    try std.testing.expectEqual(@as(u2, 2), frame.trailing_newlines);
    frame.syncExternal(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(u2, 2), frame.trailing_newlines);
}

test "writer failures propagate without committing state" {
    var failed_writer: std.Io.Writer = .failing;
    var frame: Frame = .init(&failed_writer);

    try std.testing.expectError(error.WriteFailed, frame.writeAll("text"));
    try std.testing.expectEqual(@as(u2, 0), frame.trailing_newlines);
    try std.testing.expectError(error.WriteFailed, frame.writeByte('\n'));
    try std.testing.expectEqual(@as(u2, 0), frame.trailing_newlines);
    try std.testing.expectError(error.WriteFailed, frame.openBlock());
}

test "flush propagates writer failure" {
    const FailingFlush = struct {
        writer: std.Io.Writer = .{
            .vtable = &.{
                .drain = drain,
                .flush = failFlush,
            },
            .buffer = &.{},
        },

        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }

        fn failFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };

    var failing: FailingFlush = .{};
    var frame: Frame = .init(&failing.writer);

    try std.testing.expectError(error.WriteFailed, frame.flush());
}
