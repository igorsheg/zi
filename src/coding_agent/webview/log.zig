const std = @import("std");

const default_io = std.Options.debug_io;
const core_log_path = "/tmp/zi-webview-core.log";

pub fn coreLog(comptime fmt: []const u8, args: anytype) void {
    if (!debugEnabled()) return;

    var file = std.Io.Dir.createFile(.cwd(), default_io, core_log_path, .{ .truncate = false }) catch return;
    defer file.close(default_io);
    const len = file.length(default_io) catch 0;
    var small: [1]u8 = undefined;
    var writer = file.writer(default_io, &small);
    writer.seekTo(len) catch return;
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    writer.interface.writeAll(line) catch return;
    writer.flush() catch return;
}

fn debugEnabled() bool {
    const raw = std.c.getenv("ZI_WEBVIEW_DEBUG") orelse return false;
    return std.mem.span(raw).len != 0;
}
