const std = @import("std");
const builtin = @import("builtin");
const types = @import("process_reactor_types.zig");

const backend = switch (builtin.os.tag) {
    .macos, .ios, .visionos => @import("process_reactor_kqueue.zig"),
    else => @import("process_reactor_engine.zig"),
};

pub const ProcessId = types.ProcessId;
pub const EnvPair = types.EnvPair;
pub const SpawnRequest = types.SpawnRequest;
pub const WriteRequest = types.WriteRequest;
pub const Request = types.Request;
pub const Event = types.Event;
pub const Reactor = backend.Reactor;

test "process reactor request and event payloads own memory" {
    const allocator = std.testing.allocator;
    var spawn_request = try (SpawnRequest{ .id = 1, .argv = &.{ "echo", "ok" }, .cwd = "/tmp", .env = &.{.{ .key = "A", .value = "B" }} }).clone(allocator);
    defer spawn_request.deinit(allocator);
    var write_request = try (WriteRequest{ .id = 1, .bytes = "hello" }).clone(allocator);
    defer write_request.deinit(allocator);
    var event = Event{ .stdout = .{ .id = 1, .bytes = try allocator.dupe(u8, "bytes") } };
    defer event.deinit(allocator);

    try std.testing.expectEqualStrings("echo", spawn_request.argv[0]);
    try std.testing.expectEqualStrings("/tmp", spawn_request.cwd.?);
    try std.testing.expectEqualStrings("B", spawn_request.env[0].value);
    try std.testing.expectEqualStrings("hello", write_request.bytes);
    try std.testing.expectEqualStrings("bytes", event.stdout.bytes);
}

test "process reactor emits ready stdout and exit events" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    try reactor.start();
    try reactor.spawn(.{ .id = 7, .argv = &.{ "/bin/sh", "-c", "printf reactor" } });

    var saw_ready = false;
    var saw_stdout = false;
    var saw_exit = false;
    var attempts: usize = 0;
    while (attempts < 200 and !(saw_ready and saw_stdout and saw_exit)) : (attempts += 1) {
        var batch: [8]Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = try reactor.waitEvents(100);
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(std.testing.allocator);
            switch (event.*) {
                .ready => |id| saw_ready = saw_ready or id == 7,
                .stdout => |out| saw_stdout = saw_stdout or (out.id == 7 and std.mem.eql(u8, out.bytes, "reactor")),
                .exit => |exit| saw_exit = saw_exit or (exit.id == 7 and exit.term != null),
                .stderr, .spawn_failed => {},
            }
        }
    }

    try std.testing.expect(saw_ready);
    try std.testing.expect(saw_stdout);
    try std.testing.expect(saw_exit);
}

test "process reactor stop wakes idle backend" {
    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    try reactor.start();
    reactor.stop();
}

test "process reactor publishes spawn_failed for duplicate process id" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    var reactor = try Reactor.init(std.testing.allocator);
    defer reactor.deinit();
    try reactor.start();
    try reactor.spawn(.{ .id = 11, .argv = &.{ "/bin/sh", "-c", "sleep 1" } });

    var saw_ready = false;
    var attempts: usize = 0;
    while (attempts < 100 and !saw_ready) : (attempts += 1) {
        var batch: [8]Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = try reactor.waitEvents(100);
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(std.testing.allocator);
            switch (event.*) {
                .ready => |id| saw_ready = saw_ready or id == 11,
                else => {},
            }
        }
    }
    try std.testing.expect(saw_ready);

    try reactor.spawn(.{ .id = 11, .argv = &.{ "/bin/sh", "-c", "printf duplicate" } });

    var saw_spawn_failed = false;
    attempts = 0;
    while (attempts < 100 and !saw_spawn_failed) : (attempts += 1) {
        var batch: [8]Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = try reactor.waitEvents(100);
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(std.testing.allocator);
            switch (event.*) {
                .spawn_failed => |id| saw_spawn_failed = saw_spawn_failed or id == 11,
                else => {},
            }
        }
    }
    try std.testing.expect(saw_spawn_failed);
    try reactor.kill(11);
}
