const std = @import("std");
const input_mod = @import("input.zig");

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
        if (open.id == 0) return error.InvalidModal;
        try validateText(open.title, title_bytes_max);
        try validateText(open.body, body_bytes_max);
        const title = try allocator.dupe(u8, open.title);
        errdefer allocator.free(title);
        const body = try allocator.dupe(u8, open.body);
        errdefer allocator.free(body);
        return .{ .id = open.id, .title = title, .body = body };
    }

    pub fn deinit(self: *Confirm, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.title);
        self.* = undefined;
    }

    pub fn applyInput(self: *Confirm, event: input_mod.Input) ?ConfirmResult {
        return switch (event) {
            .text => |bytes| self.applyText(bytes.slice()),
            .key => |key| switch (key) {
                .enter => self.result(self.selected_yes),
                .escape, .ctrl_c => self.result(false),
                .arrow_left, .arrow_right, .tab => blk: {
                    self.selected_yes = !self.selected_yes;
                    break :blk null;
                },
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

fn validateText(bytes: []const u8, max: usize) !void {
    if (bytes.len > max) return error.ModalTextTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidModalText;
}
