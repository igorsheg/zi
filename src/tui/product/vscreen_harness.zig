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
};

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
