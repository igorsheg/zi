const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const shimmer_mod = @import("../shimmer.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Shimmer = shimmer_mod.Config;

/// Loader that renders only a shimmered message label.
///
/// Renders as two rows: an empty line (top padding) followed by
/// `{message}`, matching pi-mono's loader spacing without the spinner.
/// returns `["", ...super.render(width)]`.
///
/// Animation is deadline-driven through the generic component animation hooks,
/// so callers no longer need to special-case loader ticking in the main loop.
pub const Loader = struct {
    shimmer_phase: u32 = 0,
    /// Owned message buffer — setMessage copies into this.
    message_buf: [128]u8 = undefined,
    message_len: u8 = 0,
    shimmer_edge_fg: Color = Color.default,
    message_fg: Color = Color.default,
    shimmer_peak_fg: Color = Color.default,
    active: bool = true,

    const shimmer_floor: u8 = 96;

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
        self.shimmer_phase = 0;
    }

    pub fn nextAnimationDeadline(self: *Loader, now_ns: i128) ?i128 {
        if (!self.active or self.message_len == 0) return null;
        return shimmer_mod.nextDeadline(now_ns, self.shimmerConfig());
    }

    pub fn tickAnimation(self: *Loader, now_ns: i128) bool {
        if (!self.active or self.message_len == 0) return false;

        const phase = shimmer_mod.phaseForTime(now_ns, self.shimmerConfig(), self.message());
        if (phase == self.shimmer_phase) return false;
        self.shimmer_phase = phase;
        return true;
    }

    // ── Component interface ─────────────────────────────────────

    pub fn render(self: *Loader, region: Region) void {
        if (region.height < 2 or region.width < 2) return;
        // Row 0: empty (top padding). Row 1: shimmered message.
        _ = shimmer_mod.writeSmooth(region, 1, 1, self.message(), self.shimmerConfig(), self.shimmer_phase, shimmer_floor);
    }

    pub fn measure(_: *Loader, _: u32) Measurement {
        return .{ .min_height = 2, .preferred_height = 2 };
    }

    pub fn component(self: *Loader) Component {
        return Component.init(Loader, self);
    }

    fn shimmerConfig(self: *const Loader) Shimmer {
        return .{
            .step_ns = 50_000_000,
            .lead_pad_cols = 4,
            .tail_pad_cols = 8,
            .band_half_width = 5,
            .base_fg = self.message_fg,
            .edge_fg = self.shimmer_edge_fg,
            .peak_fg = self.shimmer_peak_fg,
            .base_attrs = .{ .dim = true },
            .edge_attrs = .{},
            .peak_attrs = .{},
        };
    }
};
