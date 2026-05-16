const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const status_data_mod = @import("../status_data.zig");
const theme_mod = @import("../theme.zig");
const shimmer_mod = @import("../shimmer.zig");
const shuffle_text_mod = @import("../shuffle_text.zig");
const zio_deadline = @import("../../zio/root.zig").deadline;

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const measurement = component_mod.measurement;
const StatusData = status_data_mod.StatusData;
const Theme = theme_mod.Theme;
const Shimmer = shimmer_mod.Config;
const ShuffleText = shuffle_text_mod.ShuffleText;

const default_shimmer_peak = Color.rgb(0xF2, 0xF1, 0xEF);

pub const StatusLine = struct {
    allocator: std.mem.Allocator,

    primary_text: []const u8 = "",
    primary_fg: Color = Color.default,
    working_active: bool = false,
    working_message: []const u8 = "",
    shimmer_phase: u32 = 0,

    status_data: ?*const StatusData = null,
    theme: ?*const Theme = null,

    primary_buf: std.ArrayListUnmanaged(u8) = .empty,
    working_buf: std.ArrayListUnmanaged(u8) = .empty,
    primary_shuffle: ?ShuffleText = null,

    pub fn init(allocator: std.mem.Allocator) StatusLine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatusLine) void {
        self.primary_buf.deinit(self.allocator);
        self.working_buf.deinit(self.allocator);
        if (self.primary_shuffle) |*shuffle| shuffle.deinit();
    }

    pub fn setPrimary(self: *StatusLine, text: []const u8, fg: Color) void {
        self.primary_buf.clearRetainingCapacity();
        self.primary_buf.appendSlice(self.allocator, text) catch return;
        self.primary_text = self.primary_buf.items;
        self.primary_fg = fg;
        self.startPrimaryShuffle() catch {};
    }

    pub fn clearPrimary(self: *StatusLine) void {
        self.primary_buf.clearRetainingCapacity();
        self.primary_text = "";
        if (self.primary_shuffle) |*shuffle| shuffle.stop();
    }

    pub fn setWorking(self: *StatusLine, text: []const u8) void {
        self.working_buf.clearRetainingCapacity();
        self.working_buf.appendSlice(self.allocator, text) catch return;
        self.working_message = self.working_buf.items;
        self.working_active = true;
        self.shimmer_phase = 0;
    }

    pub fn clearWorking(self: *StatusLine) void {
        self.working_buf.clearRetainingCapacity();
        self.working_message = "";
        self.working_active = false;
    }

    pub fn setStatusData(self: *StatusLine, status_data: *const StatusData) void {
        self.status_data = status_data;
    }

    pub fn setTheme(self: *StatusLine, theme: *const Theme) void {
        self.theme = theme;
    }

    pub fn render(self: *StatusLine, region: Region) void {
        if (region.width == 0 or region.height == 0) return;

        if (self.working_active and self.working_message.len > 0) {
            self.renderWorking(region);
            return;
        }

        const line = self.compose(region.width) catch return;
        defer self.allocator.free(line.text);
        if (line.text.len == 0) return;

        _ = region.writeStr(0, 0, line.text, line.fg, Color.default, .{});
    }

    pub fn nextAnimationDeadline(self: *StatusLine, now_ns: i128) ?i128 {
        var deadline: ?i128 = null;
        if (self.working_active and self.working_message.len > 0) {
            deadline = shimmer_mod.nextDeadline(now_ns, self.shimmerConfig());
        }
        if (!self.working_active) {
            if (self.primary_shuffle) |shuffle| {
                if (shuffle.isRunning()) {
                    const shuffle_deadline = now_ns + @as(i128, @intCast(shuffle.options.frame_ms * std.time.ns_per_ms));
                    deadline = if (deadline) |d| @min(d, shuffle_deadline) else shuffle_deadline;
                }
            }
        }
        return deadline;
    }

    pub fn tickAnimation(self: *StatusLine, now_ns: i128) bool {
        var changed = false;
        if (self.working_active and self.working_message.len > 0) {
            const phase = shimmer_mod.phaseForTime(now_ns, self.shimmerConfig(), self.working_message);
            if (phase != self.shimmer_phase) {
                self.shimmer_phase = phase;
                changed = true;
            }
        }
        if (!self.working_active) {
            if (self.primary_shuffle) |*shuffle| {
                changed = (shuffle.tick(nsToMs(now_ns)) catch false) or changed;
            }
        }
        return changed;
    }

    pub fn measure(self: *StatusLine, width: u32) Measurement {
        _ = self;
        _ = width;
        return measurement(1, 1);
    }

    pub fn component(self: *StatusLine) Component {
        return Component.init(StatusLine, self);
    }

    const ComposedLine = struct {
        text: []u8,
        fg: Color,
    };

    fn compose(self: *StatusLine, width: u32) !ComposedLine {
        const primary = self.primarySegment();
        const extension = if (self.status_data) |data|
            try data.formatExtensionStatuses(self.allocator, " ")
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(extension);

        const separator = " · ";
        const needs_separator = primary.text.len > 0 and extension.len > 0;
        const total = primary.text.len + extension.len + if (needs_separator) separator.len else 0;
        var out = try self.allocator.alloc(u8, total);
        var pos: usize = 0;
        if (primary.text.len > 0) {
            @memcpy(out[pos..][0..primary.text.len], primary.text);
            pos += primary.text.len;
        }
        if (needs_separator) {
            @memcpy(out[pos..][0..separator.len], separator);
            pos += separator.len;
        }
        if (extension.len > 0) {
            @memcpy(out[pos..][0..extension.len], extension);
        }

        if (width > 0 and out.len > width) {
            out = try self.allocator.realloc(out, width);
        }
        return .{ .text = out, .fg = primary.fg };
    }

    const PrimarySegment = struct { text: []const u8, fg: Color };

    fn primarySegment(self: *StatusLine) PrimarySegment {
        if (self.working_active) {
            const fg = if (self.theme) |theme| theme.fg(.dim) else self.primary_fg;
            return .{ .text = self.working_message, .fg = fg };
        }
        if (self.primary_shuffle) |shuffle| {
            if (shuffle.isRunning()) return .{ .text = shuffle.rendered(), .fg = self.primary_fg };
        }
        return .{ .text = self.primary_text, .fg = self.primary_fg };
    }

    fn renderWorking(self: *StatusLine, region: Region) void {
        const working_cols = region.textWidth(self.working_message);
        _ = shimmer_mod.writeSmooth(region, 0, 0, self.working_message, self.shimmerConfig(), self.shimmer_phase, 96);

        const data = self.status_data orelse return;
        const extension = data.formatExtensionStatuses(self.allocator, " ") catch return;
        defer self.allocator.free(extension);
        if (extension.len == 0) return;

        const separator = " · ";
        var x = working_cols;
        if (x < region.width) x += region.writeStr(x, 0, separator, self.primarySegment().fg, Color.default, .{});
        if (x < region.width) _ = region.writeStr(x, 0, extension, self.primarySegment().fg, Color.default, .{});
    }

    fn startPrimaryShuffle(self: *StatusLine) !void {
        if (self.primary_text.len == 0) return;
        if (self.primary_shuffle == null) {
            self.primary_shuffle = try ShuffleText.init(self.allocator, .{
                .duration_ms = 220,
                .frame_ms = 33,
            });
        }
        const shuffle = &self.primary_shuffle.?;
        try shuffle.setText(self.primary_text);
        try shuffle.start(currentMs());
    }

    fn shimmerConfig(self: *const StatusLine) Shimmer {
        const base = if (self.theme) |theme| theme.fg(.dim) else self.primary_fg;
        const edge = if (self.theme) |theme| theme.fg(.muted) else self.primary_fg;
        return .{
            .step_ns = 50_000_000,
            .lead_pad_cols = 4,
            .tail_pad_cols = 8,
            .band_half_width = 5,
            .base_fg = base,
            .edge_fg = edge,
            .peak_fg = if (self.theme) |theme| shimmerPeakColor(theme.fg(.text)) else self.primary_fg,
            .base_attrs = .{ .dim = true },
            .edge_attrs = .{},
            .peak_attrs = .{},
        };
    }
};

fn shimmerPeakColor(text_fg: Color) Color {
    return switch (text_fg) {
        .default_color => default_shimmer_peak,
        else => text_fg,
    };
}

fn currentMs() u64 {
    return @intCast(@divFloor(zio_deadline.nowNs(std.Options.debug_io), std.time.ns_per_ms));
}

fn nsToMs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divFloor(ns, std.time.ns_per_ms));
}

const testing = std.testing;

test "StatusLine renders primary and extension statuses inline" {
    var data = StatusData.init(testing.allocator);
    defer data.deinit();
    data.setStatus("turn", "● Turn 1...");

    var line = StatusLine.init(testing.allocator);
    defer line.deinit();
    line.setStatusData(&data);
    line.setWorking("Working...");

    const composed = try line.compose(80);
    defer testing.allocator.free(composed.text);
    try testing.expectEqualStrings("Working... · ● Turn 1...", composed.text);
}

test "StatusLine reserves one row when empty" {
    var line = StatusLine.init(testing.allocator);
    defer line.deinit();

    try testing.expectEqual(@as(u32, 1), line.measure(80).preferred_height);
    try testing.expectEqual(@as(u32, 1), line.measure(80).min_height);
}

test "StatusLine publishes shimmer animation while working" {
    var line = StatusLine.init(testing.allocator);
    defer line.deinit();
    line.setWorking("Thinking...");

    const now_ns: i128 = 100;
    try testing.expect(line.nextAnimationDeadline(now_ns) != null);
    try testing.expect(!line.tickAnimation(now_ns));
    try testing.expect(line.nextAnimationDeadline(now_ns + 1) != null);
}

test "StatusLine uses concrete shimmer peak for terminal default theme text" {
    var theme = Theme{
        .fg_colors = [_]Color{Color.rgb(1, 1, 1)} ** @typeInfo(theme_mod.FgColor).@"enum".fields.len,
        .bg_colors = [_]Color{Color.default} ** @typeInfo(theme_mod.BgColor).@"enum".fields.len,
    };
    theme.fg_colors[@intFromEnum(theme_mod.FgColor.dim)] = Color.rgb(0x66, 0x66, 0x66);
    theme.fg_colors[@intFromEnum(theme_mod.FgColor.muted)] = Color.rgb(0x80, 0x80, 0x80);
    theme.fg_colors[@intFromEnum(theme_mod.FgColor.text)] = Color.default;

    var line = StatusLine.init(testing.allocator);
    defer line.deinit();
    line.setTheme(&theme);

    try testing.expect(line.shimmerConfig().peak_fg.eql(default_shimmer_peak));
}
