const std = @import("std");

const component_mod = @import("../component.zig");
const text_mod = @import("../components/text.zig");
const framebuffer_surface_mod = @import("../components/framebuffer_surface.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");

const Component = component_mod.Component;

pub const ExtensionUiState = struct {
    allocator: std.mem.Allocator,
    report_text: text_mod.Text,
    message_text: text_mod.Text,
    surface: framebuffer_surface_mod.FramebufferSurface,
    report_id: ?[]const u8 = null,
    report_scroll_offsets: std.StringHashMapUnmanaged(u32) = .{},

    pub fn init(allocator: std.mem.Allocator) ExtensionUiState {
        return .{
            .allocator = allocator,
            .report_text = text_mod.Text.init(allocator),
            .message_text = text_mod.Text.init(allocator),
            .surface = framebuffer_surface_mod.FramebufferSurface.init(allocator),
        };
    }

    pub fn deinit(self: *ExtensionUiState) void {
        self.surface.deinit();
        self.message_text.deinit();
        self.clearReportScrollState();
        self.report_text.deinit();
    }

    pub fn reportComponent(self: *ExtensionUiState) Component {
        return self.report_text.component();
    }

    pub fn messageComponent(self: *ExtensionUiState) Component {
        return self.message_text.component();
    }

    pub fn surfaceComponent(self: *ExtensionUiState) Component {
        return self.surface.component();
    }

    pub fn applyReport(self: *ExtensionUiState, report: extension_ui.Report) void {
        self.saveCurrentReportScrollOffset();
        const text = switch (report.format) {
            .text => report.flattenText(self.allocator),
        } catch return;
        defer self.allocator.free(text);
        self.report_text.setContent(text);
        self.report_text.scroll_offset = self.report_scroll_offsets.get(report.id) orelse 0;
        self.setCurrentReportId(report.id);
    }

    pub fn applyMessage(self: *ExtensionUiState, update: extension_ui.UiPublication) void {
        self.message_text.setContent(update.text orelse "");
    }

    pub fn applyProgress(self: *ExtensionUiState, update: extension_ui.UiPublication) void {
        self.saveCurrentReportScrollOffset();
        self.clearCurrentReportId();
        const text = self.formatProgress(update) catch return;
        defer self.allocator.free(text);
        self.report_text.setContent(text);
        self.report_text.scroll_offset = 0;
    }

    pub fn applySurfaceUpdate(self: *ExtensionUiState, update: extension_ui.SurfaceUpdate) void {
        self.surface.apply(update);
    }

    pub fn keyboardSurfaceId(self: *const ExtensionUiState) ?[]const u8 {
        return self.surface.keyboardSurfaceId();
    }

    fn saveCurrentReportScrollOffset(self: *ExtensionUiState) void {
        const id = self.report_id orelse return;
        const owned_key = self.allocator.dupe(u8, id) catch return;
        if (self.report_scroll_offsets.fetchRemove(id)) |old| {
            self.allocator.free(old.key);
        }
        self.report_scroll_offsets.put(self.allocator, owned_key, self.report_text.scroll_offset) catch {
            self.allocator.free(owned_key);
        };
    }

    fn setCurrentReportId(self: *ExtensionUiState, id: []const u8) void {
        self.clearCurrentReportId();
        self.report_id = self.allocator.dupe(u8, id) catch null;
    }

    fn clearCurrentReportId(self: *ExtensionUiState) void {
        if (self.report_id) |old| self.allocator.free(old);
        self.report_id = null;
    }

    fn clearReportScrollState(self: *ExtensionUiState) void {
        self.clearCurrentReportId();
        var iter = self.report_scroll_offsets.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.report_scroll_offsets.deinit(self.allocator);
        self.report_scroll_offsets = .{};
    }

    fn formatProgress(self: *ExtensionUiState, update: extension_ui.UiPublication) ![]const u8 {
        if (update.text) |text| return try self.allocator.dupe(u8, text);
        const title = update.title orelse "Progress";
        const detail = update.detail;
        const status_suffix: []const u8 = switch (update.progress_status orelse .running) {
            .running => "",
            .done => " done",
            .@"error" => " error",
            .cancelled => " cancelled",
        };
        if (update.current) |cur| {
            if (update.total) |tot| {
                if (detail) |d| return try std.fmt.allocPrint(self.allocator, "{s}{s} {d}/{d} — {s}", .{ title, status_suffix, cur, tot, d });
                return try std.fmt.allocPrint(self.allocator, "{s}{s} {d}/{d}", .{ title, status_suffix, cur, tot });
            }
            if (detail) |d| return try std.fmt.allocPrint(self.allocator, "{s}{s} {d} — {s}", .{ title, status_suffix, cur, d });
            return try std.fmt.allocPrint(self.allocator, "{s}{s} {d}", .{ title, status_suffix, cur });
        }
        if (update.indeterminate) {
            if (detail) |d| return try std.fmt.allocPrint(self.allocator, "{s}{s} … — {s}", .{ title, status_suffix, d });
            return try std.fmt.allocPrint(self.allocator, "{s}{s} …", .{ title, status_suffix });
        }
        if (detail) |d| return try std.fmt.allocPrint(self.allocator, "{s}{s} — {s}", .{ title, status_suffix, d });
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ title, status_suffix });
    }
};
