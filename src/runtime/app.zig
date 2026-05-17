const std = @import("std");
const build_options = @import("build_options");
const runtime_env = @import("env.zig");
const log = @import("log.zig");

pub const name = "zi";
pub const version = build_options.version;
pub const tagline = "AI coding agent";

pub fn writeVersionLine(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}

test "version line uses app metadata" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersionLine(&out.writer);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} {s}\n", .{ name, version });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}

pub const use_debug_allocator = false;

pub const MainHeap = struct {
    debug_allocator: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void = if (use_debug_allocator) .init else {},

    pub fn allocator(self: *MainHeap) std.mem.Allocator {
        return if (use_debug_allocator) self.debug_allocator.allocator() else std.heap.smp_allocator;
    }

    pub fn deinit(self: *MainHeap) void {
        if (use_debug_allocator) {
            switch (self.debug_allocator.deinit()) {
                .ok => {},
                .leak => @panic("memory leak detected"),
            }
        }
    }
};

pub const Caps = struct {
    io: std.Io,
    env: runtime_env.Env,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    log.setThreadLabel(.main);
    const env = runtime_env.Env.from(init.environ_map);

    var heap: MainHeap = .{};
    defer heap.deinit();

    const allocator = heap.allocator();

    var log_session = try log.init(allocator, .{
        .io = init.io,
        .sink = .stderr,
        .min_level = .info,
    });
    defer log_session.deinit();

    const caps: Caps = .{
        .io = init.io,
        .env = env,
        .allocator = allocator,
    };
    _ = caps;
}
