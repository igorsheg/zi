const std = @import("std");
const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");
const infra = @import("../infra/root.zig");

pub const VScreenHarness = struct {
    allocator: std.mem.Allocator,
    app: app_mod.ProductApp,
    renderer: infra.Renderer,
    output: infra.FrameOutput,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        output_storage: []u8,
    ) !VScreenHarness {
        var app = try app_mod.ProductApp.init(width, height);
        errdefer app.deinit(allocator);
        var renderer = try infra.Renderer.init(allocator, width, height, frame_mod.size_cells_max);
        errdefer renderer.deinit();
        return .{
            .allocator = allocator,
            .app = app,
            .renderer = renderer,
            .output = infra.FrameOutput.init(output_storage),
        };
    }

    pub fn deinit(self: *VScreenHarness) void {
        self.renderer.deinit();
        self.app.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn apply(self: *VScreenHarness, command: app_mod.Command) !?app_mod.Effect {
        return self.app.apply(self.allocator, command);
    }

    pub fn build(self: *VScreenHarness) !void {
        try frame_mod.Frame.build(&self.app, &self.renderer);
    }

    pub fn stage(self: *VScreenHarness) !infra.renderer.FrameDiff {
        return self.renderer.stage(&self.output);
    }

    pub fn commit(self: *VScreenHarness) void {
        self.renderer.commit();
        self.app.dirty = false;
    }

    pub fn render(self: *VScreenHarness) !infra.renderer.FrameDiff {
        self.output.reset();
        try self.build();
        const diff = try self.stage();
        self.commit();
        return diff;
    }

    pub fn nextCell(self: *const VScreenHarness, x: u16, y: u16) !infra.Cell {
        return self.renderer.next.get(x, y);
    }

    pub fn dumpTextAlloc(self: *const VScreenHarness) ![]u8 {
        return dumpCellBufferText(self.allocator, self.renderer.next);
    }
};

pub fn dumpCellBufferText(allocator: std.mem.Allocator, buffer: anytype) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var y: u16 = 0;
    while (y < buffer.height) : (y += 1) {
        if (y > 0) try out.append(allocator, '\n');
        const row_start = out.items.len;
        var x: u16 = 0;
        while (x < buffer.width) : (x += 1) {
            const cell = try buffer.get(x, y);
            switch (cell.kind) {
                .empty, .wide_continuation => try out.append(allocator, ' '),
                .grapheme, .wide_head => {
                    const rendered = cell.renderText().?;
                    try out.appendSlice(allocator, rendered.slice());
                },
            }
        }
        trimTrailingSpaces(&out, row_start);
    }

    return out.toOwnedSlice(allocator);
}

fn trimTrailingSpaces(out: *std.ArrayListUnmanaged(u8), row_start: usize) void {
    while (out.items.len > row_start and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
}

test "vscreen harness renders and commits deterministic frame" {
    var storage: [4096]u8 = undefined;
    var harness = try VScreenHarness.init(std.testing.allocator, 20, 4, &storage);
    defer harness.deinit();

    const diff = try harness.render();
    try std.testing.expect(diff.changed > 0);

    harness.output.reset();
    try harness.build();
    const second = try harness.stage();
    try std.testing.expectEqual(@as(usize, 0), second.changed);
    harness.commit();
}

test "vscreen harness dumps normalized screen text" {
    var storage: [4096]u8 = undefined;
    var harness = try VScreenHarness.init(std.testing.allocator, 20, 4, &storage);
    defer harness.deinit();

    try harness.app.composer.insertUtf8(std.testing.allocator, "hello");
    _ = try harness.render();
    const dump = try harness.dumpTextAlloc();
    defer std.testing.allocator.free(dump);

    try std.testing.expectEqualStrings("zi\n\n\n> hello", dump);
}
