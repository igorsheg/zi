const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const status_data_mod = @import("../status_data.zig");
const theme_mod = @import("../theme.zig");
const shimmer_mod = @import("../shimmer.zig");
const grapheme_mod = @import("../grapheme.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const StatusData = status_data_mod.StatusData;
const Theme = theme_mod.Theme;
const Shimmer = shimmer_mod.Config;

/// Single TUI-owned composer for the status area.
///
/// Status semantics (primary messages, working state, extension statuses) are
/// kept as data here and rendered as one presentation line. No caller should
/// clear/replace the status slot to show loader/status behavior.
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

    pub fn init(allocator: std.mem.Allocator) StatusLine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StatusLine) void {
        self.primary_buf.deinit(self.allocator);
        self.working_buf.deinit(self.allocator);
    }

    pub fn setPrimary(self: *StatusLine, text: []const u8, fg: Color) void {
        self.primary_buf.clearRetainingCapacity();
        self.primary_buf.appendSlice(self.allocator, text) catch return;
        self.primary_text = self.primary_buf.items;
        self.primary_fg = fg;
    }

    pub fn clearPrimary(self: *StatusLine) void {
        self.primary_buf.clearRetainingCapacity();
        self.primary_text = "";
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
        if (!self.working_active or self.working_message.len == 0) return null;
        return shimmer_mod.nextDeadline(now_ns, self.shimmerConfig());
    }

    pub fn tickAnimation(self: *StatusLine, now_ns: i128) bool {
        if (!self.working_active or self.working_message.len == 0) return false;
        const phase = shimmer_mod.phaseForTime(now_ns, self.shimmerConfig(), self.working_message);
        if (phase == self.shimmer_phase) return false;
        self.shimmer_phase = phase;
        return true;
    }

    pub fn measure(self: *StatusLine, width: u32) Measurement {
        _ = self;
        _ = width;
        // Reserve the status slot even when the line is empty so the transcript
        // does not jump when transient working/status text disappears.
        return .{ .min_height = 1, .preferred_height = 1 };
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
        return .{ .text = self.primary_text, .fg = self.primary_fg };
    }

    fn renderWorking(self: *StatusLine, region: Region) void {
        const working_cols: u32 = @intCast(grapheme_mod.strWidth(self.working_message));
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
            .peak_fg = Color.rgb(0xF2, 0xF1, 0xEF),
            .base_attrs = .{ .dim = true },
            .edge_attrs = .{},
            .peak_attrs = .{},
        };
    }
};

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

test "StatusLine renders extension statuses sorted values only" {
    var data = StatusData.init(testing.allocator);
    defer data.deinit();
    data.setStatus("b", "second");
    data.setStatus("a", "first");

    var line = StatusLine.init(testing.allocator);
    defer line.deinit();
    line.setStatusData(&data);

    const composed = try line.compose(80);
    defer testing.allocator.free(composed.text);
    try testing.expectEqualStrings("first second", composed.text);
}
