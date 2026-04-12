const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;

/// Animated braille spinner with a static message label.
///
/// Renders as two rows: an empty line (top padding) followed by
/// `{frame} {message}`, matching pi-mono's Loader component which
/// returns `["", ...super.render(width)]`.
///
/// Animation is deadline-driven through the generic component animation hooks,
/// so callers no longer need to special-case loader ticking in the main loop.
pub const Loader = struct {
    frame: u8 = 0,
    spinner_last_tick_ns: i128 = 0,
    /// Owned message buffer — setMessage copies into this.
    message_buf: [128]u8 = undefined,
    message_len: u8 = 0,
    spinner_fg: Color = Color.default,
    message_fg: Color = Color.default,
    active: bool = true,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const spinner_interval_ns: i128 = 80_000_000; // 80ms

    pub fn message(self: *const Loader) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn setMessage(self: *Loader, msg: []const u8) void {
        const len = @min(msg.len, self.message_buf.len);
        @memcpy(self.message_buf[0..len], msg[0..len]);
        self.message_len = @intCast(len);
    }

    pub fn stop(self: *Loader) void {
        self.active = false;
    }

    pub fn start(self: *Loader) void {
        self.active = true;
        self.frame = 0;
        self.spinner_last_tick_ns = 0;
    }

    pub fn nextAnimationDeadline(self: *Loader, now_ns: i128) ?i128 {
        if (!self.active) return null;

        return if (self.spinner_last_tick_ns == 0)
            now_ns
        else
            self.spinner_last_tick_ns + spinner_interval_ns;
    }

    pub fn tickAnimation(self: *Loader, now_ns: i128) bool {
        if (!self.active) return false;

        var changed = false;
        if (self.spinner_last_tick_ns == 0 or now_ns - self.spinner_last_tick_ns >= spinner_interval_ns) {
            if (self.spinner_last_tick_ns != 0) {
                self.frame = @intCast((self.frame + 1) % frames.len);
            }
            self.spinner_last_tick_ns = now_ns;
            changed = true;
        }

        return changed;
    }

    // ── Component interface ─────────────────────────────────────

    pub fn render(self: *Loader, region: Region) void {
        if (region.height < 2 or region.width < 4) return;
        // Row 0: empty (top padding). Row 1: spinner + message.
        var col: u32 = 1; // 1 col left padding
        col += region.writeStr(col, 1, frames[self.frame], self.spinner_fg, Color.default, Attributes.none);
        col += 1; // space
        _ = region.writeStr(col, 1, self.message(), self.message_fg, Color.default, .{ .dim = true });
    }

    pub fn measure(_: *Loader, _: u32) Measurement {
        return .{ .min_height = 2, .preferred_height = 2 };
    }

    pub fn component(self: *Loader) Component {
        return Component.init(Loader, self);
    }
};

test "loader animation hooks publish deadlines and visible ticks" {
    var loader = Loader{};
    loader.setMessage("Working...");
    loader.start();

    const now_ns: i128 = 100;
    try std.testing.expectEqual(@as(?i128, now_ns), loader.nextAnimationDeadline(now_ns));
    try std.testing.expect(loader.tickAnimation(now_ns));
    try std.testing.expect(loader.nextAnimationDeadline(now_ns + 1) != null);
}
