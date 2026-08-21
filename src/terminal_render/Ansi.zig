const std = @import("std");
const style = @import("Style.zig");

const Ansi = @This();

pub const Color = style.Color;
pub const Attributes = style.Attributes;
pub const Style = style.Style;

pub const Position = struct {
    row: u16,
    column: u16,
};

pub const MoveError = error{ InvalidCursorPosition, WriteFailed };

pub const EraseLine = enum(u2) {
    to_end = 0,
    to_start = 1,
    entire = 2,
};

/// Encodes terminal controls while retaining only facts this instance emitted.
/// Call `forgetCursor` after writing bytes that can move or wrap the cursor.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    style: ?Style = .{},
    position: ?Position = null,
    cursor_visible: ?bool = null,

    pub fn init(writer: *std.Io.Writer) Encoder {
        return .{ .writer = writer };
    }

    /// Clears retained facts after output outside this encoder changes terminal state.
    pub fn invalidate(self: *Encoder) void {
        self.style = null;
        self.position = null;
        self.cursor_visible = null;
    }

    pub fn forgetCursor(self: *Encoder) void {
        self.position = null;
    }

    /// Moves to a one-based terminal position. Unknown positions use CUP; known
    /// positions use the shorter relative row and column controls.
    pub fn moveTo(self: *Encoder, position: Position) MoveError!void {
        if (position.row == 0 or position.column == 0) return error.InvalidCursorPosition;
        if (self.position) |current| {
            if (std.meta.eql(current, position)) return;
            errdefer self.position = null;
            if (position.row < current.row) {
                try self.writer.print("\x1b[{d}A", .{current.row - position.row});
            } else if (position.row > current.row) {
                try self.writer.print("\x1b[{d}B", .{position.row - current.row});
            }
            if (position.column < current.column) {
                try self.writer.print("\x1b[{d}D", .{current.column - position.column});
            } else if (position.column > current.column) {
                try self.writer.print("\x1b[{d}C", .{position.column - current.column});
            }
        } else {
            errdefer self.position = null;
            try self.writer.print("\x1b[{d};{d}H", .{ position.row, position.column });
        }
        self.position = position;
    }

    pub fn setCursorVisible(self: *Encoder, visible: bool) std.Io.Writer.Error!void {
        if (self.cursor_visible) |current| {
            if (current == visible) return;
        }
        errdefer self.cursor_visible = null;
        try self.writer.writeAll(if (visible) "\x1b[?25h" else "\x1b[?25l");
        self.cursor_visible = visible;
    }

    pub fn eraseLine(self: *Encoder, mode: EraseLine) std.Io.Writer.Error!void {
        try self.writer.print("\x1b[{d}K", .{@intFromEnum(mode)});
    }

    /// Starts a synchronized terminal update transaction (DEC private mode 2026).
    pub fn beginSynchronizedUpdate(self: *Encoder) std.Io.Writer.Error!void {
        try self.writer.writeAll("\x1b[?2026h");
    }

    /// Ends a synchronized terminal update transaction (DEC private mode 2026).
    pub fn endSynchronizedUpdate(self: *Encoder) std.Io.Writer.Error!void {
        try self.writer.writeAll("\x1b[?2026l");
    }

    /// Applies only the SGR facts that differ from the retained style. If the
    /// prior style is unknown, this first resets SGR state in the same sequence.
    pub fn setStyle(self: *Encoder, next: Style) std.Io.Writer.Error!void {
        if (self.style) |current| {
            if (current.eql(next)) return;
        }
        errdefer self.style = null;
        try writeStyleTransition(self.writer, self.style, next);
        self.style = next;
    }
};

fn writeStyleTransition(writer: *std.Io.Writer, previous: ?Style, next: Style) std.Io.Writer.Error!void {
    var sgr = Sgr.init(writer);
    if (previous) |current| {
        if (current.attributes.bold != next.attributes.bold or
            current.attributes.dim != next.attributes.dim)
        {
            if (current.attributes.bold or current.attributes.dim) try sgr.parameter(22);
            if (next.attributes.bold) try sgr.parameter(1);
            if (next.attributes.dim) try sgr.parameter(2);
        }
        try writeAttributeTransition(&sgr, current.attributes.italic, next.attributes.italic, 3, 23);
        try writeAttributeTransition(&sgr, current.attributes.underline, next.attributes.underline, 4, 24);
        try writeAttributeTransition(&sgr, current.attributes.blink, next.attributes.blink, 5, 25);
        try writeAttributeTransition(&sgr, current.attributes.inverse, next.attributes.inverse, 7, 27);
        try writeAttributeTransition(&sgr, current.attributes.hidden, next.attributes.hidden, 8, 28);
        try writeAttributeTransition(
            &sgr,
            current.attributes.strikethrough,
            next.attributes.strikethrough,
            9,
            29,
        );
        if (!std.meta.eql(current.foreground, next.foreground)) {
            try writeColor(&sgr, next.foreground, false);
        }
        if (!std.meta.eql(current.background, next.background)) {
            try writeColor(&sgr, next.background, true);
        }
    } else {
        try sgr.parameter(0);
        try writeEnabledAttributes(&sgr, next.attributes);
        try writeColor(&sgr, next.foreground, false);
        try writeColor(&sgr, next.background, true);
    }
    try sgr.finish();
}

fn writeAttributeTransition(
    sgr: *Sgr,
    current: bool,
    next: bool,
    enabled_code: u8,
    disabled_code: u8,
) std.Io.Writer.Error!void {
    if (current == next) return;
    try sgr.parameter(if (next) enabled_code else disabled_code);
}

fn writeEnabledAttributes(sgr: *Sgr, attributes: Attributes) std.Io.Writer.Error!void {
    if (attributes.bold) try sgr.parameter(1);
    if (attributes.dim) try sgr.parameter(2);
    if (attributes.italic) try sgr.parameter(3);
    if (attributes.underline) try sgr.parameter(4);
    if (attributes.blink) try sgr.parameter(5);
    if (attributes.inverse) try sgr.parameter(7);
    if (attributes.hidden) try sgr.parameter(8);
    if (attributes.strikethrough) try sgr.parameter(9);
}

fn writeColor(sgr: *Sgr, color: Color, background: bool) std.Io.Writer.Error!void {
    const selector: u8 = if (background) 48 else 38;
    switch (color) {
        .default => try sgr.parameter(if (background) 49 else 39),
        .indexed => |index| {
            try sgr.parameter(selector);
            try sgr.parameter(5);
            try sgr.parameter(index);
        },
        .rgb => |rgb| {
            try sgr.parameter(selector);
            try sgr.parameter(2);
            try sgr.parameter(rgb.r);
            try sgr.parameter(rgb.g);
            try sgr.parameter(rgb.b);
        },
    }
}

const Sgr = struct {
    writer: *std.Io.Writer,
    has_parameter: bool = false,

    fn init(writer: *std.Io.Writer) Sgr {
        return .{ .writer = writer };
    }

    fn parameter(self: *Sgr, value: u8) std.Io.Writer.Error!void {
        if (!self.has_parameter) {
            try self.writer.writeAll("\x1b[");
            self.has_parameter = true;
        } else {
            try self.writer.writeByte(';');
        }
        try self.writer.print("{d}", .{value});
    }

    fn finish(self: *Sgr) std.Io.Writer.Error!void {
        if (self.has_parameter) try self.writer.writeByte('m');
    }
};

test "encoder emits every style attribute and color exactly" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var encoder = Encoder.init(&output.writer);

    const full: Style = .{
        .foreground = .{ .indexed = 42 },
        .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .attributes = .{
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = true,
            .blink = true,
            .inverse = true,
            .hidden = true,
            .strikethrough = true,
        },
    };
    try encoder.setStyle(full);
    try encoder.setStyle(.{ .foreground = .{ .indexed = 42 }, .attributes = .{ .bold = true } });
    try encoder.setStyle(.{});

    try std.testing.expectEqualStrings(
        "\x1b[1;2;3;4;5;7;8;9;38;5;42;48;2;1;2;3m" ++
            "\x1b[22;1;23;24;25;27;28;29;49m" ++
            "\x1b[22;39m",
        output.written(),
    );
}

test "encoder positions, erases, controls visibility, and delimits updates" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var encoder = Encoder.init(&output.writer);

    try encoder.moveTo(.{ .row = 3, .column = 5 });
    try encoder.moveTo(.{ .row = 1, .column = 1 });
    try encoder.setCursorVisible(false);
    try encoder.setCursorVisible(false);
    try encoder.eraseLine(.entire);
    try encoder.beginSynchronizedUpdate();
    try encoder.endSynchronizedUpdate();

    try std.testing.expectEqualStrings(
        "\x1b[3;5H\x1b[2A\x1b[4D\x1b[?25l\x1b[2K\x1b[?2026h\x1b[?2026l",
        output.written(),
    );
}

test "encoder propagates write errors and invalidates retained style" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }

        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var output: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var encoder = Encoder.init(&output);

    try std.testing.expectError(error.WriteFailed, encoder.setStyle(.{ .attributes = .{ .bold = true } }));
    try std.testing.expect(encoder.style == null);
}
