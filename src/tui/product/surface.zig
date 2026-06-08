const std = @import("std");
const substrate = @import("../substrate/root.zig");

pub const title_bytes_max: usize = 80;
pub const body_bytes_max: usize = 512;
pub const ModalId = u32;

pub const OpenConfirm = struct {
    id: ModalId,
    title: []const u8,
    body: []const u8,
};

pub const ConfirmResult = struct {
    id: ModalId,
    accepted: bool,
};

pub const Confirm = struct {
    id: ModalId,
    title: []u8,
    body: []u8,
    selected_yes: bool = true,

    pub fn init(allocator: std.mem.Allocator, open: OpenConfirm) !Confirm {
        try validateOpen(open);
        const title = try allocator.dupe(u8, open.title);
        errdefer allocator.free(title);
        const body = try allocator.dupe(u8, open.body);
        errdefer allocator.free(body);
        return .{
            .id = open.id,
            .title = title,
            .body = body,
        };
    }

    pub fn deinit(self: *Confirm, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.title);
        self.* = undefined;
    }

    pub fn applyInput(self: *Confirm, event: substrate.input.InputEvent) ?ConfirmResult {
        return switch (event) {
            .text => |bytes| self.applyText(bytes.slice()),
            .key => |key| switch (key) {
                .enter => self.result(self.selected_yes),
                .escape => self.result(false),
                .arrow_left, .arrow_right, .tab, .backtab => blk: {
                    self.selected_yes = !self.selected_yes;
                    break :blk null;
                },
                .ctrl => |c| if (c == 0x03) self.result(false) else null,
                else => null,
            },
            else => null,
        };
    }

    fn applyText(self: *Confirm, bytes: []const u8) ?ConfirmResult {
        if (bytes.len == 1) {
            if (bytes[0] == 'y' or bytes[0] == 'Y') return self.result(true);
            if (bytes[0] == 'n' or bytes[0] == 'N') return self.result(false);
        }
        return null;
    }

    fn result(self: Confirm, accepted: bool) ConfirmResult {
        return .{ .id = self.id, .accepted = accepted };
    }
};

fn validateOpen(open: OpenConfirm) !void {
    if (open.id == 0) return error.InvalidModal;
    try validateText(open.title, title_bytes_max);
    try validateText(open.body, body_bytes_max);
}

fn validateText(bytes: []const u8, max: usize) !void {
    if (bytes.len > max) return error.ModalTextTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidModalText;
}

test "confirm modal accepts cancels and toggles selection" {
    var confirm = try Confirm.init(std.testing.allocator, .{
        .id = 1,
        .title = "Title",
        .body = "Body",
    });
    defer confirm.deinit(std.testing.allocator);

    try std.testing.expect((confirm.applyInput(.{
        .text = substrate.input.InlineBytes.from("n"),
    })).?.accepted == false);
    try std.testing.expect(confirm.applyInput(.{ .key = .arrow_right }) == null);
    try std.testing.expect((confirm.applyInput(.{ .key = .enter })).?.accepted == false);
    try std.testing.expect(confirm.applyInput(.{ .key = .arrow_left }) == null);
    try std.testing.expect((confirm.applyInput(.{ .key = .enter })).?.accepted == true);
}

test "confirm modal rejects invalid open before allocation" {
    try std.testing.expectError(error.InvalidModal, Confirm.init(std.testing.allocator, .{
        .id = 0,
        .title = "",
        .body = "",
    }));
    try std.testing.expectError(error.InvalidModalText, Confirm.init(std.testing.allocator, .{
        .id = 1,
        .title = "\xff",
        .body = "",
    }));
}
