const std = @import("std");
const interactive = @import("../../coding_agent/root.zig").interactive;

pub fn writeHint(
    writer: *std.Io.Writer,
    phase: interactive.Phase,
    active_tool: ?[]const u8,
    queued_count: usize,
) std.Io.Writer.Error!void {
    switch (phase) {
        .model_less => try writer.writeAll("select a model with /model provider/model"),
        .authenticating => try writer.writeAll("signing in..."),
        .transitioning => try writer.writeAll("changing session..."),
        .unavailable => try writer.writeAll("session unavailable"),
        .turn => |turn| switch (turn) {
            .idle => try writer.writeAll("enter send · ctrl+d exit"),
            .awaiting_start => try writer.writeAll("starting... · esc cancel"),
            .running => {
                try writer.writeAll(active_tool orelse "working");
                try writer.writeAll(" · esc cancel");
            },
            .cancel_pending, .cancelling => try writer.writeAll("cancelling..."),
            .dispatching_follow_up => try writer.writeAll("starting queued prompt..."),
            .poisoned => try writer.writeAll("session unavailable · reopen to continue"),
        },
    }
    if (queued_count != 0) try writer.print(" · {d} queued", .{queued_count});
}

test "running hint leads with concrete tool activity" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHint(
        &out.writer,
        .{ .turn = .{ .running = @enumFromInt(1) } },
        "Reading src/main.zig",
        2,
    );
    try std.testing.expectEqualStrings(
        "Reading src/main.zig · esc cancel · 2 queued",
        out.written(),
    );
}
