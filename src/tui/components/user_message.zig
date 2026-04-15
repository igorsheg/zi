const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const markdown_mod = @import("markdown.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const keybindings = @import("../keybindings.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Theme = theme_mod.Theme;

pub const Footer = union(enum) {
    none,
    queued_steering,
    queued_follow_up,
    edited,
    custom: []const u8,
};

pub const Status = enum {
    in_chat,
    pending,
};

pub const Props = struct {
    text: []const u8,
    footer: Footer = .none,
    status: Status = .in_chat,
};

pub const UserMessage = struct {
    allocator: std.mem.Allocator,
    theme: *const Theme = undefined,
    body: markdown_mod.Markdown,
    footer: text_mod.Text,
    footer_visible: bool = false,
    status: Status = .in_chat,

    pub fn init(allocator: std.mem.Allocator) UserMessage {
        var self = UserMessage{
            .allocator = allocator,
            .theme = themes_builtin.dark(),
            .body = markdown_mod.Markdown.init(allocator),
            .footer = text_mod.Text.init(allocator),
        };
        self.setTheme(self.theme);
        return self;
    }

    pub fn deinit(self: *UserMessage) void {
        self.body.deinit();
        self.footer.deinit();
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

        self.footer.padding_x = 1;
        self.footer.padding_y = 0;
        self.footer.fg = theme.fg(.muted);

        self.applyStatusStyles();
    }

    pub fn setProps(self: *UserMessage, props: Props) void {
        self.status = props.status;
        self.applyStatusStyles();

        self.body.setContent(props.text);

        var footer_buf: [128]u8 = undefined;
        const footer_text = footerLabel(props.footer, self.status, &footer_buf);
        self.footer_visible = footer_text.len > 0;
        self.footer.setContent(footer_text);
    }

    fn applyStatusStyles(self: *UserMessage) void {
        const bg = switch (self.status) {
            .in_chat, .pending => self.theme.bg(.user_message_bg),
        };

        self.body.bg = bg;
        self.footer.bg = bg;
    }

    pub fn measure(self: *UserMessage, width: u32) Measurement {
        const body = self.body.measure(width);
        const footer_h: u32 = if (self.footer_visible) self.footer.measure(width).preferred_height else 0;
        return .{
            .min_height = body.min_height + footer_h,
            .preferred_height = body.preferred_height + footer_h,
        };
    }

    pub fn render(self: *UserMessage, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *UserMessage, region: Region, first_row: u32) void {
        const width = region.width;
        const height = region.height;
        if (width == 0 or height == 0) return;

        const body_h = self.body.measure(width).preferred_height;
        const footer_h: u32 = if (self.footer_visible) self.footer.measure(width).preferred_height else 0;

        var screen_y: u32 = 0;
        if (first_row < body_h) {
            const skipped = first_row;
            const visible_h = @min(body_h - skipped, height - screen_y);
            self.body.renderSlice(region.sub(0, screen_y, width, visible_h), skipped);
            screen_y += visible_h;
        }
        if (!self.footer_visible or screen_y >= height) return;

        if (first_row < body_h + footer_h) {
            const footer_skip = first_row -| body_h;
            const visible_h = @min(footer_h - footer_skip, height - screen_y);
            self.footer.renderSlice(region.sub(0, screen_y, width, visible_h), footer_skip);
        }
    }
};

fn footerLabel(footer: Footer, status: Status, out: []u8) []const u8 {
    var pos: usize = 0;
    const base = switch (footer) {
        .none => "",
        .queued_steering => "Queued · Steering",
        .queued_follow_up => "Queued · Follow-up",
        .edited => "Edited",
        .custom => |text| text,
    };

    append(out, &pos, base);

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

fn append(dst: []u8, pos: *usize, text: []const u8) void {
    if (pos.* >= dst.len) return;
    const copy_len = @min(dst.len - pos.*, text.len);
    @memcpy(dst[pos.*..][0..copy_len], text[0..copy_len]);
    pos.* += copy_len;
}

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn bufferText(buf: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..buf.height) |row| {
        if (row > 0) try out.append(allocator, '\n');
        var end = buf.width;
        while (end > 0 and buf.get(end - 1, @intCast(row)).grapheme.codepoint == ' ') : (end -= 1) {}
        for (0..end) |col| {
            const cp = buf.get(@intCast(col), @intCast(row)).grapheme.codepoint;
            try out.append(allocator, @intCast(cp));
        }
    }

    return out.toOwnedSlice(allocator);
}

test "user message renders body and queued footer" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();
    msg.setProps(.{ .text = "hello", .footer = .queued_follow_up });

    var buf = try Buffer.init(testing.allocator, 30, 6);
    defer buf.deinit();
    msg.render(buf.region());

    const text = try bufferText(&buf, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Queued · Follow-up") != null);
}

test "queued user message footer mentions queued amend shortcut" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();
    msg.setProps(.{ .text = "hello", .footer = .queued_follow_up, .status = .pending });

    var buf = try Buffer.init(testing.allocator, 80, 6);
    defer buf.deinit();

    msg.render(buf.region());

    var binding_buf: [32]u8 = undefined;
    const binding = keybindings.formatBindings(.app_restore_queued, " / ", &binding_buf);

    const text = try bufferText(&buf, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Queued · Follow-up") != null);
    try testing.expect(std.mem.indexOf(u8, text, "to edit") != null);
    try testing.expect(std.mem.indexOf(u8, text, binding) != null);
}

test "queued user message has distinct background" {
    var convo_msg = UserMessage.init(testing.allocator);
    defer convo_msg.deinit();
    convo_msg.setProps(.{ .text = "hello" });

    var convo_buf = try Buffer.init(testing.allocator, 40, 6);
    defer convo_buf.deinit();
    convo_msg.render(convo_buf.region());

    var queued_msg = UserMessage.init(testing.allocator);
    defer queued_msg.deinit();
    queued_msg.setProps(.{ .text = "hello", .footer = .queued_follow_up, .status = .pending });

    var queued_buf = try Buffer.init(testing.allocator, 40, 6);
    defer queued_buf.deinit();
    queued_msg.render(queued_buf.region());

    const theme = themes_builtin.dark();
    try testing.expectEqual(theme.bg(.user_message_bg), convo_buf.get(0, 0).bg);
    try testing.expectEqual(theme.bg(.user_message_bg), queued_buf.get(0, 0).bg);
}

test "user message can omit footer" {
    var msg = UserMessage.init(testing.allocator);
    defer msg.deinit();
    msg.setProps(.{ .text = "hello" });

    try testing.expectEqual(@as(u32, 3), msg.measure(20).preferred_height);
}
