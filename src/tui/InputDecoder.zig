const std = @import("std");
const vaxis = @import("vaxis");
const input = @import("input.zig");
const Terminal = @import("Terminal.zig");

pub const drain_capacity = 4096;
pub const carry_capacity = 64;
pub const buffer_capacity = drain_capacity + carry_capacity;
pub const lone_escape_timeout_ns: u64 = 10 * std.time.ns_per_ms;
const text_capacity = 4096;

parser: vaxis.Parser = .{},
buffer: [buffer_capacity]u8 = undefined,
paste_buffer: [text_capacity]u8 = undefined,
len: usize = 0,
last_text: [text_capacity]u8 = undefined,

const InputDecoder = @This();

pub const Error = error{ DecoderFull, ActionTextTooLong };

pub fn feed(self: *InputDecoder, bytes: []const u8) Error!void {
    if (bytes.len > buffer_capacity - self.len) return error.DecoderFull; // bounded policy: reject.
    @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

pub fn pendingBytes(self: *const InputDecoder) usize {
    return self.len;
}

pub fn nextAction(self: *InputDecoder) !?input.Action {
    return self.nextActionWithTerminal(null);
}

pub fn nextActionWithTerminal(self: *InputDecoder, terminal: ?*Terminal) !?input.Action {
    while (self.len > 0) {
        var paste_fba = std.heap.FixedBufferAllocator.init(&self.paste_buffer);
        const result = try self.parser.parse(self.buffer[0..self.len], paste_fba.allocator());
        if (result.n == 0) return null;
        defer self.discard(result.n);

        const event = result.event orelse continue;
        if (try self.actionFromEvent(event, terminal)) |action| {
            if (action == .none) continue;
            return try self.ownAction(action);
        }
    }
    return null;
}

pub fn needsEscapeDeadline(self: *const InputDecoder) bool {
    return self.len > 0 and self.buffer[0] == 0x1b;
}

pub fn expireLoneEscape(self: *InputDecoder) input.Action {
    if (self.needsEscapeDeadline()) self.discard(1);
    return .cancel;
}

fn actionFromEvent(self: *InputDecoder, event: vaxis.Event, terminal: ?*Terminal) !?input.Action {
    _ = self;
    switch (event) {
        .key_press => |key| return input.fromKey(key),
        .key_release => return null,
        .mouse => |mouse| {
            const action = input.fromMouse(if (terminal) |term| term.vx.?.translateMouse(mouse) else mouse);
            if (action == .none) return null;
            return action;
        },
        .paste => |text| return .{ .insert = text },
        .winsize, .color_report, .color_scheme, .cap_kitty_keyboard, .cap_kitty_graphics, .cap_rgb, .cap_sgr_pixels, .cap_unicode, .cap_da1, .cap_color_scheme_updates, .cap_multi_cursor => {
            if (terminal) |term| {
                return switch (try term.applyParserEvent(event)) {
                    .resized => .force_redraw,
                    .consumed, .ignored => null,
                };
            }
            return null;
        },
        .paste_start, .paste_end, .mouse_leave, .focus_in, .focus_out => return null,
    }
}

fn ownAction(self: *InputDecoder, action: input.Action) Error!input.Action {
    return switch (action) {
        .insert => |text| blk: {
            if (text.len > text_capacity) return error.ActionTextTooLong;
            @memcpy(self.last_text[0..text.len], text);
            break :blk .{ .insert = self.last_text[0..text.len] };
        },
        else => action,
    };
}

fn discard(self: *InputDecoder, count: usize) void {
    std.debug.assert(count <= self.len);
    std.mem.copyForwards(u8, self.buffer[0 .. self.len - count], self.buffer[count..self.len]);
    self.len -= count;
}

test "decoder feeds printable text and owns returned slice" {
    var decoder: InputDecoder = .{};
    try decoder.feed("a");
    const action = (try decoder.nextAction()).?;
    try std.testing.expect(action == .insert);
    try std.testing.expectEqualStrings("a", action.insert);
    try std.testing.expectEqual(@as(usize, 0), decoder.pendingBytes());
}

test "decoder parses arrows and ctrl keys" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[D\x03");

    const left = (try decoder.nextAction()).?;
    try std.testing.expect(left == .key_editor);
    try std.testing.expectEqual(input.EditorOp.move_left, left.key_editor);

    const ctrl_c = (try decoder.nextAction()).?;
    try std.testing.expect(ctrl_c == .clear_or_quit);
}

test "decoder preserves incomplete escape sequence and rejects overflow" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[");
    try std.testing.expectEqual(@as(?input.Action, null), try decoder.nextAction());
    try std.testing.expectEqual(@as(usize, 2), decoder.pendingBytes());

    try decoder.feed("D");
    const left = (try decoder.nextAction()).?;
    try std.testing.expect(left == .key_editor);

    var full: [buffer_capacity]u8 = undefined;
    @memset(&full, 'x');
    try decoder.feed(&full);
    try std.testing.expectError(error.DecoderFull, decoder.feed("x"));
}

test "decoder drops key release events" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[97;1:3u");
    try std.testing.expectEqual(@as(?input.Action, null), try decoder.nextAction());
    try std.testing.expectEqual(@as(usize, 0), decoder.pendingBytes());
}

test "decoder maps mouse wheel and drops non-wheel mouse" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[<64;1;1M\x1b[<0;1;1M");

    const wheel = (try decoder.nextAction()).?;
    try std.testing.expect(wheel == .scroll);
    try std.testing.expectEqual(@as(i32, -3), wheel.scroll);
    try std.testing.expectEqual(@as(?input.Action, null), try decoder.nextAction());
}

test "decoder copies osc paste into insert action" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b]52;c;aGk=\x07");
    const paste = (try decoder.nextAction()).?;
    try std.testing.expect(paste == .insert);
    try std.testing.expectEqualStrings("hi", paste.insert);
}

test "decoder exposes lone escape deadline and expiry" {
    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[");
    try std.testing.expect(decoder.needsEscapeDeadline());
    try std.testing.expect(decoder.expireLoneEscape() == .cancel);
    try std.testing.expectEqual(@as(usize, 1), decoder.pendingBytes());
}

test "decoder applies winsize parser event through terminal" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var decoder: InputDecoder = .{};
    try decoder.feed("\x1b[48;24;100;480;1000t");
    const action = (try decoder.nextActionWithTerminal(&terminal)).?;
    try std.testing.expect(action == .force_redraw);
    try std.testing.expectEqual(@as(u16, 100), terminal.vx.?.screen.width);
    try std.testing.expectEqual(@as(u16, 24), terminal.vx.?.screen.height);
}
