const std = @import("std");
const runtime = @import("../runtime/root.zig");
const tui = @import("../tui/root.zig");
const auth_mode = @import("auth_mode.zig");
const sdk = @import("sdk.zig");
const tui_owner = @import("tui_owner.zig");

pub const Options = struct {
    initial_prompt: ?[]const u8 = null,
    resume_session_file: ?[]const u8 = null,
};

pub fn run(process: runtime.Process, options: auth_mode.Options, tui_options: Options) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);

    var app_runtime = if (tui_options.resume_session_file) |session_file| blk: {
        break :blk try sdk.resumeRuntimeHost(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_file_name = session_file,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    } else blk: {
        const session_id = try std.fmt.allocPrint(process.gpa, "tui-{d}", .{timestamp});
        defer process.gpa.free(session_id);
        break :blk try sdk.createRuntimeHost(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_id = session_id,
            .timestamp = timestamp_text,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    };
    defer app_runtime.deinit();

    var terminal: tui.substrate.terminal.Terminal = undefined;
    try terminal.init(process.gpa, process.io, process.environ);
    defer terminal.deinit();

    var event_loop = terminal.eventLoop();
    var terminal_events: tui.substrate.event_pump.TerminalEvents = undefined;
    try terminal_events.init(process.zio_runtime, &event_loop);
    defer terminal_events.deinit();
    try terminal.setupStartedEventLoop(&event_loop);

    var owner = tui_owner.OwnerLoop.init(process.gpa, &app_runtime.host, &terminal, &terminal_events);
    defer owner.deinit();
    if (tui_options.initial_prompt) |prompt| {
        try owner.submitInitialPrompt(prompt);
    }
    try owner.renderIfDirty();
    try owner.run();
}
