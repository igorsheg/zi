const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const markdown_mod = @import("markdown.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const keybindings = @import("../keybindings.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Theme = theme_mod.Theme;
const Color = cell_mod.Color;

pub const MetaLine = union(enum) {
    none,
    queued_steering,
    queued_follow_up,
    edited,
    custom: []u8,

    pub fn clone(self: MetaLine, allocator: std.mem.Allocator) !MetaLine {
        return switch (self) {
            .none => .none,
            .queued_steering => .queued_steering,
            .queued_follow_up => .queued_follow_up,
            .edited => .edited,
            .custom => |text| .{ .custom = try allocator.dupe(u8, text) },
        };
    }

    fn deinit(self: *MetaLine, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |text| allocator.free(text),
            else => {},
        }
        self.* = .none;
    }

    fn label(self: MetaLine) []const u8 {
        return switch (self) {
            .none => "",
            .queued_steering => "Queued · Steering",
            .queued_follow_up => "Queued · Follow-up",
            .edited => "Edited",
            .custom => |text| text,
        };
    }
};

pub const Status = enum {
    in_chat,
    pending,
};

pub const UserRowModel = struct {
    text: ?[]u8 = null,
    meta: MetaLine = .none,
    status: Status = .in_chat,

    pub fn clone(self: UserRowModel, allocator: std.mem.Allocator) !UserRowModel {
        return .{
            .text = if (self.text) |text| try allocator.dupe(u8, text) else null,
            .meta = try self.meta.clone(allocator),
            .status = self.status,
        };
    }

    pub fn deinit(self: *UserRowModel, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.meta.deinit(allocator);
        self.* = .{};
    }
};

pub const UserMessage = struct {
    allocator: std.mem.Allocator,
    theme: *const Theme = undefined,
    body: markdown_mod.Markdown,
    meta: text_mod.Text,
    meta_visible: bool = false,
    model: UserRowModel = .{},

    pub fn init(allocator: std.mem.Allocator) UserMessage {
        var self = UserMessage{
            .allocator = allocator,
            .theme = themes_builtin.dark(),
            .body = markdown_mod.Markdown.init(allocator),
            .meta = text_mod.Text.init(allocator),
        };
        self.setTheme(self.theme);
        return self;
    }

    pub fn deinit(self: *UserMessage) void {
        self.body.deinit();
        self.meta.deinit();
        self.model.deinit(self.allocator);
    }

    pub fn component(self: *UserMessage) Component {
        return Component.init(UserMessage, self);
    }

    pub fn setTheme(self: *UserMessage, theme: *const Theme) void {
        self.theme = theme;
        self.body.theme = theme;
        self.body.padding_x = 1;
        self.body.padding_y = 1;
        self.body.fg = theme.fg(.user_message_text);

        self.meta.padding_x = 1;
        self.meta.padding_y = 0;
        self.meta.fg = theme.fg(.muted);

        self.applyModel();
    }

    pub fn setOwnedModel(self: *UserMessage, model: *UserRowModel) void {
        self.model.deinit(self.allocator);
        self.model = model.*;
        model.* = .{};
        self.applyModel();
    }

    fn applyModel(self: *UserMessage) void {
        self.applyStatusStyles();
        self.body.setContent(self.model.text orelse "");

        var meta_buf: [128]u8 = undefined;
        const meta_text = metaLineText(self.model.meta, self.model.status, &meta_buf);
        self.meta_visible = meta_text.len > 0;
        self.meta.setContent(meta_text);
    }

    fn applyStatusStyles(self: *UserMessage) void {
        const queued = isQueuedMeta(self.model.meta);
        const bg = if (queued) Color.default else switch (self.model.status) {
            .in_chat, .pending => self.theme.bg(.user_message_bg),
        };

        self.body.bg = bg;
        self.meta.bg = Color.default;
    }

    pub fn measure(self: *UserMessage, width: u32) Measurement {
        const body = self.body.measure(width);
        const meta_h: u32 = if (self.meta_visible) self.meta.measure(width).preferred_height else 0;
        const body_h = self.bodyVisibleHeight(body.preferred_height);
        return .{
            .min_height = @min(body.min_height, body_h) + meta_h,
            .preferred_height = body_h + meta_h,
        };
    }

    pub fn render(self: *UserMessage, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *UserMessage, region: Region, first_row: u32) void {
        const width = region.width;
        const height = region.height;
        if (width == 0 or height == 0) return;

        const body_h = self.bodyVisibleHeight(self.body.measure(width).preferred_height);
        const meta_h: u32 = if (self.meta_visible) self.meta.measure(width).preferred_height else 0;

        var screen_y: u32 = 0;
        if (first_row < body_h) {
            const skipped = first_row;
            const visible_h = @min(body_h - skipped, height - screen_y);
            self.body.renderSlice(region.sub(0, screen_y, width, visible_h), skipped);
            screen_y += visible_h;
        }
        if (!self.meta_visible or screen_y >= height) return;

        if (first_row < body_h + meta_h) {
            const meta_skip = first_row -| body_h;
            const visible_h = @min(meta_h - meta_skip, height - screen_y);
            self.meta.renderSlice(region.sub(0, screen_y, width, visible_h), meta_skip);
        }
    }

    fn bodyVisibleHeight(self: *const UserMessage, measured_height: u32) u32 {
        if (!isQueuedMeta(self.model.meta)) return measured_height;
        return measured_height -| self.body.padding_y;
    }
};

fn metaLineText(meta: MetaLine, status: Status, out: []u8) []const u8 {
    var pos: usize = 0;
    const base = meta.label();

    if (base.len > 0) {
        append(out, &pos, "↩ ");
        append(out, &pos, base);
    }

    if (status == .pending and base.len > 0) {
        append(out, &pos, " · ");
        append(out, &pos, "press ");
        var restore_key: [32]u8 = undefined;
        const restore_binding = keybindings.formatBindings(.app_restore_queued, " / ", &restore_key);
        append(out, &pos, restore_binding);
        append(out, &pos, " to edit");
    }

    return out[0..pos];
}

fn isQueuedMeta(meta: MetaLine) bool {
    return switch (meta) {
        .queued_steering, .queued_follow_up => true,
        else => false,
    };
}

fn append(dst: []u8, pos: *usize, text: []const u8) void {
    if (pos.* >= dst.len) return;
    const copy_len = @min(dst.len - pos.*, text.len);
    @memcpy(dst[pos.*..][0..copy_len], text[0..copy_len]);
    pos.* += copy_len;
}

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn setTestModel(msg: *UserMessage, model: *UserRowModel) void {
    msg.setOwnedModel(model);
}

fn makeTestModel(text: []const u8, meta: MetaLine, status: Status) !UserRowModel {
    return .{
        .text = try testing.allocator.dupe(u8, text),
        .meta = try meta.clone(testing.allocator),
        .status = status,
    };
}

fn bufferText(buf: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..buf.height) |row| {
        if (row > 0) try out.append(allocator, '\n');
        var end = buf.width;
        while (end > 0 and buf.get(end - 1, @intCast(row)).grapheme.codepoint == ' ') : (end -= 1) {}
        for (0..end) |col| {
            const cp = buf.get(@intCast(col), @intCast(row)).grapheme.codepoint;
            var encoded: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &encoded);
            try out.appendSlice(allocator, encoded[0..n]);
        }
    }

    return out.toOwnedSlice(allocator);
}

test "user message renders body and queued meta line from owned model" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();

    var model = try makeTestModel("hello", .queued_follow_up, .in_chat);
    defer model.deinit(testing.allocator);
    setTestModel(&msg, &model);

    var buf = try Buffer.init(testing.allocator, 30, 6);
    defer buf.deinit();
    msg.render(buf.region());

    const text = try bufferText(&buf, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "↩ Queued · Follow-up") != null);
    try testing.expect(buf.get(0, 0).bg.eql(Color.default));
}

test "queued user message meta line is transparent and mentions queued amend shortcut" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();

    var model = try makeTestModel("hello", .queued_follow_up, .pending);
    defer model.deinit(testing.allocator);
    setTestModel(&msg, &model);

    var buf = try Buffer.init(testing.allocator, 80, 6);
    defer buf.deinit();

    msg.render(buf.region());

    var binding_buf: [32]u8 = undefined;
    const binding = keybindings.formatBindings(.app_restore_queued, " / ", &binding_buf);

    const text = try bufferText(&buf, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "↩ Queued · Follow-up") != null);
    try testing.expect(std.mem.indexOf(u8, text, "to edit") != null);
    try testing.expect(buf.get(0, 0).bg.eql(Color.default));
    try testing.expectEqual(@as(u21, '↩'), buf.get(1, 2).grapheme.codepoint);
    try testing.expectEqual(@as(u32, 3), msg.measure(80).preferred_height);
    try testing.expect(std.mem.indexOf(u8, text, binding) != null);
}

test "user message model replacement updates body and meta visibility" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();

    var first = try makeTestModel("hello", .queued_follow_up, .pending);
    defer first.deinit(testing.allocator);
    setTestModel(&msg, &first);
    try testing.expect(msg.meta_visible);

    var second = try makeTestModel("updated", .none, .in_chat);
    defer second.deinit(testing.allocator);
    setTestModel(&msg, &second);

    try testing.expect(!msg.meta_visible);
    try testing.expectEqual(@as(u32, 3), msg.measure(20).preferred_height);
}
