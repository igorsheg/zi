//! Dev-only real terminal fixture for TUI smoke tests. It owns no agent,
//! provider, auth, session store, or network. The only purpose is to exercise
//! the real tui.Terminal path under a tty/tmux with deterministic resident
//! transcript data and fake history pages.
const std = @import("std");
const tui = @import("tui");

const initial_items = 48;
const history_pages_max = 4;
const history_page_items = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const terminal = try tui.Terminal.init(gpa, io, 80, 24);
    defer terminal.deinit();
    try terminal.setup();
    defer terminal.shutdown() catch |err| ignoreBestEffortError(err);

    try seedTranscript(terminal);
    try terminal.renderIfDirty();

    var history_pages_loaded: usize = 0;
    var effects: [tui.Terminal.effects_per_read_max]tui.Effect = undefined;
    while (terminal.isRunning()) {
        var fds = [_]std.posix.pollfd{.{
            .fd = terminal.inputFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, 50);
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const result = try terminal.readAvailableInput(&effects);
            defer for (effects[0..result.effect_count]) |effect| effect.deinit(gpa);
            for (effects[0..result.effect_count]) |effect| switch (effect) {
                .submit_text => |text| {
                    if (std.mem.eql(u8, text, "/quit")) {
                        terminal.requestStop();
                    } else {
                        _ = try terminal.applyCommand(.{ .append_transcript = .{ .status = .{
                            .level = .info,
                            .text = "fixture received prompt",
                        } } });
                    }
                },
                .interrupt, .request_shutdown => terminal.requestStop(),
                .request_transcript_history => if (history_pages_loaded < history_pages_max) {
                    try prependHistoryPage(terminal, history_pages_loaded);
                    history_pages_loaded += 1;
                },
            };
            if (result.shutdown_requested) terminal.requestStop();
            if (result.truncated) {
                _ = try terminal.applyCommand(.{ .append_transcript = .{ .status = .{
                    .level = .warning,
                    .text = "fixture input truncated",
                } } });
            }
        }
        try terminal.renderIfDirty();
    }
}

fn seedTranscript(terminal: *tui.Terminal) !void {
    var buffer: [96]u8 = undefined;
    var index: usize = 0;
    while (index < initial_items) : (index += 1) {
        const text = std.fmt.bufPrint(&buffer, "fixture live row {d:0>2}", .{index}) catch unreachable;
        _ = try terminal.applyCommand(.{ .append_transcript = .{ .message = .{
            .role = .assistant,
            .text = text,
            .mode = .new_item,
        } } });
    }
    _ = try terminal.applyCommand(.{ .append_transcript = .{ .status = .{
        .level = .info,
        .text = "fixture: wheel up for older rows; type /quit to exit",
    } } });
}

fn prependHistoryPage(terminal: *tui.Terminal, page: usize) !void {
    var buffer: [96]u8 = undefined;
    var index: usize = history_page_items;
    while (index > 0) {
        index -= 1;
        const text = std.fmt.bufPrint(
            &buffer,
            "fixture older page {d} row {d}",
            .{ page, index },
        ) catch unreachable;
        _ = try terminal.applyCommand(.{ .prepend_transcript = .{
            .role = .user,
            .text = text,
            .mode = .new_item,
        } });
    }
}

fn ignoreBestEffortError(err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);
}
