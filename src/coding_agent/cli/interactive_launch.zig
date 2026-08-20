const std = @import("std");
const interactive = @import("../interactive/root.zig");
const TurnWorker = @import("../TurnWorker.zig");
const initial_message = @import("initial_message.zig");
const launch = @import("launch.zig");
const print_mode = @import("print_mode.zig");
const surface = @import("surface.zig");

const max_initial_prompts = 64;

/// Takes ownership of the created runtime on successful worker admission.
pub fn runInteractiveLaunch(
    request: *const surface.LaunchRequest,
    context: launch.LaunchContext,
) !print_mode.ExitCode {
    var prepared = (try launch.prepareInitial(request, context, false)) orelse return .failure;
    defer prepared.deinit();
    const runtime = (try launch.createRuntime(request, context)) orelse return .failure;
    const transcript = runtime.transcript();
    const worker = TurnWorker.start(
        context.allocator,
        context.io,
        TurnWorker.SessionOwner.from(runtime),
        .{},
    ) catch |failure| {
        runtime.deinit();
        try context.stderr.print("Unable to start the interactive worker: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    defer worker.deinit();

    var app = interactive.App.init(
        context.allocator,
        context.io,
        worker,
        context.stdout,
        .{},
    ) catch |failure| {
        try context.stderr.print("Unable to start interactive mode: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    defer app.deinit();

    var prompt_buffer: [max_initial_prompts][]const u8 = undefined;
    const prompts = collectInitialPrompts(&prepared.value, &prompt_buffer);
    const cause = app.run(
        std.Io.File.stdin(),
        std.Io.File.stdout(),
        transcript,
        .{ .initial_prompts = prompts },
    ) catch |failure| {
        try context.stderr.print("Interactive mode failed: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    return switch (cause) {
        .requested => .success,
        .input_closed => closed: {
            try context.stderr.writeAll("Interactive terminal input closed unexpectedly.\n");
            break :closed .failure;
        },
    };
}

fn collectInitialPrompts(
    initial: *const initial_message.InitialMessage,
    buffer: *[max_initial_prompts][]const u8,
) []const []const u8 {
    var count: usize = 0;
    if (initial.text) |text| {
        buffer[count] = text;
        count += 1;
    }
    for (initial.remaining_messages) |message| {
        buffer[count] = message;
        count += 1;
    }
    return buffer[0..count];
}

test "interactive launch preserves composed initial prompt order" {
    var initial = try initial_message.buildInitialMessage(
        std.testing.allocator,
        &.{ "first", "second", "third" },
        null,
        "file:",
    );
    defer initial.deinit();
    var buffer: [max_initial_prompts][]const u8 = undefined;
    const prompts = collectInitialPrompts(&initial, &buffer);
    try std.testing.expectEqual(@as(usize, 3), prompts.len);
    try std.testing.expectEqualStrings("file:first", prompts[0]);
    try std.testing.expectEqualStrings("second", prompts[1]);
    try std.testing.expectEqualStrings("third", prompts[2]);
}
