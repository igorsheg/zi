const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;

/// Animated braille spinner with a message label.
///
/// Renders as two rows: an empty line (top padding) followed by
/// `{frame} {message}`, matching pi-mono's Loader component which
/// returns `["", ...super.render(width)]`.
///
/// Callers drive animation by calling `tick()` each frame and marking
/// dirty when it returns true.
pub const Loader = struct {
    frame: u8 = 0,
    last_tick_ns: i128 = 0,
    message: []const u8 = "Working...",
    spinner_fg: Color = Color.default,
    message_fg: Color = Color.default,
    active: bool = true,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const frame_interval_ns: i128 = 80_000_000; // 80ms

    /// Advance animation frame if 80ms has elapsed. Returns true if frame changed.
    pub fn tick(self: *Loader) bool {
        if (!self.active) return false;
        const now = std.time.nanoTimestamp();
        if (self.last_tick_ns == 0) {
            self.last_tick_ns = now;
            return true;
        }
        if (now - self.last_tick_ns >= frame_interval_ns) {
            self.frame = @intCast((self.frame + 1) % frames.len);
            self.last_tick_ns = now;
            return true;
        }
        return false;
    }

    pub fn setMessage(self: *Loader, msg: []const u8) void {
        self.message = msg;
    }

    pub fn stop(self: *Loader) void {
        self.active = false;
    }

    pub fn start(self: *Loader) void {
        self.active = true;
        self.frame = 0;
        self.last_tick_ns = 0;
    }

    // ── Component interface ─────────────────────────────────────

    pub fn render(self: *Loader, region: Region) void {
        if (region.height < 2 or region.width < 4) return;
        // Row 0: empty (top padding). Row 1: spinner + message.
        var col: u32 = 1; // 1 col left padding
        col += region.writeStr(col, 1, frames[self.frame], self.spinner_fg, Color.default, Attributes.none);
        col += 1; // space
        _ = region.writeStr(col, 1, self.message, self.message_fg, Color.default, Attributes.none);
    }

    pub fn measure(_: *Loader, _: u32) Measurement {
        return .{ .min_height = 2, .preferred_height = 2 };
    }

    pub fn component(self: *Loader) Component {
        return Component.init(Loader, self);
    }
};
