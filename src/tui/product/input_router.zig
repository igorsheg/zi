const std = @import("std");
const vaxis = @import("vaxis");

const primitive = @import("../primitive/root.zig");
const terminal = @import("../substrate/terminal.zig");
const app_mod = @import("App.zig");

pub const text_size_bytes_max = 256;
pub const page_scroll_rows = 8;

pub const RouteResult = union(enum) {
    command: app_mod.Command,
    cancel,
};

pub const Scratch = struct {
    text_buffer: [text_size_bytes_max]u8 = undefined,

    pub fn route(self: *Scratch, event: terminal.Event) !?RouteResult {
        return switch (event) {
            .key_press => |key_event| try self.routeKey(key_event),
            .winsize => |winsize| .{ .command = .{ .resize = .{
                .width_columns = winsize.cols,
                .height_rows = winsize.rows,
            } } },
            else => null,
        };
    }

    fn routeKey(self: *Scratch, key_event: vaxis.Key) !?RouteResult {
        const input = primitive.input.inputFromKey(key_event) orelse return null;
        return switch (input) {
            .cancel => .cancel,
            .submit => .{ .command = .submit_composer },
            .backspace => .{ .command = .backspace_composer },
            .move_left => .{ .command = .move_composer_left },
            .move_right => .{ .command = .move_composer_right },
            .page_up => .{ .command = .{ .scroll_transcript_up = page_scroll_rows } },
            .page_down => .{ .command = .{ .scroll_transcript_down = page_scroll_rows } },
            .text => |bytes| .{ .command = .{ .insert_composer_text = try self.copyText(bytes) } },
        };
    }

    fn copyText(self: *Scratch, bytes: []const u8) ![]const u8 {
        if (bytes.len > self.text_buffer.len) return error.InputRouteTextTooLarge;
        @memcpy(self.text_buffer[0..bytes.len], bytes);
        return self.text_buffer[0..bytes.len];
    }
};

fn testKey(codepoint: u21, text: ?[]const u8) vaxis.Key {
    return .{ .codepoint = codepoint, .text = text };
}

test "input router copies printable key text into scratch command" {
    var scratch: Scratch = .{};
    var source = [_]u8{ 'h', 'i' };

    const routed = (try scratch.route(.{ .key_press = testKey('h', source[0..]) })).?;
    source[0] = 'b';

    try std.testing.expectEqualStrings("hi", routed.command.insert_composer_text);
}

test "input router maps editing and submit keys" {
    var scratch: Scratch = .{};

    try std.testing.expectEqual(
        app_mod.Command.backspace_composer,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.backspace, null) })).?.command,
    );
    try std.testing.expectEqual(
        app_mod.Command.move_composer_left,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.left, null) })).?.command,
    );
    try std.testing.expectEqual(
        app_mod.Command.move_composer_right,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.right, null) })).?.command,
    );
    try std.testing.expectEqual(
        app_mod.Command.submit_composer,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.enter, null) })).?.command,
    );
}

test "input router maps resize and scrolling" {
    var scratch: Scratch = .{};

    const resize = (try scratch.route(.{ .winsize = .{
        .rows = 24,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    } })).?.command.resize;
    try std.testing.expectEqual(@as(u16, 80), resize.width_columns);
    try std.testing.expectEqual(@as(u16, 24), resize.height_rows);

    try std.testing.expectEqual(
        page_scroll_rows,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.page_up, null) })).?.command.scroll_transcript_up,
    );
    try std.testing.expectEqual(
        page_scroll_rows,
        (try scratch.route(.{ .key_press = testKey(vaxis.Key.page_down, null) })).?.command.scroll_transcript_down,
    );
}

test "input router rejects oversized borrowed text" {
    var scratch: Scratch = .{};
    const bytes = "x" ** (text_size_bytes_max + 1);

    try std.testing.expectError(
        error.InputRouteTextTooLarge,
        scratch.route(.{ .key_press = testKey('x', bytes) }),
    );
}

test "input router ignores unknown and non-key events" {
    var scratch: Scratch = .{};

    try std.testing.expect((try scratch.route(.focus_in)) == null);
    try std.testing.expect((try scratch.route(.{ .key_press = .{ .codepoint = 0 } })) == null);
}
