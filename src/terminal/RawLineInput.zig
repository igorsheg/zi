const std = @import("std");
const builtin = @import("builtin");
const RawLineInput = @This();
const LineEditor = @import("LineEditor.zig");
const EditLayout = @import("EditLayout.zig");
const DisplayColumns = @import("DisplayColumns.zig");
const Size = @import("Size.zig");
const PosixMode = @import("PosixMode.zig");
const CookedLineInput = @import("CookedLineInput.zig");
const PromptHistory = @import("PromptHistory.zig");
const PromptSearch = @import("PromptSearch.zig");
const DisplayWidth = @import("../text/root.zig").DisplayWidth;

pub const max_prompt_bytes = LineEditor.max_prompt_bytes;
pub const OwnedLine = CookedLineInput.OwnedLine;
pub const Result = CookedLineInput.Result;

const paste_enable = "\x1b[?2004h";
const paste_disable = "\x1b[?2004l";
const cursor_show = "\x1b[?25h";
const cursor_hide = "\x1b[?25l";
const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const submission_marker_default = "▌ ";
const submission_body_column = 2;
const ctrl_c_notice = "ctrl+c again to exit";
const paste_end_marker_len = "\x1b[201~".len;

allocator: std.mem.Allocator,
io: std.Io,
stdin: std.Io.File,
stdout: std.Io.File,
writer: *std.Io.Writer,
prompt: []const u8,
empty_submit: bool = false,
submission_style_open: []const u8 = "",
submission_style_close: []const u8 = "",
display_columns: DisplayColumns.Policy = .terminal,
history: ?*PromptHistory = null,
search_style_open: []const u8 = "",
search_style_close: []const u8 = "",
search_no_match_style_open: []const u8 = "",
search_no_match_style_close: []const u8 = "",
mode: PosixMode,
screen_cursor_row: usize = 0,
screen_rows: usize = 1,
columns: usize = 80,
rows: usize = 24,
geometry_valid: bool = false,
paste_enabled: bool = false,
flush_input_on_cleanup: bool = false,
active: bool = false,
pending_preseed: ?[]u8 = null,

pub const Options = struct {
    empty_submit: bool = false,
    /// Borrowed terminal bytes. The caller keeps them valid for the input's lifetime.
    submission_style_open: []const u8 = "",
    submission_style_close: []const u8 = "",
    display_columns: DisplayColumns.Policy = .terminal,
    /// Borrowed for the input's lifetime.
    history: ?*PromptHistory = null,
    /// Borrowed terminal bytes. The caller keeps them valid for the input's lifetime.
    search_style_open: []const u8 = "",
    search_style_close: []const u8 = "",
    search_no_match_style_open: []const u8 = "",
    search_no_match_style_close: []const u8 = "",
};

/// The files and writer remain owned by the caller. Prompt, style bytes, and history are borrowed.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout: std.Io.File,
    writer: *std.Io.Writer,
    prompt: []const u8,
    options: Options,
) RawLineInput {
    return .{
        .allocator = allocator,
        .io = io,
        .stdin = stdin,
        .stdout = stdout,
        .writer = writer,
        .prompt = prompt,
        .empty_submit = options.empty_submit,
        .submission_style_open = options.submission_style_open,
        .submission_style_close = options.submission_style_close,
        .display_columns = options.display_columns,
        .history = options.history,
        .search_style_open = options.search_style_open,
        .search_style_close = options.search_style_close,
        .search_no_match_style_open = options.search_no_match_style_open,
        .search_no_match_style_close = options.search_no_match_style_close,
        .mode = PosixMode.init(stdin),
    };
}

/// Releases an unused preseed. The input must not be inside `read`.
pub fn deinit(input: *RawLineInput) void {
    std.debug.assert(!input.active);
    if (input.pending_preseed) |bytes| input.allocator.free(bytes);
    input.* = undefined;
}

/// Atomically replaces the bounded one-shot editor seed.
pub fn queuePreseed(
    input: *RawLineInput,
    bytes: []const u8,
) error{ OutOfMemory, PromptTooLarge }!void {
    if (bytes.len > max_prompt_bytes) return error.PromptTooLarge;
    if (bytes.len == 0) {
        if (input.pending_preseed) |previous| input.allocator.free(previous);
        input.pending_preseed = null;
        return;
    }
    const replacement = input.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
    if (input.pending_preseed) |previous| input.allocator.free(previous);
    input.pending_preseed = replacement;
}

/// Controls whether bare Enter can submit an empty line for a resumable turn.
pub fn setEmptySubmit(input: *RawLineInput, enabled: bool) void {
    input.empty_submit = enabled;
}

pub fn admitSession(input: *RawLineInput, line: []const u8) error{OutOfMemory}!void {
    const history = input.history orelse return;
    try history.admit(line, .session);
}

pub fn admitPersistent(input: *RawLineInput, line: []const u8) error{OutOfMemory}!void {
    const history = input.history orelse return;
    try history.admit(line, .persistent);
}

/// Reads directly from the stdin descriptor. A submitted result owns its bytes.
/// EOF owns no storage. All terminal state is restored before this function returns.
pub fn read(input: *RawLineInput) !Result {
    const preseed = input.pending_preseed;
    input.pending_preseed = null;
    defer if (preseed) |bytes| input.allocator.free(bytes);
    var editor = try initializeEditor(input, preseed);
    defer editor.deinit();

    if (input.history) |history| history.beginRead();
    try input.enter();
    errdefer input.cleanupIgnoringErrors();
    try input.repaint(&editor, .{});

    while (true) {
        const byte = switch (try input.readByte(250)) {
            .byte => |byte| byte,
            .eof => {
                try input.finish();
                return .eof;
            },
            .timeout => {
                const size = input.querySize();
                if (size.columns != input.columns or size.rows != input.rows)
                    try input.repaint(&editor, .{ .show_notice = editor.exit_armed });
                continue;
            },
        };

        if (byte == 0x0c) {
            try input.repaint(&editor, .{
                .show_notice = editor.exit_armed,
                .clear_screen = true,
            });
            continue;
        }
        if (byte == 0x1a) {
            try input.suspendEditing(&editor);
            continue;
        }

        const was_armed = editor.exit_armed;
        const outcome = if (byte == 0x1b)
            try input.handleEscape(&editor)
        else
            try input.handleEditorByte(&editor, byte);

        switch (outcome) {
            .none => {
                if (was_armed and !editor.exit_armed)
                    try input.repaint(&editor, .{});
            },
            .history_previous, .history_next => |navigation| {
                const direction: PromptHistory.Direction = if (navigation == .history_previous)
                    .older
                else
                    .newer;
                if (try input.navigateHistory(&editor, direction)) {
                    try input.repaint(&editor, .{});
                } else if (was_armed and !editor.exit_armed) {
                    try input.repaint(&editor, .{});
                }
            },
            .history_search => {
                if (input.history) |history| {
                    switch (try input.searchHistory(&editor, history)) {
                        .editing => try input.repaint(&editor, .{}),
                        .submit => return input.submitAndFinish(&editor),
                        .eof => {
                            try input.finish();
                            return .eof;
                        },
                    }
                } else if (was_armed and !editor.exit_armed) {
                    try input.repaint(&editor, .{});
                }
            },
            .edited => try input.repaint(&editor, .{}),
            .exit_armed => try input.repaint(&editor, .{ .show_notice = true }),
            .paste_begin => switch (try input.collectPaste(&editor)) {
                .complete, .idle => try input.repaint(&editor, .{}),
                .eof => {
                    try input.finish();
                    return .eof;
                },
            },
            .submit => return input.submitAndFinish(&editor),
            .eof => {
                try input.finish();
                return .eof;
            },
        }
    }
}

fn handleEditorByte(
    input: *RawLineInput,
    editor: *LineEditor,
    byte: u8,
) LineEditor.Error!LineEditor.Outcome {
    if (byte == 0x03 and editor.bytes().len != 0) {
        if (input.history) |history| {
            try history.admit(editor.bytes(), .session);
            history.beginRead();
        }
    }
    return editor.handleByte(byte);
}

fn initializeEditor(input: *RawLineInput, preseed: ?[]const u8) !LineEditor {
    var editor = LineEditor.init(input.allocator, input.empty_submit);
    errdefer editor.deinit();
    if (preseed) |bytes| try editor.setBuffer(bytes);
    return editor;
}

fn navigateHistory(
    input: *RawLineInput,
    editor: *LineEditor,
    direction: PromptHistory.Direction,
) LineEditor.Error!bool {
    const history = input.history orelse return false;
    var prepared = (try history.prepareNavigation(editor.bytes(), direction)) orelse return false;
    editor.setBuffer(prepared.target) catch |err| {
        prepared.deinit(history.allocator);
        return err;
    };
    history.commitNavigation(&prepared);
    return true;
}

fn enter(input: *RawLineInput) !void {
    _ = try std.posix.tcgetattr(input.stdin.handle);
    _ = try std.posix.tcgetattr(input.stdout.handle);
    try input.mode.apply(.prompt_edit);
    errdefer input.cleanupIgnoringErrors();
    input.paste_enabled = true;
    try input.writer.writeAll(paste_enable);
    try input.writer.writeAll(cursor_show);
    try input.writer.flush();
    input.active = true;
    input.screen_cursor_row = 0;
    input.screen_rows = 1;
    input.geometry_valid = false;
}

fn finish(input: *RawLineInput) !void {
    if (input.active) try input.leaveFreshRow();
    try input.cleanup();
}

fn submitAndFinish(input: *RawLineInput, editor: *LineEditor) !Result {
    const nonempty = editor.bytes().len != 0;
    if (nonempty) {
        const size = input.querySize();
        if (size.columns != input.columns or size.rows != input.rows)
            try input.repaint(editor, .{ .show_notice = editor.exit_armed });
        try input.renderSubmitted(editor.bytes());
    }

    var result = takeSubmitted(editor);
    errdefer result.deinit(input.allocator);
    if (!nonempty) {
        try input.finish();
    } else {
        // renderSubmitted already placed the cursor on the next transcript row.
        try input.cleanup();
    }
    return result;
}

fn cleanup(input: *RawLineInput) !void {
    var first_error: ?anyerror = null;
    if (input.paste_enabled) {
        var disabled = true;
        input.writer.writeAll(paste_disable) catch |err| {
            first_error = err;
            disabled = false;
        };
        if (disabled) input.paste_enabled = false;
    }
    input.writer.writeAll(cursor_show) catch |err| if (first_error == null) {
        first_error = err;
    };
    input.writer.flush() catch |err| if (first_error == null) {
        first_error = err;
    };
    input.mode.restore() catch |err| if (first_error == null) {
        first_error = err;
    };
    if (input.flush_input_on_cleanup) {
        var flushed = true;
        flushInput(input.stdin.handle) catch |err| {
            if (first_error == null) first_error = err;
            flushed = false;
        };
        if (flushed) input.flush_input_on_cleanup = false;
    }
    input.active = false;
    if (first_error) |err| return err;
}

fn cleanupIgnoringErrors(input: *RawLineInput) void {
    _ = input.cleanup() catch return;
}

fn leaveFreshRow(input: *RawLineInput) !void {
    const size = input.querySize();
    if (input.geometry_valid and (size.columns != input.columns or size.rows != input.rows)) {
        try input.writer.writeAll("\r\x1b[999B\r\n\x1b[J");
        try input.writer.flush();
        input.columns = size.columns;
        input.rows = size.rows;
        input.screen_cursor_row = 0;
        input.screen_rows = 1;
        input.geometry_valid = false;
        return;
    }
    try input.writer.writeByte('\r');
    const rows_below = input.screen_rows -| (input.screen_cursor_row + 1);
    if (rows_below != 0) try writeCursorMove(input.writer, rows_below, 'B');
    try input.writer.writeAll("\r\n\x1b[J");
    try input.writer.flush();
    input.screen_cursor_row = 0;
    input.screen_rows = 1;
}

/// Paints one already-committed user message at column zero. The caller owns
/// surrounding block separation and guarantees no active editor row exists.
pub fn renderCommitted(
    writer: *std.Io.Writer,
    text: []const u8,
    style_open: []const u8,
    style_close: []const u8,
    columns: usize,
) std.Io.Writer.Error!void {
    try writer.writeAll(style_open);
    try writer.writeAll(submission_marker_default);
    var sink_context: SubmittedPaintSink = .{
        .writer = writer,
        .style_open = style_open,
        .style_close = style_close,
    };
    _ = EditLayout.render(text, text.len, .{
        .prompt_width = submission_body_column,
        .continuation_column = submission_body_column,
        .columns = columns,
    }, sink_context.sink());
    if (sink_context.failed) return error.WriteFailed;
    try writer.writeAll(style_close);
    try writer.writeAll("\x1b[K\r\n");
    try writer.flush();
}

fn renderSubmitted(input: *RawLineInput, text: []const u8) !void {
    try input.writer.writeAll(sync_begin);
    errdefer {
        input.writer.writeAll(input.submission_style_close) catch {};
        input.writer.writeAll("\x1b[0m") catch {};
        input.writer.writeAll(sync_end) catch {};
        input.writer.flush() catch {};
    }
    if (input.screen_cursor_row != 0)
        try writeCursorMove(input.writer, input.screen_cursor_row, 'A');
    try input.writer.writeByte('\r');
    try input.writer.writeAll(input.submission_style_open);
    try input.writer.writeAll(submission_marker_default);

    var sink_context: SubmittedPaintSink = .{
        .writer = input.writer,
        .style_open = input.submission_style_open,
        .style_close = input.submission_style_close,
    };
    _ = EditLayout.render(text, text.len, .{
        .prompt_width = submission_body_column,
        .continuation_column = submission_body_column,
        .columns = input.columns,
    }, sink_context.sink());
    if (sink_context.failed) return error.WriteFailed;

    try input.writer.writeAll(input.submission_style_close);
    try input.writer.writeAll("\x1b[K\r\n\x1b[J");
    try input.writer.writeAll(sync_end);
    try input.writer.flush();
    input.screen_cursor_row = 0;
    input.screen_rows = 1;
    input.geometry_valid = false;
}

const SubmittedPaintSink = struct {
    writer: *std.Io.Writer,
    style_open: []const u8,
    style_close: []const u8,
    failed: bool = false,

    fn sink(context: *SubmittedPaintSink) EditLayout.Sink {
        return .{ .context = context, .emit_fn = emit };
    }

    fn emit(raw_context: *anyopaque, event: EditLayout.Event) void {
        const context: *SubmittedPaintSink = @ptrCast(@alignCast(raw_context));
        if (context.failed) return;
        switch (event) {
            .glyph => |glyph| context.writer.writeAll(glyph.bytes) catch {
                context.failed = true;
            },
            .row_break => {
                context.writer.writeAll(context.style_close) catch {
                    context.failed = true;
                    return;
                };
                context.writer.writeAll("\x1b[K\r\n") catch {
                    context.failed = true;
                    return;
                };
                context.writer.writeAll(context.style_open) catch {
                    context.failed = true;
                    return;
                };
                context.writer.writeAll(submission_marker_default) catch {
                    context.failed = true;
                };
            },
        }
    }
};

fn suspendEditing(input: *RawLineInput, editor: *const LineEditor) !void {
    try input.leaveFreshRow();
    try input.cleanup();
    try std.posix.raise(.TSTP);
    try input.enter();
    try input.repaint(editor, .{ .show_notice = editor.exit_armed });
}

fn handleEscape(input: *RawLineInput, editor: *LineEditor) !LineEditor.Outcome {
    const first = switch (try input.readByte(50)) {
        .byte => |byte| byte,
        .timeout, .eof => return .none,
    };
    if (first == '\r' or first == '\n') {
        try editor.insert("\n");
        return .edited;
    }
    const meta_action = metaAction(first);
    if (meta_action != .none) return editor.applyAction(meta_action);

    var sequence: [70]u8 = undefined;
    sequence[0] = first;
    var len: usize = 1;
    var leader = first;
    var stripped: usize = 0;
    while (leader == 0x1b and stripped < 4 and len < sequence.len) : (stripped += 1) {
        leader = switch (try input.readByte(50)) {
            .byte => |byte| byte,
            .timeout, .eof => break,
        };
        sequence[len] = leader;
        len += 1;
    }
    if (leader == '[' or leader == 'O') {
        while (len < sequence.len) {
            const byte = switch (try input.readByte(50)) {
                .byte => |byte| byte,
                .timeout, .eof => break,
            };
            sequence[len] = byte;
            len += 1;
            if ((byte >= 0x40 and byte <= 0x7e) or byte == '$' or byte < 0x20 or byte > 0x7e) break;
        }
    }

    const decoded = LineEditor.decodeEscape(sequence[0..len]);
    const action = if (decoded.action != .none)
        decoded.action
    else
        commonModifiedAction(sequence[0..len]);
    return editor.applyAction(action);
}

fn metaAction(byte: u8) LineEditor.EscapeAction {
    return switch (byte) {
        'b', 'B' => .move_word_left,
        'f', 'F' => .move_word_right,
        'd', 'D' => .delete_word_forward,
        0x08, 0x7f => .delete_word_back,
        else => .none,
    };
}

fn commonModifiedAction(sequence: []const u8) LineEditor.EscapeAction {
    if (sequence.len < 3 or sequence[0] != '[') return .none;
    for (sequence[1 .. sequence.len - 1]) |byte| {
        if ((byte < '0' or byte > '9') and byte != ';') return .none;
    }
    return switch (sequence[sequence.len - 1]) {
        'C' => .move_word_right,
        'D' => .move_word_left,
        'H' => .line_start,
        'F' => .line_end,
        'A' => .history_previous,
        'B' => .history_next,
        else => .none,
    };
}

fn collectPaste(input: *RawLineInput, editor: *LineEditor) !PasteFinish {
    const source: PasteByteSource = .{
        .context = input,
        .read_fn = readPasteByte,
    };
    return collectPasteFrom(input.allocator, editor, source) catch |err| {
        input.flush_input_on_cleanup = true;
        return err;
    };
}

const PasteFinish = enum {
    complete,
    idle,
    eof,
};

const OwnedPaste = struct {
    body: std.ArrayList(u8),
    finish: PasteFinish,

    fn deinit(paste: *OwnedPaste, allocator: std.mem.Allocator) void {
        paste.body.deinit(allocator);
        paste.* = undefined;
    }
};

fn readPasteByte(raw_context: *anyopaque) anyerror!ReadSample {
    const input: *RawLineInput = @ptrCast(@alignCast(raw_context));
    return input.readByte(5000);
}

const PasteByteSource = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque) anyerror!ReadSample,

    fn read(source: PasteByteSource) !ReadSample {
        return source.read_fn(source.context);
    }
};

fn collectPasteBodyFrom(
    collector_allocator: std.mem.Allocator,
    maximum: usize,
    source: PasteByteSource,
) !OwnedPaste {
    // Retain only a bounded prefix, but always consume through the exact marker.
    var collector = LineEditor.PasteCollector.init(collector_allocator, maximum);
    errdefer collector.deinit();
    var retention_error: ?anyerror = null;

    while (true) {
        const sample = try source.read();
        const byte = switch (sample) {
            .byte => |byte| byte,
            .timeout, .eof => {
                if (retention_error) |err| return err;
                collector.finishPartial() catch |err| {
                    retention_error = err;
                    collector.max_bytes = collector.body.items.len;
                    continue;
                };
                const body = collector.body;
                collector.body = .empty;
                collector.deinit();
                return .{
                    .body = body,
                    .finish = if (sample == .timeout) .idle else .eof,
                };
            },
        };
        const result: LineEditor.PasteCollector.FeedResult = collector.feed(&.{byte}) catch |err| result: {
            if (retention_error == null) retention_error = err;
            collector.max_bytes = collector.body.items.len;
            if (collector.marker_len == paste_end_marker_len) {
                collector.pending_cr = false;
                collector.complete = true;
                break :result .{ .consumed = 1, .complete = true };
            }
            // Replay the failed byte in discard mode. It may begin the end marker.
            break :result try collector.feed(&.{byte});
        };
        if (result.complete) break;
    }
    if (retention_error) |err| return err;
    const body = collector.body;
    collector.body = .empty;
    collector.deinit();
    return .{ .body = body, .finish = .complete };
}

fn collectPasteFrom(
    collector_allocator: std.mem.Allocator,
    editor: *LineEditor,
    source: PasteByteSource,
) !PasteFinish {
    var paste = try collectPasteBodyFrom(
        collector_allocator,
        max_prompt_bytes - editor.bytes().len,
        source,
    );
    defer paste.deinit(collector_allocator);
    try editor.insert(paste.body.items);
    return paste.finish;
}

const ReadSample = union(enum) {
    byte: u8,
    timeout,
    eof,
};

const SearchFinish = enum { editing, submit, eof };

const SearchByteSource = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, i32) anyerror!ReadSample,

    fn read(source: SearchByteSource, timeout_ms: i32) !ReadSample {
        return source.read_fn(source.context, timeout_ms);
    }
};

fn readSearchByte(raw_context: *anyopaque, timeout_ms: i32) anyerror!ReadSample {
    const input: *RawLineInput = @ptrCast(@alignCast(raw_context));
    return input.readByte(timeout_ms);
}

fn searchHistory(
    input: *RawLineInput,
    editor: *LineEditor,
    history: *PromptHistory,
) !SearchFinish {
    const source: SearchByteSource = .{
        .context = input,
        .read_fn = readSearchByte,
    };
    return input.searchHistoryFrom(editor, history, source);
}

fn searchHistoryFrom(
    input: *RawLineInput,
    editor: *LineEditor,
    history: *PromptHistory,
    source: SearchByteSource,
) !SearchFinish {
    var search = try PromptSearch.init(input.allocator, editor, history);
    defer search.deinit();
    errdefer _ = search.finish(history, editor, .cancel) catch .editing;
    var needs_paint = true;

    while (true) {
        if (needs_paint) {
            const view = search.view(history);
            try editor.setBufferAtCursor(view.buffer, view.cursor);
            var prompt = try input.buildSearchPrompt(&search, input.querySize().columns);
            defer prompt.deinit(input.allocator);
            try input.repaint(editor, .{
                .prompt = prompt.items,
                .continuation_column = 0,
            });
            needs_paint = false;
        }

        const sample = source.read(250) catch |err| {
            _ = try search.finish(history, editor, .cancel);
            return err;
        };
        const key = switch (sample) {
            .timeout => {
                const size = input.querySize();
                needs_paint = size.columns != input.columns or size.rows != input.rows;
                continue;
            },
            .eof => {
                _ = try search.finish(history, editor, .cancel);
                return .eof;
            },
            .byte => |byte| byte,
        };
        needs_paint = true;

        switch (key) {
            0x12 => search.repeat(history, .older),
            0x13 => search.repeat(history, .newer),
            0x08, 0x7f => search.backspace(history),
            0x03, 0x07 => {
                _ = try search.finish(history, editor, .cancel);
                return .editing;
            },
            '\r' => return switch (try search.finish(history, editor, .submit)) {
                .editing => .editing,
                .submit => .submit,
            },
            '\n' => {
                _ = try search.finish(history, editor, .accept);
                return .editing;
            },
            0x1b => {
                if (try consumeSearchEscape(source)) {
                    try input.appendSearchPaste(&search, history, source);
                    continue;
                }
                _ = try search.finish(history, editor, .accept);
                return .editing;
            },
            0x20...0x7e, 0x80...0xff => try appendTypedSearchBytes(&search, history, key, source),
            else => {},
        }
    }
}

fn appendTypedSearchBytes(
    search: *PromptSearch,
    history: *const PromptHistory,
    first: u8,
    source: SearchByteSource,
) !void {
    var bytes: [4]u8 = undefined;
    bytes[0] = first;
    const expected = std.unicode.utf8ByteSequenceLength(first) catch 1;
    var len: usize = 1;
    while (len < expected) : (len += 1) {
        bytes[len] = switch (try source.read(50)) {
            .byte => |byte| byte,
            .timeout, .eof => break,
        };
    }
    try search.append(history, bytes[0..len]);
}

/// Consumes one bounded escape sequence. Only bracketed-paste begin returns true.
fn consumeSearchEscape(source: SearchByteSource) !bool {
    var sequence: [70]u8 = undefined;
    var len: usize = 0;
    var leader: u8 = 0;
    var stripped: usize = 0;
    while (stripped < 5 and len < sequence.len) : (stripped += 1) {
        leader = switch (try source.read(50)) {
            .byte => |byte| byte,
            .timeout, .eof => return false,
        };
        sequence[len] = leader;
        len += 1;
        if (leader != 0x1b) break;
    }
    if (leader == '[' or leader == 'O') {
        while (len < sequence.len) {
            const byte = switch (try source.read(50)) {
                .byte => |byte| byte,
                .timeout, .eof => break,
            };
            sequence[len] = byte;
            len += 1;
            if ((byte >= 0x40 and byte <= 0x7e) or byte == '$' or byte < 0x20 or byte > 0x7e) break;
        }
    }
    return LineEditor.decodeEscape(sequence[0..len]).action == .paste_begin;
}

const SearchPasteAdapter = struct {
    source: SearchByteSource,

    fn pasteSource(adapter: *SearchPasteAdapter) PasteByteSource {
        return .{ .context = adapter, .read_fn = SearchPasteAdapter.read };
    }

    fn read(raw_context: *anyopaque) anyerror!ReadSample {
        const adapter: *SearchPasteAdapter = @ptrCast(@alignCast(raw_context));
        return switch (try adapter.source.read(5000)) {
            .byte => |byte| .{ .byte = if (byte == 0) 1 else byte },
            .timeout => .timeout,
            .eof => .eof,
        };
    }
};

fn appendSearchPaste(
    input: *RawLineInput,
    search: *PromptSearch,
    history: *const PromptHistory,
    source: SearchByteSource,
) !void {
    var adapter: SearchPasteAdapter = .{ .source = source };
    var paste = collectPasteBodyFrom(
        input.allocator,
        max_prompt_bytes - search.query.items.len,
        adapter.pasteSource(),
    ) catch |err| {
        input.flush_input_on_cleanup = true;
        return err;
    };
    defer paste.deinit(input.allocator);

    var retained: usize = 0;
    for (paste.body.items) |byte| {
        if (byte >= 0x20 and byte != 0x7f) {
            paste.body.items[retained] = byte;
            retained += 1;
        }
    }
    try search.append(history, paste.body.items[0..retained]);
}

/// A nonnegative timeout bounds the wait. EOF and timeout remain distinct.
fn readByte(input: *RawLineInput, timeout_ms: i32) !ReadSample {
    var fds = [_]std.posix.pollfd{.{
        .fd = input.stdin.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&fds, timeout_ms) == 0) return .timeout;
    var byte: [1]u8 = undefined;
    const count = try std.posix.read(input.stdin.handle, &byte);
    return if (count == 0) .eof else .{ .byte = byte[0] };
}

const PaintOptions = struct {
    prompt: ?[]const u8 = null,
    continuation_column: ?usize = null,
    show_notice: bool = false,
    clear_screen: bool = false,
};

fn buildSearchPrompt(
    input: *const RawLineInput,
    search: *const PromptSearch,
    columns: usize,
) error{OutOfMemory}!std.ArrayList(u8) {
    const label = if (search.direction == .older) "reverse-search" else "forward-search";
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(input.allocator);
    try plain.appendSlice(input.allocator, label);
    if (search.query.items.len != 0) {
        try plain.appendSlice(input.allocator, " · ");
        var glyphs = DisplayWidth.iterator(search.query.items);
        while (glyphs.next()) |glyph| try plain.appendSlice(input.allocator, glyph.bytes);
    }
    try plain.appendSlice(input.allocator, " → ");
    const suffix_start = plain.items.len;
    if (search.no_match) try plain.appendSlice(input.allocator, "(no match)");

    const budget = if (columns > 1) columns - 1 else 1;
    const total_width = DisplayWidth.visibleWidth(plain.items, std.math.maxInt(usize));
    var keep_from: usize = 0;
    const clipped = total_width > budget;
    if (clipped) {
        var kept_width: usize = 0;
        var offset = plain.items.len;
        const tail_budget = budget - 1;
        keep_from = offset;
        while (offset != 0) {
            const previous = LineEditor.previousCodepoint(plain.items, offset);
            const glyph = DisplayWidth.next(plain.items, previous) orelse unreachable;
            if (glyph.width > tail_budget -| kept_width) break;
            kept_width += glyph.width;
            keep_from = previous;
            offset = previous;
        }
    }

    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(input.allocator);
    const starts_in_suffix = keep_from >= suffix_start and search.no_match;
    if (starts_in_suffix) {
        try styled.appendSlice(input.allocator, input.search_no_match_style_open);
    } else {
        try styled.appendSlice(input.allocator, input.search_style_open);
    }
    if (clipped) try styled.appendSlice(input.allocator, "…");
    if (!starts_in_suffix and search.no_match and keep_from < suffix_start) {
        try styled.appendSlice(input.allocator, plain.items[keep_from..suffix_start]);
        try styled.appendSlice(input.allocator, input.search_style_close);
        try styled.appendSlice(input.allocator, input.search_no_match_style_open);
        try styled.appendSlice(input.allocator, plain.items[suffix_start..]);
        try styled.appendSlice(input.allocator, input.search_no_match_style_close);
    } else {
        try styled.appendSlice(input.allocator, plain.items[keep_from..]);
        try styled.appendSlice(
            input.allocator,
            if (starts_in_suffix)
                input.search_no_match_style_close
            else
                input.search_style_close,
        );
    }
    plain.deinit(input.allocator);
    return styled;
}

fn repaint(
    input: *RawLineInput,
    editor: *const LineEditor,
    options: PaintOptions,
) !void {
    const prompt = options.prompt orelse input.prompt;
    const prompt_width = EditLayout.promptWidth(prompt);
    const continuation_column = options.continuation_column orelse prompt_width;
    const size = input.querySize();
    const geometry_changed = input.geometry_valid and
        (size.columns != input.columns or size.rows != input.rows);
    input.columns = size.columns;
    input.rows = size.rows;

    if (options.clear_screen) {
        try input.writer.writeAll(cursor_hide ++ "\x1b[2J\x1b[H");
        input.screen_cursor_row = 0;
    } else if (geometry_changed) {
        // Old relative rows are invalid after reflow. Move to the viewport bottom
        // and scroll once instead of risking an overwrite with stale geometry.
        try input.writer.writeAll(cursor_hide ++ "\r\x1b[999B\r\n");
        input.screen_cursor_row = 0;
        input.screen_rows = 1;
    } else {
        try input.writer.writeAll(cursor_hide ++ "\r");
        if (input.screen_cursor_row != 0)
            try writeCursorMove(input.writer, input.screen_cursor_row, 'A');
    }
    try input.writer.writeAll("\r\x1b[J");

    const layout = EditLayout.compute(editor.bytes(), editor.cursor, prompt_width, input.columns);
    const display_notice = options.show_notice and input.rows > 1;
    const window = visibleWindow(layout, input.rows, display_notice);
    if (window.start_row == 0) try input.writer.writeAll(prompt);

    var sink_context: ClippedPaintSink = .{
        .writer = input.writer,
        .start_row = window.start_row,
        .end_row = window.start_row + window.row_count,
        .started = window.start_row == 0,
    };
    _ = EditLayout.render(editor.bytes(), editor.cursor, .{
        .prompt_width = prompt_width,
        .continuation_column = continuation_column,
        .columns = input.columns,
    }, sink_context.sink());
    if (sink_context.failed) return error.WriteFailed;

    var final_row = window.row_count - 1;
    if (display_notice) {
        try input.writer.writeAll("\r\n");
        try input.writer.writeAll(ctrl_c_notice);
        final_row += 1;
    }
    if (final_row > window.cursor_row)
        try writeCursorMove(input.writer, final_row - window.cursor_row, 'A');
    try input.writer.writeByte('\r');
    if (layout.cursor.column != 0)
        try writeCursorMove(input.writer, layout.cursor.column, 'C');
    try input.writer.writeAll(cursor_show);
    try input.writer.flush();

    input.screen_cursor_row = window.cursor_row;
    input.screen_rows = window.row_count + @intFromBool(display_notice);
    input.geometry_valid = true;
}

const VisibleWindow = struct {
    start_row: usize,
    row_count: usize,
    cursor_row: usize,
};

fn visibleWindow(layout: EditLayout.Layout, terminal_rows: usize, show_notice: bool) VisibleWindow {
    const safe_rows = @max(@as(usize, 1), terminal_rows);
    const edit_capacity = @max(@as(usize, 1), safe_rows - @intFromBool(show_notice));
    const row_count = @min(layout.total_rows, edit_capacity);
    const start_row = if (layout.cursor.row >= edit_capacity)
        layout.cursor.row - edit_capacity + 1
    else
        0;
    return .{
        .start_row = start_row,
        .row_count = row_count,
        .cursor_row = layout.cursor.row - start_row,
    };
}

const ClippedPaintSink = struct {
    writer: *std.Io.Writer,
    start_row: usize,
    end_row: usize,
    started: bool,
    failed: bool = false,

    fn sink(context: *ClippedPaintSink) EditLayout.Sink {
        return .{ .context = context, .emit_fn = emit };
    }

    fn emit(raw_context: *anyopaque, event: EditLayout.Event) void {
        const context: *ClippedPaintSink = @ptrCast(@alignCast(raw_context));
        if (context.failed) return;
        switch (event) {
            .glyph => |glyph| {
                if (glyph.position.row < context.start_row or glyph.position.row >= context.end_row) return;
                context.startAt(glyph.position.column);
                context.writer.writeAll(glyph.bytes) catch {
                    context.failed = true;
                };
            },
            .row_break => |position| {
                if (position.row < context.start_row or position.row >= context.end_row) return;
                if (!context.started) {
                    context.startAt(position.column);
                    return;
                }
                context.writer.writeAll("\r\n") catch {
                    context.failed = true;
                    return;
                };
                context.writer.splatByteAll(' ', position.column) catch {
                    context.failed = true;
                };
            },
        }
    }

    fn startAt(context: *ClippedPaintSink, column: usize) void {
        if (context.started) return;
        context.writer.splatByteAll(' ', column) catch {
            context.failed = true;
            return;
        };
        context.started = true;
    }
};

fn writeCursorMove(writer: *std.Io.Writer, amount: usize, direction: u8) !void {
    if (amount == 0) return;
    var digits: [32]u8 = undefined;
    var index = digits.len;
    var remaining = amount;
    while (remaining != 0) {
        index -= 1;
        digits[index] = @intCast('0' + remaining % 10);
        remaining /= 10;
    }
    try writer.writeAll("\x1b[");
    try writer.writeAll(digits[index..]);
    try writer.writeByte(direction);
}

fn takeSubmitted(editor: *LineEditor) Result {
    const buffer = editor.buffer;
    editor.buffer = .empty;
    editor.cursor = 0;
    return .{ .submit = .{
        .bytes = buffer.items,
        .capacity = buffer.capacity,
    } };
}

fn querySize(input: *const RawLineInput) Size {
    var size = Size.query(input.stdout.handle);
    size.columns = @min(size.columns, input.display_columns.resolve(size.columns));
    return size;
}

fn flushInput(fd: std.posix.fd_t) !void {
    const queue: c_int = switch (builtin.os.tag) {
        .linux => 0,
        .macos, .ios, .tvos, .watchos, .visionos => 1,
        else => return error.InputFlushUnsupported,
    };
    if (tcflush(fd, queue) != 0) return error.InputFlushFailed;
}

extern "c" fn tcflush(fd: c_int, queue: c_int) c_int;

fn invalidRawInput(allocator: std.mem.Allocator, writer: *std.Io.Writer) RawLineInput {
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    return init(
        allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        writer,
        "> ",
        .{},
    );
}

test "raw preseed replacement clear bounds and deinit are atomic" {
    var output: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&output);
    var input = invalidRawInput(std.testing.allocator, &writer);
    defer input.deinit();
    try input.queuePreseed("first");
    try std.testing.expectEqualStrings("first", input.pending_preseed.?);
    try input.queuePreseed("second");
    try std.testing.expectEqualStrings("second", input.pending_preseed.?);

    var oversized: [max_prompt_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(error.PromptTooLarge, input.queuePreseed(&oversized));
    try std.testing.expectEqualStrings("second", input.pending_preseed.?);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    input.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, input.queuePreseed("replacement"));
    input.allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("second", input.pending_preseed.?);
    try input.queuePreseed("");
    try std.testing.expect(input.pending_preseed == null);
    // The deferred deinit owns a seed which was never consumed by read.
    try input.queuePreseed("unused");
}

test "raw preseed editor starts at end and moved seed is freed on setup OOM" {
    var output: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&output);
    var input = invalidRawInput(std.testing.allocator, &writer);
    defer input.deinit();
    var editor = try initializeEditor(&input, "/preset-save ");
    defer editor.deinit();
    try std.testing.expectEqualStrings("/preset-save ", editor.bytes());
    try std.testing.expectEqual(editor.bytes().len, editor.cursorOffset());

    try input.queuePreseed("owned seed");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    input.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, input.read());
    input.allocator = std.testing.allocator;
    try std.testing.expect(input.pending_preseed == null);
}

test "raw preseed is consumed before terminal entry failure" {
    var descriptors: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&descriptors));
    const read_end: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
    defer read_end.close(std.testing.io);
    const write_end: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
    defer write_end.close(std.testing.io);
    var output: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&output);
    var input = init(
        std.testing.allocator,
        std.testing.io,
        read_end,
        write_end,
        &writer,
        "> ",
        .{},
    );
    defer input.deinit();
    try input.queuePreseed("one shot");
    try std.testing.expectError(error.NotATerminal, input.read());
    try std.testing.expect(input.pending_preseed == null);
}

test "input display policy bounds editor columns independently of physical fallback" {
    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    const input = init(
        std.testing.allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{ .display_columns = .{ .fixed = 40 } },
    );

    const size = input.querySize();
    try std.testing.expectEqual(@as(usize, 40), size.columns);
    try std.testing.expectEqual(@as(usize, 24), size.rows);
}

test "meta word actions classify and unknown input stays inert" {
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_left, metaAction('b'));
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_right, metaAction('f'));
    try std.testing.expectEqual(LineEditor.EscapeAction.delete_word_forward, metaAction('d'));
    try std.testing.expectEqual(LineEditor.EscapeAction.delete_word_back, metaAction(0x7f));
    try std.testing.expectEqual(LineEditor.EscapeAction.none, metaAction('x'));
}

test "modified CSI actions include history navigation" {
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_left, commonModifiedAction("[1;5D"));
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_right, commonModifiedAction("[1;5C"));
    try std.testing.expectEqual(LineEditor.EscapeAction.line_end, commonModifiedAction("[1;2F"));
    try std.testing.expectEqual(LineEditor.EscapeAction.history_previous, commonModifiedAction("[1;2A"));
    try std.testing.expectEqual(LineEditor.EscapeAction.history_next, commonModifiedAction("[1;5B"));
    try std.testing.expectEqual(LineEditor.EscapeAction.none, commonModifiedAction("[xD"));
}

fn testInput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    history: ?*PromptHistory,
) RawLineInput {
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    return init(
        allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        writer,
        "> ",
        .{ .history = history },
    );
}

test "null history keeps admission navigation and ctrl-c safe" {
    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testInput(std.testing.allocator, &writer, null);
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");

    try input.admitSession("session");
    try input.admitPersistent("persistent");
    try std.testing.expect(!try input.navigateHistory(&editor, .older));
    try std.testing.expectEqual(LineEditor.Outcome.edited, try input.handleEditorByte(&editor, 0x03));
    try std.testing.expectEqualStrings("", editor.bytes());
}

test "history navigation restores the live draft transactionally" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("oldest");
    try history.seed("newest");
    history.beginRead();

    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testInput(std.testing.allocator, &writer, &history);
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("live draft");

    try std.testing.expect(try input.navigateHistory(&editor, .older));
    try std.testing.expectEqualStrings("newest", editor.bytes());
    try std.testing.expect(try input.navigateHistory(&editor, .older));
    try std.testing.expectEqualStrings("oldest", editor.bytes());
    try std.testing.expect(try input.navigateHistory(&editor, .newer));
    try std.testing.expectEqualStrings("newest", editor.bytes());
    try std.testing.expect(try input.navigateHistory(&editor, .newer));
    try std.testing.expectEqualStrings("live draft", editor.bytes());
    try std.testing.expect(!try input.navigateHistory(&editor, .newer));
}

test "history navigation OOM preserves editor and history state" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("history entry too long for editor storage");
    history.beginRead();

    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testInput(std.testing.allocator, &writer, &history);
    var editor_storage: [5]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&editor_storage);
    var editor = LineEditor.init(fixed.allocator(), false);
    defer editor.deinit();
    try editor.setBuffer("draft");

    try std.testing.expectError(error.OutOfMemory, input.navigateHistory(&editor, .older));
    try std.testing.expectEqualStrings("draft", editor.bytes());
    try std.testing.expectEqual(history.count(), history.currentPosition());
    try std.testing.expect(history.draft == null);
}

test "nonempty ctrl-c admits a session entry before clearing" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("older");
    history.beginRead();

    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testInput(std.testing.allocator, &writer, &history);
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");

    try std.testing.expectEqual(LineEditor.Outcome.edited, try input.handleEditorByte(&editor, 0x03));
    try std.testing.expectEqualStrings("", editor.bytes());
    try std.testing.expectEqualStrings("draft", history.entry(history.count() - 1).?);
    try std.testing.expectEqual(history.count(), history.currentPosition());
}

test "ctrl-c admission OOM keeps the editor intact" {
    var history_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&history_storage);
    var history = PromptHistory.init(fixed.allocator());
    defer history.deinit();

    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testInput(std.testing.allocator, &writer, &history);
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("keep me");

    try std.testing.expectError(error.OutOfMemory, input.handleEditorByte(&editor, 0x03));
    try std.testing.expectEqualStrings("keep me", editor.bytes());
    try std.testing.expectEqual(@as(usize, 0), history.count());
}

const TestPasteSource = struct {
    bytes: []const u8,
    index: usize = 0,
    ending: ReadSample = .timeout,

    fn source(test_source: *TestPasteSource) PasteByteSource {
        return .{ .context = test_source, .read_fn = TestPasteSource.read };
    }

    fn read(raw_context: *anyopaque) anyerror!ReadSample {
        const test_source: *TestPasteSource = @ptrCast(@alignCast(raw_context));
        if (test_source.index == test_source.bytes.len) return test_source.ending;
        defer test_source.index += 1;
        return .{ .byte = test_source.bytes[test_source.index] };
    }
};

test "paste retention failure discards through exact end marker" {
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("before");

    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var test_source: TestPasteSource = .{ .bytes = "x\x1b[201~tail" };
    try std.testing.expectError(
        error.OutOfMemory,
        collectPasteFrom(fixed.allocator(), &editor, test_source.source()),
    );
    try std.testing.expectEqual(@as(usize, 7), test_source.index);
    try std.testing.expectEqualStrings("before", editor.bytes());
}

test "paste failure while flushing CR at marker still drains exactly" {
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var test_source: TestPasteSource = .{ .bytes = "\r\x1b[201~tail" };
    try std.testing.expectError(
        error.OutOfMemory,
        collectPasteFrom(fixed.allocator(), &editor, test_source.source()),
    );
    try std.testing.expectEqual(@as(usize, 7), test_source.index);
    try std.testing.expectEqualStrings("", editor.bytes());
}

test "paste idle commits partial body and later marker remains raw input" {
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var test_source: TestPasteSource = .{ .bytes = "body\r\x1b[20" };
    try std.testing.expectEqual(
        PasteFinish.idle,
        try collectPasteFrom(std.testing.allocator, &editor, test_source.source()),
    );
    try std.testing.expectEqualStrings("body\n\x1b[20", editor.bytes());
    const later_marker = LineEditor.decodeEscape("[201~");
    try std.testing.expectEqual(LineEditor.EscapeAction.none, later_marker.action);
    try std.testing.expectEqual(@as(usize, 5), later_marker.consumed);
}

test "paste descriptor EOF commits partial body and reports EOF" {
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var test_source: TestPasteSource = .{
        .bytes = "partial",
        .ending = .eof,
    };
    try std.testing.expectEqual(
        PasteFinish.eof,
        try collectPasteFrom(std.testing.allocator, &editor, test_source.source()),
    );
    try std.testing.expectEqualStrings("partial", editor.bytes());
}

test "injected paste source inserts normalized body atomically" {
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("a");
    var test_source: TestPasteSource = .{ .bytes = "b\r\nc\x1b[201~tail" };
    try std.testing.expectEqual(
        PasteFinish.complete,
        try collectPasteFrom(std.testing.allocator, &editor, test_source.source()),
    );
    try std.testing.expectEqualStrings("ab\nc", editor.bytes());
    try std.testing.expectEqual(@as(usize, 10), test_source.index);
}

const TestSearchSource = struct {
    bytes: []const u8,
    index: usize = 0,
    ending: ReadSample = .eof,
    timeouts: usize = 0,

    fn source(test_source: *TestSearchSource) SearchByteSource {
        return .{ .context = test_source, .read_fn = TestSearchSource.read };
    }

    fn read(raw_context: *anyopaque, _: i32) anyerror!ReadSample {
        const test_source: *TestSearchSource = @ptrCast(@alignCast(raw_context));
        if (test_source.timeouts != 0) {
            test_source.timeouts -= 1;
            return .timeout;
        }
        if (test_source.index == test_source.bytes.len) return test_source.ending;
        defer test_source.index += 1;
        return .{ .byte = test_source.bytes[test_source.index] };
    }
};

fn makeSearchHistory(allocator: std.mem.Allocator) !PromptHistory {
    var history = PromptHistory.init(allocator);
    errdefer history.deinit();
    try history.seed("old alpha");
    try history.seed("middle alpha");
    try history.seed("new alpha\nsecond row");
    history.beginRead();
    return history;
}

fn testSearchInput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    history: *PromptHistory,
) RawLineInput {
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    return init(
        allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        writer,
        "> ",
        .{
            .history = history,
            .search_style_open = "<a>",
            .search_style_close = "</a>",
            .search_no_match_style_open = "<n>",
            .search_no_match_style_close = "</n>",
        },
    );
}

fn runSearchScript(
    script: []const u8,
    editor: *LineEditor,
    history: *PromptHistory,
    output: []u8,
) !SearchFinish {
    var writer = std.Io.Writer.fixed(output);
    var input = testSearchInput(std.testing.allocator, &writer, history);
    var source: TestSearchSource = .{ .bytes = script };
    return input.searchHistoryFrom(editor, history, source.source());
}

test "injected search scripts cover CR LF cancel escape and EOF outcomes" {
    const cases = [_]struct {
        script: []const u8,
        finish: SearchFinish,
        expected: []const u8,
        cursor: usize,
    }{
        .{ .script = "alpha\r", .finish = .submit, .expected = "new alpha\nsecond row", .cursor = 4 },
        .{ .script = "alpha\n", .finish = .editing, .expected = "new alpha\nsecond row", .cursor = 4 },
        .{ .script = "alpha\x03", .finish = .editing, .expected = "draft", .cursor = 2 },
        .{ .script = "alpha\x07", .finish = .editing, .expected = "draft", .cursor = 2 },
        .{ .script = "alpha\x1b", .finish = .editing, .expected = "new alpha\nsecond row", .cursor = 4 },
        .{ .script = "missing\r", .finish = .editing, .expected = "draft", .cursor = 2 },
        .{ .script = "", .finish = .eof, .expected = "draft", .cursor = 2 },
    };

    for (cases) |case| {
        var history = try makeSearchHistory(std.testing.allocator);
        defer history.deinit();
        var editor = LineEditor.init(std.testing.allocator, false);
        defer editor.deinit();
        try editor.setBufferAtCursor("draft", 2);
        var output: [8192]u8 = undefined;

        try std.testing.expectEqual(
            case.finish,
            try runSearchScript(case.script, &editor, &history, &output),
        );
        try std.testing.expectEqualStrings(case.expected, editor.bytes());
        try std.testing.expectEqual(case.cursor, editor.cursorOffset());
    }
}

test "injected search traverses both directions and retains typed UTF-8 sequences" {
    var history = try makeSearchHistory(std.testing.allocator);
    defer history.deinit();
    try history.seed("unicode café");
    history.beginRead();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var output: [16384]u8 = undefined;

    try std.testing.expectEqual(
        SearchFinish.editing,
        try runSearchScript("alpha\x12\x13\n", &editor, &history, &output),
    );
    try std.testing.expectEqualStrings("new alpha\nsecond row", editor.bytes());

    history.beginRead();
    try editor.setBuffer("draft");
    try std.testing.expectEqual(
        SearchFinish.editing,
        try runSearchScript("café\n", &editor, &history, &output),
    );
    try std.testing.expectEqualStrings("unicode café", editor.bytes());
}

test "injected search backspace recovers from no match and empty Ctrl-S searches forward" {
    var history = try makeSearchHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");
    var output: [16384]u8 = undefined;

    try std.testing.expectEqual(
        SearchFinish.editing,
        try runSearchScript("alphax\x7f\n", &editor, &history, &output),
    );
    try std.testing.expectEqualStrings("new alpha\nsecond row", editor.bytes());

    history.beginRead();
    try editor.setBuffer("draft");
    try std.testing.expectEqual(
        SearchFinish.editing,
        try runSearchScript("\x13alpha\n", &editor, &history, &output),
    );
    try std.testing.expectEqualStrings("old alpha", editor.bytes());
}

test "search escape consumer drains non-paste sequences and only paste begin continues" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("paste ab value");
    history.beginRead();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");
    var output: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testSearchInput(std.testing.allocator, &writer, &history);

    var non_paste: TestSearchSource = .{ .bytes = "\x1b[Ax" };
    try std.testing.expectEqual(
        SearchFinish.editing,
        try input.searchHistoryFrom(&editor, &history, non_paste.source()),
    );
    try std.testing.expectEqual(@as(usize, 3), non_paste.index);
    try std.testing.expectEqualStrings("draft", editor.bytes());

    history.beginRead();
    try editor.setBuffer("draft");
    var paste: TestSearchSource = .{
        .bytes = "\x1b[200~a\x00\x03\r\nb\x7f\x1b[201~\n",
    };
    try std.testing.expectEqual(
        SearchFinish.editing,
        try input.searchHistoryFrom(&editor, &history, paste.source()),
    );
    try std.testing.expectEqualStrings("paste ab value", editor.bytes());
    try std.testing.expectEqual(paste.bytes.len, paste.index);
}

test "search paste allocation failure drains through its marker" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try PromptSearch.init(std.testing.allocator, &editor, &history);
    defer search.deinit();
    var output: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var input = testSearchInput(fixed.allocator(), &writer, &history);
    var source: TestSearchSource = .{ .bytes = "body\x1b[201~tail" };

    try std.testing.expectError(
        error.OutOfMemory,
        input.appendSearchPaste(&search, &history, source.source()),
    );
    try std.testing.expectEqual(@as(usize, 10), source.index);
    try std.testing.expect(input.flush_input_on_cleanup);
    try std.testing.expectEqualStrings("", search.query.items);
}

test "search prompt is safe styled one-row output clipped from the left" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try PromptSearch.init(std.testing.allocator, &editor, &history);
    defer search.deinit();
    try search.query.appendSlice(std.testing.allocator, "bad\x1b\xff界tail");
    search.no_match = true;

    var sink: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&sink);
    const input = testSearchInput(std.testing.allocator, &writer, &history);
    var unstyled_input = input;
    unstyled_input.search_style_open = "";
    unstyled_input.search_style_close = "";
    unstyled_input.search_no_match_style_open = "";
    unstyled_input.search_no_match_style_close = "";
    const widths = [_]usize{ 1, 8, 20, 80 };
    for (widths) |columns| {
        var prompt = try unstyled_input.buildSearchPrompt(&search, columns);
        defer prompt.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.indexOfScalar(u8, prompt.items, '\n') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, prompt.items, 0x1b) == null);
        try std.testing.expect(EditLayout.promptWidth(prompt.items) <= @max(@as(usize, 1), columns -| 1));
    }

    search.query.clearRetainingCapacity();
    try search.query.appendSlice(std.testing.allocator, "needle");
    var wide = try input.buildSearchPrompt(&search, 80);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "<a>reverse-search · needle → </a><n>(no match)</n>",
        wide.items,
    );
    var one = try input.buildSearchPrompt(&search, 1);
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<n>…</n>", one.items);
}

fn searchAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = PromptHistory.init(allocator);
    defer history.deinit();
    try history.seed("history needle");
    history.beginRead();
    var editor = LineEditor.init(allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");
    var output: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testSearchInput(allocator, &writer, &history);
    var source: TestSearchSource = .{ .bytes = "needle\n" };
    _ = try input.searchHistoryFrom(&editor, &history, source.source());
}

test "all raw search allocations are leak-free" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        searchAllocationFailureCase,
        .{},
    );
}

test "search repaint uses column-zero continuation and never enters alternate screen" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("first\nsecond");
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var input = testSearchInput(std.testing.allocator, &writer, &history);
    input.columns = 80;
    input.rows = 24;
    input.geometry_valid = true;

    try input.repaint(&editor, .{ .prompt = "search → ", .continuation_column = 0 });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\r\nsecond") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?1049") == null);
}

test "cursor moves use bounded direct decimal encoding" {
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeCursorMove(&writer, 123, 'A');
    try writeCursorMove(&writer, 0, 'B');
    try writeCursorMove(&writer, 7, 'C');
    try std.testing.expectEqualStrings("\x1b[123A\x1b[7C", writer.buffered());
}

test "visible window clips to terminal rows and keeps cursor visible" {
    const layout: EditLayout.Layout = .{
        .cursor = .{ .row = 8, .column = 2 },
        .end = .{ .row = 9, .column = 3 },
        .total_rows = 10,
    };
    var window = visibleWindow(layout, 4, false);
    try std.testing.expectEqual(@as(usize, 5), window.start_row);
    try std.testing.expectEqual(@as(usize, 4), window.row_count);
    try std.testing.expectEqual(@as(usize, 3), window.cursor_row);

    window = visibleWindow(layout, 4, true);
    try std.testing.expectEqual(@as(usize, 6), window.start_row);
    try std.testing.expectEqual(@as(usize, 3), window.row_count);
    try std.testing.expectEqual(@as(usize, 2), window.cursor_row);
}

test "clipped paint sink emits only the selected visible rows" {
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context: ClippedPaintSink = .{
        .writer = &writer,
        .start_row = 2,
        .end_row = 4,
        .started = false,
    };
    _ = EditLayout.render("0\n1\n2\n3", 7, .{ .columns = 80 }, context.sink());
    try std.testing.expect(!context.failed);
    try std.testing.expectEqualStrings("2\r\n3", writer.buffered());
}

test "paint sink emits explicit CRLF and continuation indentation" {
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context: ClippedPaintSink = .{
        .writer = &writer,
        .start_row = 0,
        .end_row = 10,
        .started = true,
    };
    _ = EditLayout.render("ab\ncd", 5, .{
        .prompt_width = 2,
        .continuation_column = 2,
        .columns = 80,
    }, context.sink());
    try std.testing.expect(!context.failed);
    try std.testing.expectEqualStrings("ab\r\n  cd", writer.buffered());
}

test "submitted message replaces edit area with full styled transcript" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    var input = init(
        std.testing.allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{
            .submission_style_open = "<open>",
            .submission_style_close = "<close>",
        },
    );
    input.columns = 80;
    input.rows = 1;
    input.screen_cursor_row = 2;
    input.screen_rows = 3;
    input.geometry_valid = true;

    try input.renderSubmitted("ab\ncd");
    try std.testing.expectEqualStrings(
        sync_begin ++ "\x1b[2A\r<open>▌ ab<close>\x1b[K\r\n" ++
            "<open>▌ cd<close>\x1b[K\r\n\x1b[J" ++ sync_end,
        writer.buffered(),
    );
    try std.testing.expectEqual(@as(usize, 0), input.screen_cursor_row);
    try std.testing.expectEqual(@as(usize, 1), input.screen_rows);
    try std.testing.expect(!input.geometry_valid);
}

test "submitted message renders rows beyond the editor viewport" {
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    var input = init(
        std.testing.allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{},
    );
    input.columns = 80;
    input.rows = 1;

    try input.renderSubmitted("zero\none\ntwo");
    try std.testing.expectEqualStrings(
        sync_begin ++ "\r▌ zero\x1b[K\r\n▌ one\x1b[K\r\n" ++
            "▌ two\x1b[K\r\n\x1b[J" ++ sync_end,
        writer.buffered(),
    );
}

test "submitted rendering needs no allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    var input = init(
        failing.allocator(),
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{},
    );

    try input.renderSubmitted("owned elsewhere");
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "submit cleanup failure frees the transferred line" {
    var editor = LineEditor.init(std.testing.allocator, true);
    defer editor.deinit();
    try editor.setBuffer("owned");
    const rendered = sync_begin ++ "\r▌ owned\x1b[K\r\n\x1b[J" ++ sync_end;
    var output: [rendered.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    var input = init(
        std.testing.allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{},
    );
    input.active = true;
    try std.testing.expectError(error.WriteFailed, input.submitAndFinish(&editor));
    try std.testing.expectEqual(@as(usize, 0), editor.bytes().len);
}

test "empty submit finish failure frees retained editor allocation" {
    var editor = LineEditor.init(std.testing.allocator, true);
    defer editor.deinit();
    try editor.setBuffer("retained capacity");
    try editor.setBuffer("");
    var output: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&output);
    const invalid_file: std.Io.File = .{
        .handle = -1,
        .flags = .{ .nonblocking = false },
    };
    var input = init(
        std.testing.allocator,
        std.testing.io,
        invalid_file,
        invalid_file,
        &writer,
        "> ",
        .{ .empty_submit = true },
    );
    input.active = true;

    try std.testing.expectError(error.WriteFailed, input.submitAndFinish(&editor));
    try std.testing.expectEqual(@as(usize, 0), editor.bytes().len);
}

test "taking a submission transfers editor allocation" {
    var editor = LineEditor.init(std.testing.allocator, true);
    defer editor.deinit();
    try editor.setBuffer("hello");
    var result = takeSubmitted(&editor);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .submit => |line| try std.testing.expectEqualStrings("hello", line.bytes),
        .eof => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), editor.bytes().len);
}
