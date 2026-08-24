const std = @import("std");
const ai = @import("../ai/root.zig");
const interactive = @import("../coding_agent/root.zig").interactive;
const RenderInvalidation = @import("render_invalidation.zig");
const transcript = @import("transcript/root.zig");
const render = @import("render_engine/root.zig");
const FramePlan = @import("render_engine/frame_plan.zig");
const TerminalSession = @import("terminal/Session.zig");

const Screen = @This();

const default_max_store_bytes = transcript.default_max_store_bytes;

pub const InitOptions = struct {
    max_store_bytes: usize = default_max_store_bytes,
};

pub const FrameView = struct {
    composer: render.FrameBuilder.ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
    active_model: ?ai.ModelIdentity = null,
    thinking_level: ?ai.ThinkingLevel = null,
    cwd: []const u8 = "",
    slash_menu: ?render.FrameBuilder.SlashMenuProjection = null,
};

allocator: std.mem.Allocator,
output: *std.Io.Writer,
transcript_runtime: transcript.Runtime,
invalidations: RenderInvalidation.State = .{},
terminal_renderer: render.TerminalRenderer,
size: ?TerminalSession.Size = null,

pub fn init(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    options: InitOptions,
) !Screen {
    return .{
        .allocator = allocator,
        .output = output,
        .transcript_runtime = try .init(allocator, options.max_store_bytes),
        .terminal_renderer = .init(allocator),
    };
}

pub fn deinit(self: *Screen) void {
    self.terminal_renderer.deinit();
    self.transcript_runtime.deinit();
    self.* = undefined;
}

/// Admits the exact terminal geometry and the one-based row returned by the
/// terminal cursor probe. This must happen before startup or publication.
pub fn begin(self: *Screen, size: TerminalSession.Size, launch_row: u16) !void {
    if (self.size != null) return error.AlreadyPrepared;
    try self.terminal_renderer.begin(
        .{ .rows = size.rows, .columns = size.columns },
        launch_row,
    );
    self.size = size;
}

pub fn start(
    self: *Screen,
    restored: ?*const interactive.SessionTranscript,
) !void {
    if (self.size == null) return error.ScreenNotPrepared;
    try self.transcript_runtime.start(restored);
    self.invalidations.invalidate();
}

pub fn apply(self: *Screen, fact: interactive.HostFact) !void {
    try self.transcript_runtime.apply(fact);
    self.invalidations.invalidate();
}

pub fn notice(self: *Screen, text: []const u8) !void {
    try self.transcript_runtime.notice(text);
    self.invalidations.invalidate();
}

pub fn editorChanged(self: *Screen) void {
    self.invalidations.invalidate();
}

pub fn resized(self: *Screen, size: TerminalSession.Size) !void {
    if (self.size == null) return error.ScreenNotPrepared;
    if (size.rows == 0 or size.columns == 0) return error.InvalidTerminalSize;
    if (std.meta.eql(self.size.?, size)) return;
    self.size = size;
    self.invalidations.invalidate();
}

/// Publishes one coalesced normal-buffer frame. Facts mutate only the store
/// and streaming state; this is the sole live frame write path.
pub fn commit(self: *Screen, view: FrameView) !void {
    var attempt = (try self.invalidations.beginAttempt()) orelse return;
    defer attempt.deinit();

    // Per-frame painting allocations are request-scoped and freed in bulk.
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var frame = try self.buildFrame(arena.allocator(), view);
    defer frame.deinit();
    _ = try self.terminal_renderer.commit(
        self.output,
        &frame.surface,
        if (frame.document) |*document| document else null,
        frame.plan,
    );
    if (frame.open_entry_materialized) self.transcript_runtime.markOpenEntryMaterialized();
    attempt.commit();
}

pub fn finish(self: *Screen, view: FrameView) !void {
    if (self.transcript_runtime.openEntryId() != null) {
        try self.transcript_runtime.finishOpenEntry();
        self.invalidations.invalidate();
    }
    if (self.terminal_renderer.isPublicationIndeterminate()) return;
    try self.commit(view);
    try self.terminal_renderer.finish(self.output);
}

// Frame coordination ---------------------------------------------------------

const BuiltFrame = render.FrameBuilder.BuiltFrame;

fn buildFrame(self: *Screen, arena: std.mem.Allocator, view: FrameView) !BuiltFrame {
    const terminal_size = self.size orelse return error.ScreenNotPrepared;
    return render.FrameBuilder.build(
        arena,
        &self.transcript_runtime.store,
        self.transcript_runtime.openEntryId(),
        .{ .rows = terminal_size.rows, .columns = terminal_size.columns },
        .{
            .composer = view.composer,
            .phase = view.phase,
            .queued_count = view.queued_count,
            .active_tool = self.transcript_runtime.activeToolLabel(),
            .active_model = view.active_model,
            .thinking_level = view.thinking_level,
            .cwd = view.cwd,
            .slash_menu = view.slash_menu,
        },
        &self.terminal_renderer,
    );
}

fn applyEventFact(self: *Screen, event: interactive.Event) !void {
    try self.apply(.{ .turn = .{ .event = event } });
}

fn beginTestScreen(screen: *Screen) !void {
    try screen.begin(.{ .rows = 24, .columns = 80 }, 1);
}

test "screen rejects publication before inline admission" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    screen.editorChanged();

    try std.testing.expectError(error.ScreenNotPrepared, screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    }));
    try std.testing.expect(screen.invalidations.hasPending());
}

test "screen stages facts and publishes one fx-style footer frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);

    try screen.applyEventFact(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } });
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try screen.commit(.{
        .composer = .{ .text = "next", .cursor_byte = 4 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 2,
        .active_model = .{ .provider = "openai", .model = "gpt-test" },
        .cwd = "/work/zi",
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "hello") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "working · esc cancel") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "2 queued") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "openai/gpt-test") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "/work/zi") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "next") != null);
}

test "screen paints compact absolute bands from the launch row" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 12, .columns = 30 }, 6);
    try screen.notice("hello");

    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    const layout = screen.terminal_renderer.committed_layout.?;
    const expected_transcript: FramePlan.Band = .{ .top = 6, .bottom = 7 };
    const expected_footer: FramePlan.Band = .{ .top = 8, .bottom = 9 };
    try std.testing.expectEqual(expected_transcript, layout.transcript_band);
    try std.testing.expectEqual(expected_footer, layout.footer_band);
    for (1..6) |row| {
        for (screen.terminal_renderer.shadow.?.rowCells(@intCast(row)).?) |cell| {
            try std.testing.expect(cell.isBlank());
        }
    }
    var row: u16 = 1;
    while (row < 6) : (row += 1) {
        var sequence: [32]u8 = undefined;
        const cup = try std.fmt.bufPrint(&sequence, "\x1b[{d};1H", .{row});
        try std.testing.expect(std.mem.find(u8, output.written(), cup) == null);
    }
}

test "screen materializes an oversized restored transcript on its first frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 5, .columns = 40 }, 1);

    var restored: interactive.SessionTranscript = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .items = &.{.{
            .metadata = .recovered_open_turn,
            .content = .{ .assistant = .{
                .parts = &.{.{ .text = .{ .text =
                \\**alpha界**
                \\beta
                \\gamma
                \\delta
                \\epsilon
                \\zeta
                } }},
                .identity = .{ .provider = "test", .model = "model" },
            } },
        }},
    };
    defer restored.deinit();
    try screen.start(&restored);
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    const bytes = output.written();
    inline for (.{ "alpha", "界", "beta", "gamma", "delta", "epsilon", "zeta" }) |text| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, text));
    }
    try std.testing.expect(screen.terminal_renderer.committed_layout.?.materialized_transcript_rows != 0);
    try std.testing.expect(screen.transcript_runtime.store.entryAt(0).?.isSealed());
    try std.testing.expect(screen.transcript_runtime.store.entryAt(1).?.isSealed());
    try std.testing.expect(std.mem.find(u8, bytes, "**") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[3J") == null);
}

test "screen builds typed document rows with gaps Unicode and boundary SGR" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 4, .columns = 20 }, 1);
    _ = try screen.transcript_runtime.store.appendSealed(.assistant_turn, "\x1b[1mbold界\x1b[22m\nsecond\n");
    _ = try screen.transcript_runtime.store.appendSealed(.system_notice, "later\nlast\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var frame = try screen.buildFrame(arena.allocator(), .{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    defer frame.deinit();
    try std.testing.expectEqual(@as(u16, 4), frame.plan.document_rows);
    const document = &frame.document.?;
    try std.testing.expect(document.rowCells(1).?[0].style.attributes.bold);
    try std.testing.expectEqualStrings("b", document.graphemeBytes(document.rowCells(1).?[0]).?);
    try std.testing.expectEqualStrings("s", document.graphemeBytes(document.rowCells(2).?[0]).?);
    for (document.rowCells(3).?) |cell| try std.testing.expect(cell.isBlank());
    try std.testing.expectEqualStrings("l", document.graphemeBytes(document.rowCells(4).?[0]).?);

    screen.invalidations.invalidate();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    const bytes = output.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "bold界"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "second"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\r\n"));
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[0;1;39;49m") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[3J") == null);
}

test "screen does not repaint materialized transcript prefix after footer shrink" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 6, .columns = 20 }, 1);
    _ = try screen.transcript_runtime.store.appendSealed(.assistant_turn, "one\ntwo\nthree\nfour\n");

    screen.invalidations.invalidate();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijklmnopqrstuvwxyz", .cursor_byte = 26 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(
        @as(u32, 2),
        screen.terminal_renderer.committed_layout.?.materialized_transcript_rows,
    );
    const before_shrink = std.mem.count(u8, output.written(), "one");

    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(before_shrink, std.mem.count(u8, output.written(), "one"));
    try std.testing.expectEqual(
        @as(u32, 2),
        screen.terminal_renderer.committed_layout.?.materialized_transcript_rows,
    );
}

test "screen streams markdown progressively without repainting sealed rows" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);

    try screen.applyEventFact(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .response = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_start = .{ .index = 0, .part = .text } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_delta = .{ .index = 0, .delta = .{ .text = "**hello**\n" } } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    // A second delta repaints only the growing row; the sealed prefix above
    // it is diffed away, not rewritten.
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_delta = .{ .index = 0, .delta = .{ .text = "**world**\n" } } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    const frame = output.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "hello"));
    try std.testing.expect(std.mem.find(u8, frame, "world") == null);

    // Sealing keeps the full styled text exactly once.
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{.{ .text = "**hello**\n**world**" }},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_end = .{
            .index = 0,
            .part = .{ .text = .{ .text = "**hello**\n**world**" } },
        } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "world"));

    // A fresh empty frame renders no transcript content again.
    const before = output.written().len;
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(before, output.written().len);
}

test "screen renders Markdown thinking and prose once in response order" {
    const parts = [_]ai.message.ResponsePart{
        .{ .thinking = .{ .text = "**inspect** state" } },
        .{ .text = .{ .text = "Use `ready`." } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);

    try screen.applyEventFact(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .response = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{.{ .thinking = "**inspect** state" }},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_end = .{ .index = 0, .part = parts[0] } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{
                .{ .thinking = "**inspect** state" },
                .{ .text = "Use `ready`." },
            },
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_end = .{ .index = 1, .part = parts[1] } },
    } });
    try screen.applyEventFact(.{ .message_end = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .published = .{ .response = .{
            .parts = &parts,
            .identity = .{ .provider = "test", .model = "model" },
        } } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    const rendered = output.written();
    const thinking = std.mem.find(u8, rendered, "Thinking").?;
    const inspect = std.mem.find(u8, rendered, "inspect").?;
    const answer = std.mem.find(u8, rendered, "Use ").?;
    try std.testing.expect(thinking < inspect);
    try std.testing.expect(inspect < answer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "inspect"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "ready"));
    try std.testing.expect(std.mem.find(u8, rendered, "**") == null);
}

test "screen keeps running tool details in footer and appends one compact result" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);

    try screen.applyEventFact(.{ .tool_execution_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .call_id = "call-1",
        .name = "read",
        .arguments_json = "{\"path\":\"secret\"}",
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "Reading secret · esc cancel") != null);

    try screen.applyEventFact(.{ .tool_execution_end = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .call_id = "call-1",
        .name = "read",
        .result = .{ .published = .{
            .call_id = "call-1",
            .name = "read",
            .content = &.{.{ .text = "private file contents" }},
            .outcome = .success,
        } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "● Read secret") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "private file contents") == null);
}

test "screen drops an abandoned streaming entry on abnormal turn end" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);

    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_delta = .{
            .index = 0,
            .delta = .{ .text = "half written\nsettles it\n" },
        } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "half written") != null);

    try screen.applyEventFact(.{ .agent_end = .{
        .run_id = @enumFromInt(1),
        .outcome = .cancelled,
        .messages = &.{},
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    const frame = output.written();
    const cancelled = std.mem.find(u8, frame, "[turn cancelled]").?;
    try std.testing.expect(cancelled > std.mem.find(u8, frame, "half written").?);
    // The dropped source no longer paints after the reset frame.
    const reset = std.mem.count(u8, frame[cancelled..], "half written");
    try std.testing.expectEqual(@as(usize, 0), reset);

    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written()[cancelled..], "half") == null);
}

test "screen makes an open entry irreversible on its first materializing commit" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 4, .columns = 20 }, 1);

    const id = try screen.transcript_runtime.store.openEntry(.assistant_turn, "one\ntwo\nthree\n");
    screen.transcript_runtime.open_entry = id;
    screen.invalidations.invalidate();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try std.testing.expect(screen.transcript_runtime.open_entry_irreversible);
    try screen.applyEventFact(.{ .agent_end = .{
        .run_id = @enumFromInt(1),
        .outcome = .cancelled,
        .messages = &.{},
    } });
    try std.testing.expect(screen.transcript_runtime.open_entry == null);
    try std.testing.expect(screen.transcript_runtime.store.entryAt(0).?.isSealed());
    try std.testing.expectEqualStrings(
        "one\ntwo\nthree\n",
        screen.transcript_runtime.store.entryAt(0).?.textBytes().?,
    );
}

test "screen finish flushes and seals an open Markdown tail before publication" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 6, .columns = 30 }, 1);
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_delta = .{
            .index = 0,
            .delta = .{ .text = "buffered **tail**" },
        } },
    } });

    try screen.finish(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try std.testing.expect(screen.transcript_runtime.open_entry == null);
    try std.testing.expect(screen.transcript_runtime.store.entryAt(0).?.isSealed());
    try std.testing.expect(std.mem.find(u8, output.written(), "buffered ") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "tail") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "**") == null);
}

test "screen settles a partial assistant after native scrolling makes it final" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 4, .columns = 20 }, 1);

    const id = try screen.transcript_runtime.store.openEntry(.assistant_turn, "one\ntwo\n");
    screen.transcript_runtime.open_entry = id;
    screen.invalidations.invalidate();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try screen.transcript_runtime.store.appendTo(id, "three\n");
    screen.invalidations.invalidate();
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expect(screen.transcript_runtime.open_entry_irreversible);

    try screen.applyEventFact(.{ .agent_end = .{
        .run_id = @enumFromInt(1),
        .outcome = .cancelled,
        .messages = &.{},
    } });
    try std.testing.expect(screen.transcript_runtime.open_entry == null);
    try std.testing.expectEqual(@as(usize, 2), screen.transcript_runtime.store.entryCount());
    try std.testing.expect(screen.transcript_runtime.store.entryAt(0).?.isSealed());
    try std.testing.expectEqualStrings(
        "one\ntwo\nthree\n",
        screen.transcript_runtime.store.entryAt(0).?.textBytes().?,
    );
}

test "screen masks OAuth answer composer bytes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 10, .columns = 40 }, 3);
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = "oauth-secret", .cursor_byte = 12, .masked = true },
        .phase = .authenticating,
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "oauth-secret") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "************") != null);
}

test "screen reflows the composer across terminal resize" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.begin(.{ .rows = 12, .columns = 6 }, 4);
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(u16, 12), screen.terminal_renderer.shadow.?.rows);
    try std.testing.expectEqual(@as(u16, 6), screen.terminal_renderer.shadow.?.columns);

    try screen.resized(.{ .rows = 12, .columns = 10 });
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(u16, 10), screen.terminal_renderer.shadow.?.columns);
}

test "screen paints one ZWJ grapheme and places the composer cursor by cells" {
    const family = "👨‍👩‍👧‍👦";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 8, .columns = 8 }, 2);
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = family, .cursor_byte = family.len },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try std.testing.expect(std.mem.find(u8, output.written(), family) != null);
    const shadow = &screen.terminal_renderer.shadow.?;
    // The composer cursor sits past the two-cell family grapheme plus prompt.
    try std.testing.expect(shadow.cursor.column >= 5);
    const cursor_cells = shadow.rowCells(shadow.cursor.row).?;
    var wide_found = false;
    for (cursor_cells) |cell| {
        if (cell.width == 2 and !cell.isContinuation()) wide_found = true;
    }
    try std.testing.expect(wide_found);
}

test "screen rejects oversized transcript stores transactionally" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(
        std.testing.allocator,
        &output.writer,
        .{ .max_store_bytes = 8 },
    );
    defer screen.deinit();

    try std.testing.expectError(error.StoreFull, screen.notice("longer than eight"));
    try std.testing.expectEqual(@as(usize, 0), screen.transcript_runtime.store.entryCount());
    try std.testing.expect(!screen.invalidations.hasPending());
}

test "screen restores an uncommitted frame request after output failure" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var failing: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var screen = try Screen.init(std.testing.allocator, &failing, .{});
    defer screen.deinit();
    try beginTestScreen(&screen);
    screen.editorChanged();
    try std.testing.expectError(error.WriteFailed, screen.commit(.{
        .composer = .{ .text = "draft", .cursor_byte = 5 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    }));
    try std.testing.expect(screen.invalidations.hasPending());
    try std.testing.expect(screen.terminal_renderer.shadow == null);
}
