const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const interactive = @import("../coding_agent/root.zig").interactive;
const RenderRequest = @import("RenderRequest.zig");
const SafeText = @import("SafeText.zig");
const transcript = @import("transcript/root.zig");
const markdown = @import("markdown/root.zig");
const terminal_render = @import("../terminal_render/root.zig");
const render = @import("render/root.zig");
const TerminalSession = @import("terminal/Session.zig");

const Store = transcript.Store;
const Kind = transcript.Kind;
const Style = terminal_render.Surface.Style;

const Screen = @This();

pub const default_max_store_bytes = transcript.default_max_store_bytes;

pub const InitOptions = struct {
    max_store_bytes: usize = default_max_store_bytes,
};

pub const ComposerView = struct {
    text: []const u8,
    cursor_byte: usize,
    masked: bool = false,
};

pub const FrameView = struct {
    composer: ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
};

/// Minimum transcript rows reserved above the footer bands before composer
/// wrapping starts stealing viewport space from tiny terminals.
const min_transcript_rows: u16 = 3;

const StreamKind = enum { assistant, thinking };

const ActiveTool = struct {
    call_hash: u64,
    kind: ToolKind,
};

const ToolKind = enum {
    read,
    write,
    edit,
    bash,
    other,

    fn fromName(name: []const u8) ToolKind {
        inline for (.{ .read, .write, .edit, .bash }) |kind| {
            if (std.mem.eql(u8, name, @tagName(kind))) return kind;
        }
        return .other;
    }

    fn label(self: ToolKind) []const u8 {
        return if (self == .other) "tool" else @tagName(self);
    }
};

allocator: std.mem.Allocator,
output: *std.Io.Writer,
store: Store,
requests: RenderRequest.State = .{},
terminal_renderer: render.TerminalRenderer,
size: ?TerminalSession.Size = null,

/// Reusable presentation-byte scratch for one-entry facts.
scratch: std.Io.Writer.Allocating,

// Streaming state: part deltas flow through the incremental markdown
// processor, whose emitted presentation bytes accumulate in the open
// entry's source until the part seals.
processor: markdown.Processor,
markdown_out: std.ArrayList(u8) = .empty,
open_entry: ?u32 = null,
open_kind: StreamKind = .assistant,
open_part_index: usize = 0,
open_entry_irreversible: bool = false,
response_next_index: usize = 0,
active_tool: ?ActiveTool = null,

pub fn init(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    options: InitOptions,
) !Screen {
    if (options.max_store_bytes == 0) return error.InvalidStoreByteLimit;
    return .{
        .allocator = allocator,
        .store = Store.init(allocator, options.max_store_bytes),
        .output = output,
        .terminal_renderer = .init(allocator),
        .scratch = .init(allocator),
        .processor = .{},
    };
}

pub fn deinit(self: *Screen) void {
    self.terminal_renderer.deinit();
    self.processor.deinit(self.allocator);
    self.markdown_out.deinit(self.allocator);
    self.scratch.deinit();
    self.store.deinit();
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
    _ = try self.sealedEntry(.welcome,
        \\Zi
        \\  Enter submits. Enter while busy queues the next prompt.
        \\  /login PROVIDER [--device] logs in. /model PROVIDER/MODEL switches while idle.
        \\  Escape cancels. Ctrl-D exits when idle.
        \\
        \\
    );
    if (restored) |value| try self.restoreTranscript(value);
    self.requests.request(.first_frame);
}

fn restoreTranscript(self: *Screen, value: *const interactive.SessionTranscript) !void {
    for (value.items) |item| switch (item.content) {
        .model_change => |identity| try self.addModel(identity),
        .user => |user| try self.addUser(user.parts),
        .assistant => |response| for (response.parts) |part|
            try self.renderPartSource(part),
        .tool_results => |results| for (results.results) |result|
            try self.addToolResult(result),
        .failure => |failure| {
            var label_buffer: [128]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &label_buffer,
                "turn failed: {s}",
                .{@tagName(failure.category)},
            );
            try self.addNotice(label);
        },
        .cancelled => try self.addNotice("turn cancelled"),
        .interrupted => try self.addNotice("turn interrupted"),
    };
}

pub fn apply(self: *Screen, fact: interactive.HostFact) !void {
    switch (fact) {
        .turn => |turn| try self.applyTurnFact(turn),
        .auth_started => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logging in to {s}", .{value.provider});
            try self.addNotice(label);
        },
        .auth_interaction => |interaction| switch (interaction) {
            .auth_url => |value| {
                try self.addNotice(value.instructions);
                try self.addNotice(value.url);
            },
            .device_code => |value| {
                try self.addNotice(value.verification_uri);
                var buffer: [1024]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, "Device code: {s}", .{value.user_code});
                try self.addNotice(label);
            },
            .prompt => |value| try self.addNotice(value.message),
        },
        .auth_cancelled => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Login cancelled for {s}", .{value.provider});
            try self.addNotice(label);
        },
        .login_succeeded => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logged in to {s}", .{value.provider});
            try self.addNotice(label);
        },
        .login_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Login failed for {s}: {s}",
                .{ value.provider, @tagName(value.failure) },
            );
            try self.addNotice(label);
        },
        .model_changed => |selection| try self.addModel(selection),
        .model_less => try self.addNotice("No model is available"),
        .model_switch_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} failed: {s}",
                .{ value.requested.provider, value.requested.model, value.reason },
            );
            try self.addNotice(label);
        },
        .model_switch_commit_indeterminate => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} had an indeterminate journal commit",
                .{ value.provider, value.model },
            );
            try self.addNotice(label);
        },
        .settings_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model changed, but saving the default failed: {s}",
                .{value.reason},
            );
            try self.addNotice(label);
        },
        .settings_commit_indeterminate => try self.addNotice(
            "Model changed, but saving the default was indeterminate",
        ),
        .session_unavailable => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Session unavailable: {s}", .{value.reason});
            try self.addNotice(label);
        },
    }
    self.requests.request(.transcript);
}

fn applyEventFact(self: *Screen, event: interactive.Event) !void {
    try self.apply(.{ .turn = .{ .event = event } });
}

fn applyTurnFact(self: *Screen, fact: interactive.TurnFact) !void {
    switch (fact) {
        .event => |event| try self.applyEvent(event),
        .completion => |completion| {
            if (!completion.agent_end_observed) switch (completion.value.outcome) {
                .completed => {},
                .failed => |failure| try self.addNotice(@errorName(failure)),
            };
        },
        .fault => |fault| switch (fault) {
            .follow_up_submission => |failure| try self.addNotice(@errorName(failure)),
            .draft_restore => |failure| try self.addNotice(@errorName(failure)),
        },
    }
}

fn applyEvent(self: *Screen, event: interactive.Event) !void {
    switch (event) {
        .agent_start, .turn_start, .turn_end => {},
        .message_start => |started| switch (started.message) {
            .request => |request| for (request.parts) |part| switch (part) {
                .user => |user| try self.addUser(&.{user}),
                .tool_result, .retry_prompt => {},
            },
            .response => self.response_next_index = 0,
        },
        .message_update => |update| switch (update.update) {
            .part_start => |started| self.streamPartStart(started),
            .part_delta => |delta| try self.streamPartDelta(delta),
            .part_end => |ended| try self.sealStreamedPart(ended.index, ended.part),
            .usage => {},
        },
        .message_end => |ended| switch (ended.message) {
            .published => |message| switch (message) {
                .request => {},
                .response => |response| try self.finishResponse(response.parts),
            },
            .discarded_response => |discarded| {
                try self.discardOpenEntry();
                for (discarded.response.parts[self.response_next_index..]) |part|
                    try self.renderSnapshotPart(part);
                self.response_next_index = 0;
                var label_buffer: [128]u8 = undefined;
                const label = try std.fmt.bufPrint(
                    &label_buffer,
                    "response discarded: {s}",
                    .{@tagName(discarded.outcome)},
                );
                try self.addNotice(label);
            },
        },
        .tool_execution_start => |started| try self.startTool(started.call_id, started.name),
        .tool_execution_end => |ended| try self.finishTool(ended.call_id, ended.name, ended.result),
        .agent_end => |ended| switch (ended.outcome) {
            .completed => {},
            .cancelled, .interrupted, .failed => {
                try self.discardOpenEntry();
                var label_buffer: [128]u8 = undefined;
                const label = switch (ended.outcome) {
                    .cancelled => "turn cancelled",
                    .interrupted => "turn interrupted",
                    .failed => |failure| try std.fmt.bufPrint(
                        &label_buffer,
                        "turn failed: {s}",
                        .{@tagName(failure)},
                    ),
                    .completed => unreachable,
                };
                try self.addNotice(label);
            },
        },
        .agent_settled => |settled| if (settled.availability == .poisoned) {
            try self.addNotice("session unavailable, reopen the durable session");
        },
    }
}

// Streaming facts ------------------------------------------------------------

fn streamPartStart(self: *Screen, started: ai.stream.PartStart) void {
    self.open_part_index = started.index;
    switch (started.part) {
        .text => self.open_kind = .assistant,
        .thinking => self.open_kind = .thinking,
        .tool_call => {},
    }
}

fn streamPartDelta(self: *Screen, delta: ai.stream.PartDelta) !void {
    self.open_part_index = delta.index;
    switch (delta.delta) {
        .text => |text| try self.streamMarkdownBytes(text),
        .thinking => |thinking| try self.streamMarkdownBytes(thinking),
        .tool_call => {},
    }
}

fn streamMarkdownBytes(self: *Screen, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (self.open_entry == null) {
        const seed = if (self.open_kind == .thinking)
            "\x1b[2mThinking\x1b[22m\n"
        else
            "";
        self.open_entry = try self.store.appendEntry(
            switch (self.open_kind) {
                .assistant => .assistant,
                .thinking => .thinking,
            },
            seed,
        );
        self.open_entry_irreversible = false;
    }
    // Only settled processor output enters the transcript source. Sanitation
    // happens before Markdown interpretation so provider controls can never be
    // mistaken for trusted presentation SGR or OSC runs.
    self.markdown_out.clearRetainingCapacity();
    try self.pushSafeMarkdown(&self.processor, bytes, &self.markdown_out);
    if (self.markdown_out.items.len != 0) {
        try self.store.appendTo(self.open_entry.?, self.markdown_out.items);
    }
}

fn sealStreamedPart(self: *Screen, index: usize, part: ai.message.ResponsePart) !void {
    self.response_next_index = index + 1;
    if (self.open_entry != null) return self.sealOpenEntry();
    try self.renderPartSource(part);
}

fn finishResponse(self: *Screen, parts: []const ai.message.ResponsePart) !void {
    if (self.open_entry != null) try self.sealOpenEntry();
    // Parts the stream never delivered are rendered whole, once.
    for (parts[self.response_next_index..]) |part| try self.renderPartSource(part);
    self.response_next_index = 0;
}

/// Finalizes an open entry whose already-painted rows may have entered native
/// scrollback. Released terminal history is immutable, so cancellation must
/// retain the matching transcript source instead of trying to erase it.
fn sealOpenEntry(self: *Screen) !void {
    const id = self.open_entry orelse return;
    defer self.resetOpenEntry();
    self.markdown_out.clearRetainingCapacity();
    try self.processor.flush(self.allocator, &self.markdown_out);
    if (self.markdown_out.items.len != 0) {
        try self.store.appendTo(id, self.markdown_out.items);
    }
    try self.store.sealEntry(id);
    self.response_next_index = @max(self.response_next_index, self.open_part_index +| 1);
}

/// Drops a replaceable tail only while every painted row remains inside Zi's
/// current owned band. Once a commit scrolls a prior copy, finality wins.
fn discardOpenEntry(self: *Screen) !void {
    const id = self.open_entry orelse return;
    if (self.open_entry_irreversible) return self.sealOpenEntry();
    self.resetOpenEntry();
    self.store.dropEntriesFrom(id) catch |failure| switch (failure) {
        error.EntryNotFound => {},
        else => return failure,
    };
}

fn resetOpenEntry(self: *Screen) void {
    self.open_entry = null;
    self.open_entry_irreversible = false;
    self.processor.reset(self.allocator);
}

// Entry helpers --------------------------------------------------------------

/// Renders one complete response part into its own sealed entry. This is the
/// fallback for parts the stream never delta-fed and for restored transcripts.
fn renderPartSource(self: *Screen, part: ai.message.ResponsePart) !void {
    switch (part) {
        .text => |text| try self.addMarkdownEntry(.assistant, text.text),
        .thinking => |thinking| try self.addMarkdownEntry(.thinking, thinking.text),
        .tool_call => {},
    }
}

fn renderSnapshotPart(self: *Screen, part: ai.stream.ResponsePartSnapshot) !void {
    switch (part) {
        .text => |text| try self.addMarkdownEntry(.assistant, text),
        .thinking => |thinking| try self.addMarkdownEntry(.thinking, thinking),
        .tool_call => {},
    }
}

fn addMarkdownEntry(self: *Screen, kind: Kind, markdown_source: []const u8) !void {
    if (std.mem.trim(u8, markdown_source, " \t\r\n").len == 0) return;

    var processor: markdown.Processor = .{};
    defer processor.deinit(self.allocator);
    self.markdown_out.clearRetainingCapacity();
    try self.pushSafeMarkdown(&processor, markdown_source, &self.markdown_out);
    try processor.flush(self.allocator, &self.markdown_out);
    if (self.markdown_out.items.len > self.remainingStoreBytes()) return error.StoreFull;

    self.scratch.clearRetainingCapacity();
    if (kind == .thinking) {
        var encoder = terminal_render.Ansi.Encoder.init(&self.scratch.writer);
        try encoder.setStyle(.{ .attributes = .{ .dim = true } });
        try self.scratch.writer.writeAll("Thinking");
        try encoder.setStyle(.{});
        try self.scratch.writer.writeByte('\n');
    }
    try self.scratch.writer.writeAll(self.markdown_out.items);
    try self.scratch.writer.writeByte('\n');
    _ = try self.sealedEntry(kind, self.scratch.written());
}

fn pushSafeMarkdown(
    self: *Screen,
    processor: *markdown.Processor,
    source: []const u8,
    out: *std.ArrayList(u8),
) !void {
    self.scratch.clearRetainingCapacity();
    try SafeText.write(&self.scratch.writer, source, true);
    try processor.push(self.allocator, self.scratch.written(), out);
}

fn addUser(self: *Screen, parts: []const ai.message.UserContent) !void {
    self.scratch.clearRetainingCapacity();
    for (parts, 0..) |part, index| {
        if (index != 0) try self.scratch.writer.writeByte(' ');
        switch (part) {
            .text => |text| try SafeText.write(&self.scratch.writer, text, true),
            .image => |image| {
                try self.scratch.writer.writeAll("[image ");
                try SafeText.write(&self.scratch.writer, image.media_type, false);
                try self.scratch.writer.writeByte(']');
            },
        }
    }
    // One rail-prefixed source line per content line; the painter wraps
    // overhang without a rail.
    var source: std.Io.Writer.Allocating = .init(self.allocator);
    defer source.deinit();
    var encoder = terminal_render.Ansi.Encoder.init(&source.writer);
    var rest = self.scratch.written();
    while (rest.len != 0) {
        const end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trimEnd(u8, rest[0..end], "\r");
        try encoder.setStyle(.{ .attributes = .{ .bold = true } });
        try source.writer.writeAll("\xe2\x94\x83 ");
        try source.writer.writeAll(line);
        try encoder.setStyle(.{});
        try source.writer.writeByte('\n');
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
    }
    _ = try self.sealedEntry(.user, source.written());
}

fn addModel(self: *Screen, identity: ai.message.ModelIdentity) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.writer.writeAll("[model ");
    try SafeText.write(&self.scratch.writer, identity.provider, false);
    try self.scratch.writer.writeByte('/');
    try SafeText.write(&self.scratch.writer, identity.model, false);
    try self.scratch.writer.writeAll("]\n");
    _ = try self.sealedEntry(.model, self.scratch.written());
}

fn addToolResult(self: *Screen, result: ai.message.ToolResult) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.writer.writeAll("\xe2\x80\xa2 ");
    try SafeText.write(&self.scratch.writer, result.name, false);
    if (result.outcome == .failure) try self.scratch.writer.writeAll(" failed");
    try self.scratch.writer.writeByte('\n');
    _ = try self.sealedEntry(.tool, self.scratch.written());
}

fn startTool(self: *Screen, call_id: []const u8, name: []const u8) !void {
    if (self.active_tool != null) return error.ToolAlreadyRunning;
    self.active_tool = .{
        .call_hash = std.hash.Wyhash.hash(0, call_id),
        .kind = ToolKind.fromName(name),
    };
}

fn finishTool(
    self: *Screen,
    call_id: []const u8,
    name: []const u8,
    result: agent.event.ToolExecutionResult,
) !void {
    const active = self.active_tool orelse return error.ToolNotRunning;
    if (active.call_hash != std.hash.Wyhash.hash(0, call_id)) return error.ToolLifecycleMismatch;
    self.active_tool = null;
    switch (result) {
        .published => |published| try self.addToolResult(published),
        .discarded => |outcome| {
            self.scratch.clearRetainingCapacity();
            try self.scratch.writer.writeAll("\xe2\x80\xa2 ");
            try SafeText.write(&self.scratch.writer, name, false);
            try self.scratch.writer.print(" discarded: {s}\n", .{@tagName(outcome)});
            _ = try self.sealedEntry(.tool, self.scratch.written());
        },
    }
}

pub fn activeToolLabel(self: *const Screen) ?[]const u8 {
    const active = self.active_tool orelse return null;
    return active.kind.label();
}

fn addNotice(self: *Screen, label: []const u8) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.writer.writeByte('[');
    try SafeText.write(&self.scratch.writer, label, false);
    try self.scratch.writer.writeAll("]\n");
    _ = try self.sealedEntry(.notice, self.scratch.written());
}

fn sealedEntry(self: *Screen, kind: Kind, bytes: []const u8) !u32 {
    const id = try self.store.appendEntry(kind, bytes);
    try self.store.sealEntry(id);
    return id;
}

fn remainingStoreBytes(self: *const Screen) usize {
    return self.store.max_store_bytes -| self.store.total_bytes;
}

pub fn notice(self: *Screen, text: []const u8) !void {
    try self.addNotice(text);
    self.requests.request(.notice);
}

pub fn editorChanged(self: *Screen) void {
    self.requests.request(.footer);
}

pub fn resized(self: *Screen, size: TerminalSession.Size) !void {
    if (self.size == null) return error.ScreenNotPrepared;
    if (size.rows == 0 or size.columns == 0) return error.InvalidTerminalSize;
    if (std.meta.eql(self.size.?, size)) return;
    self.size = size;
    self.requests.request(.resize);
}

/// Publishes one coalesced normal-buffer frame. Facts mutate only the store
/// and streaming state; this is the sole live frame write path.
pub fn commit(self: *Screen, view: FrameView) !void {
    var attempt = (try self.requests.beginAttempt()) orelse return;
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
    if (frame.open_entry_materialized) self.open_entry_irreversible = true;
    attempt.commit();
}

pub fn finish(self: *Screen, view: FrameView) !void {
    if (self.open_entry != null) {
        try self.sealOpenEntry();
        self.requests.request(.transcript);
    }
    if (self.terminal_renderer.isPublicationIndeterminate()) return;
    try self.commit(view);
    try self.terminal_renderer.finish(self.output);
}

// Painting -------------------------------------------------------------------

/// One wrapped display row of the transcript band: a byte range inside a
/// specific entry's source plus the SGR style state at the row boundary so
/// styles reassert cleanly across wraps and never leak between rows.
const RowRef = struct {
    entry_index: ?usize,
    start_byte: usize,
    end_byte: usize,
    style: Style,
};

const BuiltFrame = struct {
    surface: terminal_render.Surface,
    document: ?terminal_render.Surface,
    plan: render.FramePlan.FramePlan,
    open_entry_materialized: bool,

    fn deinit(self: *BuiltFrame) void {
        if (self.document) |*document| document.deinit();
        self.surface.deinit();
        self.* = undefined;
    }
};

fn buildFrame(self: *Screen, arena: std.mem.Allocator, view: FrameView) !BuiltFrame {
    const terminal_size = self.size orelse return error.ScreenNotPrepared;
    const prompt = "\u{276f} ";

    const budget = @min(
        @max(terminal_size.rows -| min_transcript_rows, @as(u16, 2)),
        terminal_size.rows,
    );
    const masked_text = if (view.composer.masked)
        try arena.alloc(u8, view.composer.text.len)
    else
        null;
    if (masked_text) |text| @memset(text, '*');
    const composer_text = masked_text orelse view.composer.text;
    var layout = try render.FooterLayout.init(
        arena,
        budget,
        terminal_size.columns,
        composer_text,
        view.composer.cursor_byte,
        @intCast(terminal_render.Text.displayWidth(prompt)),
    );

    const footer_rows: u16 =
        (if (layout.status != null) @as(u16, 1) else 0) + layout.composer.row_count;

    var rows: std.ArrayList(RowRef) = .empty;
    try self.wrapTranscriptRows(arena, terminal_size.columns, &rows);
    const measured_transcript_rows = std.math.cast(u32, rows.items.len) orelse
        return error.TranscriptRowCountOverflow;
    const frame_plan = try self.terminal_renderer.plan(
        .{ .rows = terminal_size.rows, .columns = terminal_size.columns },
        measured_transcript_rows,
        footer_rows,
    );
    const visible_transcript_rows = frame_plan.visible_transcript_rows;
    const materialized_transcript_rows = std.math.cast(
        usize,
        frame_plan.materialized_transcript_rows,
    ) orelse return error.TranscriptRowCountOverflow;
    if (materialized_transcript_rows > rows.items.len or
        rows.items.len - materialized_transcript_rows != @as(usize, visible_transcript_rows))
    {
        return error.InvalidFramePlan;
    }
    const document_rows: usize = frame_plan.document_rows;
    if (document_rows > materialized_transcript_rows) return error.InvalidFramePlan;

    var document: ?terminal_render.Surface = null;
    var open_entry_materialized = false;
    errdefer if (document) |*value| value.deinit();
    if (frame_plan.document_rows != 0) {
        document = try terminal_render.Surface.init(
            arena,
            frame_plan.document_rows,
            terminal_size.columns,
        );
        const first_document = materialized_transcript_rows - document_rows;
        for (rows.items[first_document..materialized_transcript_rows], 1..) |row, document_row| {
            try self.paintRowRef(&document.?, @intCast(document_row), row);
            if (self.open_entry) |open_id| {
                if (row.entry_index) |entry_index| {
                    const entry = self.store.entryAt(entry_index) orelse
                        return error.TranscriptEntryMissing;
                    open_entry_materialized = open_entry_materialized or entry.id == open_id;
                } else {
                    // Separator rows cannot be attributed exactly. Once one is
                    // published ahead of an open tail, retain that tail.
                    open_entry_materialized = true;
                }
            }
        }
    }

    var surface = try terminal_render.Surface.init(
        arena,
        terminal_size.rows,
        terminal_size.columns,
    );
    errdefer surface.deinit();
    for (rows.items[materialized_transcript_rows..], 0..) |row, index| {
        const surface_row = frame_plan.transcript_band.top + @as(u16, @intCast(index));
        try self.paintRowRef(&surface, surface_row, row);
    }

    const footer_offset = frame_plan.footer_band.top - 1;
    if (layout.status) |status| {
        const status_row: u16 = status.first_row + footer_offset;
        var status_buffer: [128]u8 = undefined;
        const label = switch (view.phase) {
            .model_less => "No model selected",
            .authenticating => "Authenticating",
            .transitioning => "Changing session backend",
            .unavailable => "Session unavailable",
            .turn => |turn_phase| switch (turn_phase) {
                .idle => "Ready",
                .awaiting_start => "Working",
                .running => if (self.activeToolLabel()) |tool_name|
                    try std.fmt.bufPrint(&status_buffer, "Working \xc2\xb7 {s}", .{tool_name})
                else
                    "Working",
                .cancel_pending, .cancelling => "Cancelling",
                .dispatching_follow_up => "Starting queued prompt",
                .poisoned => "Session unavailable",
            },
        };
        _ = try surface.writeText(status_row, 1, label, .{
            .attributes = .{ .dim = true },
        });
        if (view.queued_count != 0) {
            var queue_buffer: [64]u8 = undefined;
            const queue_text = try std.fmt.bufPrint(
                &queue_buffer,
                " \xc2\xb7 {d} queued",
                .{view.queued_count},
            );
            const status_column = @min(
                terminal_render.Text.displayWidth(label) + 1,
                @as(usize, terminal_size.columns),
            );
            _ = try surface.writeText(
                status_row,
                @intCast(status_column),
                queue_text,
                .{ .attributes = .{ .dim = true } },
            );
        }
    }

    for (layout.visibleLines(), 0..) |line, visible_index| {
        const row = layout.composer.first_row + footer_offset + @as(u16, @intCast(visible_index));
        if (layout.sourceLineIndex(visible_index) == 0 and line.start_column > 1) {
            _ = try surface.writeText(row, 1, prompt, .{
                .attributes = .{ .bold = true },
            });
        }
        _ = try surface.writeText(
            row,
            line.start_column,
            composer_text[line.start_byte..line.end_byte],
            .{},
        );
    }
    try surface.setCursor(.{
        .row = layout.cursor.row + footer_offset,
        .column = layout.cursor.column,
    });
    return .{
        .surface = surface,
        .document = document,
        .plan = frame_plan,
        .open_entry_materialized = open_entry_materialized,
    };
}

fn paintRowRef(self: *const Screen, surface: *terminal_render.Surface, row: u16, ref: RowRef) !void {
    const entry_index = ref.entry_index orelse return;
    const entry = self.store.entryAt(entry_index) orelse return error.TranscriptEntryMissing;
    try paintSourceRange(
        surface,
        row,
        entry.bytes()[ref.start_byte..ref.end_byte],
        ref.style,
    );
}

/// Wraps every entry source into display rows at the current column count.
fn wrapTranscriptRows(
    self: *Screen,
    arena: std.mem.Allocator,
    columns: u16,
    rows: *std.ArrayList(RowRef),
) !void {
    var previous_kind: ?Kind = null;
    for (self.store.entries.items, 0..) |*entry, index| {
        if (previous_kind) |previous| {
            const gap: usize = switch (previous) {
                .welcome => 0,
                .tool => if (entry.kind == .tool) 0 else 1,
                else => 1,
            };
            for (0..gap) |_| {
                try rows.append(arena, .{
                    .entry_index = null,
                    .start_byte = 0,
                    .end_byte = 0,
                    .style = .{},
                });
            }
        }
        try wrapEntryRows(arena, entry.bytes(), columns, index, rows);
        previous_kind = entry.kind;
    }
}

fn wrapEntryRows(
    arena: std.mem.Allocator,
    source: []const u8,
    columns: u16,
    entry_index: usize,
    rows: *std.ArrayList(RowRef),
) !void {
    var line_start: usize = 0;
    while (line_start < source.len) {
        const newline = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        try wrapLine(arena, source, line_start, newline, columns, entry_index, rows);
        line_start = newline + 1;
    }
}

/// Wraps one logical line (no '\n' inside). Escape runs are zero-width style
/// state; wraps happen only at grapheme boundaries, and each wrapped row
/// records the style active at its start.
fn wrapLine(
    arena: std.mem.Allocator,
    source: []const u8,
    start_byte: usize,
    end_byte: usize,
    columns: u16,
    entry_index: usize,
    rows: *std.ArrayList(RowRef),
) !void {
    const line = source[start_byte..end_byte];
    var style: Style = .{};
    var row_start: usize = start_byte;
    var row_style: Style = style;
    var width: u16 = 0;
    var index: usize = 0;
    while (index < line.len) {
        if (line[index] == 0x1b) {
            const sequence = parseEscape(line[index..]);
            if (sequence.sgr) |params| applySgr(&style, params);
            index += sequence.len;
            continue;
        }
        const next = terminal_render.Text.nextBoundary(line, index);
        const cluster = line[index..next];
        const cluster_width: u16 = if (cluster[0] == '\r')
            0
        else
            @intCast(@min(terminal_render.Text.displayWidth(cluster), std.math.maxInt(u16)));
        if (cluster_width != 0 and width != 0 and width + cluster_width > columns) {
            try rows.append(arena, .{
                .entry_index = entry_index,
                .start_byte = row_start,
                .end_byte = start_byte + index,
                .style = row_style,
            });
            row_start = start_byte + index;
            row_style = style;
            width = 0;
        }
        width +|= cluster_width;
        index = next;
    }
    try rows.append(arena, .{
        .entry_index = entry_index,
        .start_byte = row_start,
        .end_byte = end_byte,
        .style = row_style,
    });
}

fn paintSourceRange(
    surface: *terminal_render.Surface,
    row: u16,
    range: []const u8,
    initial_style: Style,
) !void {
    var style = initial_style;
    var column: u16 = 1;
    var index: usize = 0;
    while (index < range.len) {
        if (range[index] == 0x1b) {
            const sequence = parseEscape(range[index..]);
            if (sequence.sgr) |params| applySgr(&style, params);
            index += sequence.len;
            continue;
        }
        const next = terminal_render.Text.nextBoundary(range, index);
        const cluster = range[index..next];
        if (cluster[0] == '\r') {
            index = next;
            continue;
        }
        if (column > surface.columns) break;
        const result = surface.writeText(row, column, cluster, style) catch |failure| switch (failure) {
            error.OutOfBounds => break,
            else => return failure,
        };
        column = result.next_column;
        if (result.clipped) break;
        index = next;
    }
}

const Escape = struct {
    len: usize,
    sgr: ?[]const u8 = null,
};

/// Recognizes the escape vocabulary our own renderers emit: CSI (with SGR
/// parameter extraction) and OSC. Anything else consumes minimally and is
/// treated as zero-width, never reaching cells as content.
fn parseEscape(sequence: []const u8) Escape {
    if (sequence.len < 2) return .{ .len = sequence.len };
    switch (sequence[1]) {
        '[' => {
            var index: usize = 2;
            while (index < sequence.len and
                !(sequence[index] >= 0x40 and sequence[index] <= 0x7e)) : (index += 1)
            {}
            if (index == sequence.len) return .{ .len = sequence.len };
            const final = sequence[index];
            const inner = sequence[2..index];
            if (final == 'm') return .{ .len = index + 1, .sgr = inner };
            return .{ .len = index + 1 };
        },
        ']' => {
            var index: usize = 2;
            while (index < sequence.len) : (index += 1) {
                if (sequence[index] == 0x07) return .{ .len = index + 1 };
                if (sequence[index] == 0x1b and index + 1 < sequence.len and
                    sequence[index + 1] == '\\')
                {
                    return .{ .len = index + 2 };
                }
            }
            return .{ .len = sequence.len };
        },
        else => return .{ .len = 2 },
    }
}

/// Applies one SGR parameter list to the running style. Mirrors the palette
/// emitted by smol's markdown renderers: bold/dim/italic/underline/strike
/// attributes plus indexed foreground colors.
fn applySgr(style: *Style, params: []const u8) void {
    var iterator = std.mem.splitScalar(u8, params, ';');
    while (iterator.next()) |raw| {
        const code = std.fmt.parseInt(u16, raw, 10) catch continue;
        switch (code) {
            0 => style.* = .{},
            1 => style.attributes.bold = true,
            2 => style.attributes.dim = true,
            3 => style.attributes.italic = true,
            4 => style.attributes.underline = true,
            9 => style.attributes.strikethrough = true,
            22 => {
                style.attributes.bold = false;
                style.attributes.dim = false;
            },
            23 => style.attributes.italic = false,
            24 => style.attributes.underline = false,
            29 => style.attributes.strikethrough = false,
            39 => style.foreground = .default,
            38 => {
                const mode = iterator.next() orelse return;
                if (!std.mem.eql(u8, mode, "5")) continue;
                const color = iterator.next() orelse return;
                const value = std.fmt.parseInt(u8, color, 10) catch continue;
                style.foreground = .{ .indexed = value };
            },
            else => {},
        }
    }
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
    try std.testing.expect(screen.requests.hasPending());
}

test "screen stages facts and publishes one status composer frame" {
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
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "hello") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "Working") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "2 queued") != null);
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
    const expected_transcript: render.FramePlan.Band = .{ .top = 6, .bottom = 6 };
    const expected_footer: render.FramePlan.Band = .{ .top = 7, .bottom = 8 };
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
    try std.testing.expect(screen.store.entryAt(0).?.sealed);
    try std.testing.expect(screen.store.entryAt(1).?.sealed);
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
    _ = try screen.sealedEntry(.assistant, "\x1b[1mbold界\x1b[22m\nsecond\n");
    _ = try screen.sealedEntry(.notice, "later\nlast\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var frame = try screen.buildFrame(arena.allocator(), .{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    defer frame.deinit();
    try std.testing.expectEqual(@as(u16, 3), frame.plan.document_rows);
    const document = &frame.document.?;
    try std.testing.expect(document.rowCells(1).?[0].style.attributes.bold);
    try std.testing.expectEqualStrings("b", document.graphemeBytes(document.rowCells(1).?[0]).?);
    try std.testing.expectEqualStrings("s", document.graphemeBytes(document.rowCells(2).?[0]).?);
    for (document.rowCells(3).?) |cell| try std.testing.expect(cell.isBlank());

    screen.requests.request(.transcript);
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    const bytes = output.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "bold界"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "second"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\r\n"));
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
    _ = try screen.sealedEntry(.assistant, "one\ntwo\nthree\nfour\n");

    screen.requests.request(.transcript);
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
        @as(u32, 1),
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
        @as(u32, 1),
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
    try std.testing.expect(std.mem.find(u8, output.written(), "Working \xc2\xb7 read") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "secret") == null);

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
    try std.testing.expect(std.mem.find(u8, output.written(), "\xe2\x80\xa2 read") != null);
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

    const id = try screen.store.appendEntry(.assistant, "one\ntwo\nthree\n");
    screen.open_entry = id;
    screen.requests.request(.transcript);
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try std.testing.expect(screen.open_entry_irreversible);
    try screen.applyEventFact(.{ .agent_end = .{
        .run_id = @enumFromInt(1),
        .outcome = .cancelled,
        .messages = &.{},
    } });
    try std.testing.expect(screen.open_entry == null);
    try std.testing.expect(screen.store.entryAt(0).?.sealed);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", screen.store.entryAt(0).?.bytes());
}

test "screen finish flushes and seals an open Markdown tail before publication" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    try screen.begin(.{ .rows = 6, .columns = 30 }, 1);
    try screen.streamMarkdownBytes("buffered **tail**");

    try screen.finish(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try std.testing.expect(screen.open_entry == null);
    try std.testing.expect(screen.store.entryAt(0).?.sealed);
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

    const id = try screen.store.appendEntry(.assistant, "one\ntwo\n");
    screen.open_entry = id;
    screen.requests.request(.transcript);
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    try screen.store.appendTo(id, "three\n");
    screen.requests.request(.transcript);
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expect(screen.open_entry_irreversible);

    try screen.applyEventFact(.{ .agent_end = .{
        .run_id = @enumFromInt(1),
        .outcome = .cancelled,
        .messages = &.{},
    } });
    try std.testing.expect(screen.open_entry == null);
    try std.testing.expectEqual(@as(usize, 2), screen.store.entryCount());
    try std.testing.expect(screen.store.entryAt(0).?.sealed);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", screen.store.entryAt(0).?.bytes());
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

test "screen sanitizes Markdown before storing presentation escapes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.addMarkdownEntry(.assistant, "safe\x1b[2J **text**");
    const entry = screen.store.lastEntry().?;
    try std.testing.expect(std.mem.find(u8, entry.bytes(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, entry.bytes(), "safe") != null);
    try std.testing.expect(std.mem.find(u8, entry.bytes(), "text") != null);
}

test "screen prevents provider terminal escape injection" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var safe: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer safe.deinit();
    try SafeText.write(&safe.writer, "safe\x1b[2J\rtext\u{009b}tail", true);
    try std.testing.expectEqualStrings("safe\u{FFFD}[2J\u{FFFD}text\u{FFFD}tail", safe.written());
    try std.testing.expect(std.mem.find(u8, safe.written(), "\x1b") == null);
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
    try std.testing.expectEqual(@as(usize, 0), screen.store.entryCount());
    try std.testing.expect(!screen.requests.hasPending());
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
    try std.testing.expect(screen.requests.hasPending());
    try std.testing.expect(screen.terminal_renderer.shadow == null);
}
