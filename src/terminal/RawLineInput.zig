const std = @import("std");
const builtin = @import("builtin");
const RawLineInput = @This();
const LineEditor = @import("LineEditor.zig");
const EditLayout = @import("EditLayout.zig");
const DisplayColumns = @import("DisplayColumns.zig");
const Size = @import("Size.zig");
const PosixMode = @import("PosixMode.zig");
const CookedLineInput = @import("CookedLineInput.zig");

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
mode: PosixMode,
screen_cursor_row: usize = 0,
screen_rows: usize = 1,
columns: usize = 80,
rows: usize = 24,
geometry_valid: bool = false,
paste_enabled: bool = false,
flush_input_on_cleanup: bool = false,
active: bool = false,

pub const Options = struct {
    empty_submit: bool = false,
    /// Borrowed terminal bytes. The caller keeps them valid for the input's lifetime.
    submission_style_open: []const u8 = "",
    submission_style_close: []const u8 = "",
    display_columns: DisplayColumns.Policy = .terminal,
};

/// The files and writer remain owned by the caller. `prompt` and submission style bytes are borrowed.
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
        .mode = PosixMode.init(stdin),
    };
}

/// Controls whether bare Enter can submit an empty line for a resumable turn.
pub fn setEmptySubmit(input: *RawLineInput, enabled: bool) void {
    input.empty_submit = enabled;
}

/// Reads directly from the stdin descriptor. A submitted result owns its bytes.
/// EOF owns no storage. All terminal state is restored before this function returns.
pub fn read(input: *RawLineInput) !Result {
    var editor = LineEditor.init(input.allocator, input.empty_submit);
    defer editor.deinit();

    try input.enter();
    errdefer input.cleanupIgnoringErrors();
    try input.repaint(&editor, false, false);

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
                    try input.repaint(&editor, editor.exit_armed, false);
                continue;
            },
        };

        if (byte == 0x0c) {
            try input.repaint(&editor, editor.exit_armed, true);
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
            try editor.handleByte(byte);

        switch (outcome) {
            .none, .history_previous, .history_next => {
                if (was_armed and !editor.exit_armed)
                    try input.repaint(&editor, false, false);
            },
            .edited => try input.repaint(&editor, false, false),
            .exit_armed => try input.repaint(&editor, true, false),
            .paste_begin => switch (try input.collectPaste(&editor)) {
                .complete, .idle => try input.repaint(&editor, false, false),
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
            try input.repaint(editor, editor.exit_armed, false);
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
    try input.repaint(editor, editor.exit_armed, false);
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

    var sequence: [65]u8 = undefined;
    sequence[0] = first;
    var len: usize = 1;
    if (first == '[') {
        while (len < sequence.len) {
            const byte = switch (try input.readByte(50)) {
                .byte => |byte| byte,
                .timeout, .eof => break,
            };
            sequence[len] = byte;
            len += 1;
            if ((byte >= 0x40 and byte <= 0x7e) or byte < 0x20 or byte > 0x7e) break;
        }
    } else if (first == 'O') {
        switch (try input.readByte(50)) {
            .byte => |byte| {
                sequence[len] = byte;
                len += 1;
            },
            .timeout, .eof => {},
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
        // Up and Down are intentionally consumed without local history state.
        'A', 'B' => .none,
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

fn collectPasteFrom(
    collector_allocator: std.mem.Allocator,
    editor: *LineEditor,
    source: PasteByteSource,
) !PasteFinish {
    const remaining = max_prompt_bytes - editor.bytes().len;
    // Match hax: retain and commit the bounded prefix, but keep consuming through
    // the end marker so discarded paste bytes cannot become editor commands.
    var collector = LineEditor.PasteCollector.init(collector_allocator, remaining);
    defer collector.deinit();
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
                try editor.insert(collector.bytes());
                return if (sample == .timeout) .idle else .eof;
            },
        };
        const result: LineEditor.PasteCollector.FeedResult = collector.feed(&.{byte}) catch |err| result: {
            if (retention_error == null) retention_error = err;
            collector.max_bytes = collector.body.items.len;
            if (collector.marker_len == paste_end_marker_len) {
                // The complete marker was recognized before flushing a pending CR
                // failed. Discard that CR and commit the already consumed marker.
                collector.pending_cr = false;
                collector.complete = true;
                break :result LineEditor.PasteCollector.FeedResult{ .consumed = 1, .complete = true };
            }
            // The failed byte was not necessarily retained or classified. Replay it
            // after entering discard mode so a marker beginning here is not lost.
            break :result try collector.feed(&.{byte});
        };
        if (result.complete) break;
    }
    if (retention_error) |err| return err;
    try editor.insert(collector.bytes());
    return .complete;
}

const ReadSample = union(enum) {
    byte: u8,
    timeout,
    eof,
};

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

fn repaint(
    input: *RawLineInput,
    editor: *const LineEditor,
    show_notice: bool,
    clear_screen: bool,
) !void {
    const size = input.querySize();
    const geometry_changed = input.geometry_valid and
        (size.columns != input.columns or size.rows != input.rows);
    input.columns = size.columns;
    input.rows = size.rows;

    if (clear_screen) {
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

    const prompt_width = EditLayout.promptWidth(input.prompt);
    const layout = EditLayout.compute(editor.bytes(), editor.cursor, prompt_width, input.columns);
    const display_notice = show_notice and input.rows > 1;
    const window = visibleWindow(layout, input.rows, display_notice);
    if (window.start_row == 0) try input.writer.writeAll(input.prompt);

    var sink_context: ClippedPaintSink = .{
        .writer = input.writer,
        .start_row = window.start_row,
        .end_row = window.start_row + window.row_count,
        .started = window.start_row == 0,
    };
    _ = EditLayout.render(editor.bytes(), editor.cursor, .{
        .prompt_width = prompt_width,
        .continuation_column = prompt_width,
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

test "modified CSI actions are bounded and Up and Down stay inert" {
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_left, commonModifiedAction("[1;5D"));
    try std.testing.expectEqual(LineEditor.EscapeAction.move_word_right, commonModifiedAction("[1;5C"));
    try std.testing.expectEqual(LineEditor.EscapeAction.line_end, commonModifiedAction("[1;2F"));
    try std.testing.expectEqual(LineEditor.EscapeAction.none, commonModifiedAction("[1;2A"));
    try std.testing.expectEqual(LineEditor.EscapeAction.none, commonModifiedAction("[xD"));
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
