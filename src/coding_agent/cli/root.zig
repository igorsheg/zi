const entry = @import("entry.zig");
const initial_message = @import("initial_message.zig");
const launch = @import("launch.zig");
const print_mode = @import("print_mode.zig");
const surface = @import("surface.zig");

pub const run = entry.run;

const std = @import("std");
const ai_testing = @import("../../ai/testing.zig");
const AgentSession = @import("../AgentSession.zig");

test "CLI core parses, composes, runs sequential prompts, and prints only the final response" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-print" },
        .steps = &.{
            .{ .text = "first response" },
            .{ .text = "final response" },
        },
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const parsed = surface.parseInvocation(&.{ "-p", "first prompt", "second prompt" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(parsed == .admitted);
    const request = parsed.admitted.launch;
    var initial = try initial_message.buildInitialMessage(
        std.testing.allocator,
        request.messages(),
        "stdin\n",
        null,
    );
    defer initial.deinit();
    const exit = try print_mode.runPrintMode(
        &session,
        .{ .initial_message = initial.text, .messages = initial.remaining_messages },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .success);
    try std.testing.expectEqualStrings("final response\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
    const history = session.messages();
    try std.testing.expectEqual(@as(usize, 4), history.len);
    try std.testing.expectEqualStrings("stdin\nfirst prompt", history[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings("first response", history[1].response.parts[0].text.text);
    try std.testing.expectEqualStrings("second prompt", history[2].request.parts[0].user.text);
    try std.testing.expectEqualStrings("final response", history[3].response.parts[0].text.text);
}

test "text print mode routes a settled agent failure only to stderr" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-failure" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try print_mode.runPrintMode(
        &session,
        .{ .initial_message = "fail" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .failure);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("Request failed: InvalidRequest\n", stderr.written());
    try std.testing.expect(session.state() == .failed);
}

test "text print mode rejects invalid and excessive prompts before model admission" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-invalid" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try print_mode.runPrintMode(
        &session,
        .{ .initial_message = "\xff" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .failure);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("Prompt is not valid UTF-8.\n", stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(session.state() == .idle);

    var later_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer later_stdout.deinit();
    var later_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer later_stderr.deinit();
    const later_exit = try print_mode.runPrintMode(
        &session,
        .{ .initial_message = "valid", .messages = &.{"\xff"} },
        &later_stdout.writer,
        &later_stderr.writer,
    );
    try std.testing.expect(later_exit == .failure);
    try std.testing.expectEqualStrings("", later_stdout.written());
    try std.testing.expectEqualStrings("Prompt is not valid UTF-8.\n", later_stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);

    var messages: [65][]const u8 = undefined;
    @memset(&messages, "");
    var count_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count_stdout.deinit();
    var count_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count_stderr.deinit();
    const count_exit = try print_mode.runPrintMode(
        &session,
        .{ .messages = &messages },
        &count_stdout.writer,
        &count_stderr.writer,
    );
    try std.testing.expect(count_exit == .failure);
    try std.testing.expectEqualStrings("", count_stdout.written());
    try std.testing.expectEqualStrings(
        "Print mode accepts at most 64 prompts.\n",
        count_stderr.written(),
    );
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
}

test "text print mode succeeds silently without a prompt" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-empty" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try print_mode.runPrintMode(&session, .{}, &stdout.writer, &stderr.writer);
    try std.testing.expect(exit == .success);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(session.state() == .idle);
}

test {
    _ = entry;
    _ = initial_message;
    _ = launch;
    _ = print_mode;
    _ = surface;
}
