const std = @import("std");

const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const text_component_mod = @import("../components/text.zig");
const notifications = @import("../notifications.zig");
const overlay_mod = @import("../primitives/overlay.zig");
const Interactive = @import("../interactive.zig").Interactive;
const Component = component_mod.Component;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const TextComponent = text_component_mod.Text;

pub const NotificationComponent = struct {
    interactive: *Interactive = undefined,

    pub fn component(self: *NotificationComponent) Component {
        return Component.init(NotificationComponent, self);
    }

    pub fn measure(self: *NotificationComponent, _: u32) Measurement {
        const count = self.interactive.notification_center.records.count();
        return .{ .min_height = if (count > 0) 1 else 0, .preferred_height = @intCast(@min(count, 12)) };
    }

    pub fn render(self: *NotificationComponent, region: Region) void {
        if (region.width == 0 or region.height == 0) return;
        const allocator = self.interactive.allocator;
        var ordered = orderedNotifications(self.interactive, allocator) catch return;
        defer allocator.free(ordered);
        const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));
        const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
        const visible = @min(ordered.len, region.height);
        const start = ordered.len - visible;
        var y: u32 = 0;
        var last_group: ?[]const u8 = null;
        for (ordered[start..]) |item| {
            if (y >= region.height) break;
            const group = item.group orelse "";
            const show_group = last_group == null or !std.mem.eql(u8, last_group.?, group);
            last_group = group;
            const frame_idx: usize = @intCast(@mod(@divTrunc(now_ns, 120 * std.time.ns_per_ms), frames.len));
            const icon = if (item.progress and !item.done) frames[frame_idx] else levelIcon(item.level);
            const label = if (item.title) |title| title else if (show_group and group.len > 0) group else icon;
            const suffix = if (item.annote) |annote| annote else if (item.done) "done" else "";
            const rendered_message = if (item.count > 1)
                std.fmt.allocPrint(allocator, "({d}x) {s}", .{ item.count, item.message }) catch item.message
            else
                item.message;
            defer if (rendered_message.ptr != item.message.ptr) allocator.free(rendered_message);
            const text = if (suffix.len > 0)
                std.fmt.allocPrint(allocator, "{s} {s} — {s}", .{ label, rendered_message, suffix }) catch item.message
            else
                std.fmt.allocPrint(allocator, "{s} {s}", .{ label, rendered_message }) catch item.message;
            defer if (text.ptr != item.message.ptr) allocator.free(text);
            renderNotificationText(allocator, region.sub(0, y, region.width, 1), text, .{ .dim = item.done });
            y += 1;
        }
    }
};

fn renderNotificationText(allocator: std.mem.Allocator, region: Region, text: []const u8, attrs: Attributes) void {
    var component = TextComponent.init(allocator, region.buf.width_method);
    defer component.deinit();
    component.content = text;
    component.attrs = attrs;
    component.wrap_mode = .none;
    component.overflow = .ellipsis;
    component.max_lines = 1;
    component.text_align = .left;
    component.render(region);
}

/// Native notification UI surface. Extension APIs adapt into this; they do not
/// own notification placement or lifecycle.
pub fn notify(self: *Interactive, spec: notifications.Spec) void {
    self.notification_center.apply(spec) catch return;
    sync(self);
    self.tui.dirty = true;
}

pub fn tick(self: *Interactive, now_ns: i128) bool {
    const changed = self.notification_center.expire(now_ns);
    return changed or self.notification_center.hasActiveProgress();
}

pub fn sync(self: *Interactive) void {
    if (self.notification_center.records.count() > 0) {
        self.notification_component.interactive = self;
        if (self.notification_overlay) |handle| {
            handle.setOptions(options(self));
            handle.setHidden(false);
        } else {
            self.notification_overlay = self.tui.showOverlay(self.notification_component.component(), options(self));
        }
    } else if (self.notification_overlay) |handle| {
        self.notification_overlay = null;
        handle.hide();
    }
}

fn options(self: *Interactive) overlay_mod.OverlayOptions {
    var opts = overlay_mod.OverlayPresets.topToast();
    opts.anchor = .bottom_right;
    opts.width = notificationWidth(self);
    opts.max_height = null;
    opts.max_height_percent = 40;
    opts.margin_bottom = bottomMarginAboveEditor(self);
    return opts;
}

fn notificationWidth(self: *Interactive) u32 {
    var width: u32 = 1;
    var it = self.notification_center.records.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr;
        const label = if (item.title) |title| title else if (item.group) |group| group else levelIcon(item.level);
        const suffix = item.annote orelse if (item.done) "done" else "";
        const count_prefix_len: usize = if (item.count > 1) 6 else 0;
        const message_len = item.message.len + count_prefix_len;
        const suffix_len: usize = if (suffix.len > 0) suffix.len + 3 else 0;
        const row_width: u32 = @intCast(label.len + 1 + message_len + suffix_len);
        width = @max(width, row_width);
    }
    return @min(@max(width, 1), 44);
}

fn bottomMarginAboveEditor(self: *Interactive) u32 {
    const editor_child_index = 6;
    const terminal_h = self.tui.height();
    const rect = self.tui.root.childRect(editor_child_index) orelse return 3;
    return if (terminal_h > rect.y) terminal_h - rect.y else 3;
}

fn orderedNotifications(self: *Interactive, allocator: std.mem.Allocator) ![]*const notifications.Spec {
    var list = std.ArrayList(*const notifications.Spec).empty;
    errdefer list.deinit(allocator);
    var it = self.notification_center.records.iterator();
    while (it.next()) |entry| try list.append(allocator, entry.value_ptr);
    std.mem.sort(*const notifications.Spec, list.items, {}, lessNotification);
    return list.toOwnedSlice(allocator);
}

fn lessNotification(_: void, a: *const notifications.Spec, b: *const notifications.Spec) bool {
    if (a.updated_ns != b.updated_ns) return a.updated_ns < b.updated_ns;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn levelIcon(level: notifications.Level) []const u8 {
    return switch (level) {
        .debug => "·",
        .info => "●",
        .warn => "▲",
        .error_ => "✖",
        .success => "✓",
    };
}
