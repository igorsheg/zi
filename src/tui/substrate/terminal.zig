const std = @import("std");
const ansi = @import("ansi.zig");
const RawMode = @import("raw_mode.zig").RawMode;

pub const Size = struct { width: u16, height: u16 };

pub const Terminal = struct {
    io: std.Io,
    raw: ?RawMode = null,
    active: bool = false,

    pub fn init(io: std.Io) Terminal { return .{ .io = io }; }
    pub fn setup(self: *Terminal, writer: *std.Io.Writer) !void {
        self.raw = try RawMode.enter();
        try writer.writeAll(ansi.enter_alt_screen ++ ansi.hide_cursor ++ ansi.clear);
        self.active = true;
    }
    pub fn shutdown(self: *Terminal, writer: *std.Io.Writer) !void {
        defer {
            if (self.raw) |*raw| raw.restore();
            self.active = false;
            self.raw = null;
        }
        if (self.active) try writer.writeAll(ansi.reset ++ ansi.show_cursor ++ ansi.leave_alt_screen);
    }
    pub fn size(self: Terminal) !Size {
        _ = self;
        return .{ .width = 80, .height = 24 };
    }
};

test "terminal default size bounded" {
    const t = Terminal.init(std.testing.io);
    const s = try t.size();
    try std.testing.expect(s.width > 0);
    try std.testing.expect(s.height > 0);
}
