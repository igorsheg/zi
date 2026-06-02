const std = @import("std");
const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");
const infra = @import("../infra/root.zig");
const substrate = @import("../substrate/root.zig");

test "product frame renders through substrate renderer transaction" {
    var app = try app_mod.ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);
    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 4, frame_mod.size_cells_max);
    defer renderer.deinit();
    var storage: [4096]u8 = undefined;
    var output = infra.FrameOutput.init(&storage);

    const text = substrate.input.InlineBytes.from("hello");
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .text = text } }) == null);
    try frame_mod.Frame.build(&app, &renderer);
    const diff = try renderer.stage(&output);
    try std.testing.expect(diff.changed > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes(), "h") != null);
    renderer.commit();
    app.dirty = false;

    output.reset();
    try frame_mod.Frame.build(&app, &renderer);
    const second = try renderer.stage(&output);
    try std.testing.expectEqual(@as(usize, 0), second.changed);
    renderer.commit();
}
