const std = @import("std");
const text = @import("../text/root.zig");
const DisplayColumns = @import("DisplayColumns.zig");
const LineEditor = @import("LineEditor.zig");
const PickerCore = @import("PickerCore.zig");
const PosixMode = @import("PosixMode.zig");
const Size = @import("Size.zig");

const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const cursor_hide = "\x1b[?25l";
const cursor_show = "\x1b[?25h";
const erase_line = "\x1b[K";
const erase_below = "\x1b[J";
const reset = "\x1b[0m";
const bold = "\x1b[1m";
const bold_off = "\x1b[22m";
const dim = "\x1b[2m";
const fg_default = "\x1b[39m";
const escape_timeout_ms: i32 = 50;
const maximum_rows: usize = 12;
const maximum_title_lines: usize = 3;
const maximum_footer_lines: usize = 4;
const maximum_frame_rows: usize = maximum_title_lines + maximum_rows + maximum_footer_lines + 4;

pub const Item = PickerCore.Item;
pub const Limits = PickerCore.Limits;

pub const Style = struct {
    accent_open: []const u8 = "\x1b[38;5;37m",
    accent_close: []const u8 = fg_default,
    ok_open: []const u8 = "\x1b[32m",
    ok_close: []const u8 = fg_default,
};

pub const Options = struct {
    title: ?[]const u8 = null,
    items: []const Item,
    empty_message: ?[]const u8 = null,
    initial_index: usize = 0,
    repeat_clipped_label: bool = false,
    display_columns: DisplayColumns.Policy = .auto,
    style: Style = .{},
    use_utf8: bool = true,
};

pub const Error = PickerCore.Core.Error || std.Io.Writer.Error || std.posix.TermiosSetError ||
    error{OutputTooLarge};

const Picker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout_fd: std.posix.fd_t,
    writer: *std.Io.Writer,
    options: Options,
    core: PickerCore.Core,
    title_lines: usize = 0,
    footer_lines: usize = 0,
    terminal_columns: usize = 0,
    terminal_rows: usize = 0,
    painted: bool = false,
    previous_row_count: usize = 0,
    previous_row_widths: [maximum_frame_rows]usize = @splat(0),

    fn contentColumns(self: *const Picker, physical_columns: usize) usize {
        return @max(@min(self.options.display_columns.resolve(physical_columns), physical_columns), 1);
    }

    fn layout(self: *Picker, size: Size) void {
        self.terminal_columns = size.columns;
        self.terminal_rows = size.rows;
        const columns = self.contentColumns(size.columns);
        self.title_lines = wrappedLineCount(self.options.title orelse "", columns, maximum_title_lines);
        const footer_columns = footerTextColumns(columns);
        self.footer_lines = 0;
        for (self.options.items) |item| {
            var lines = wrappedLineCount(item.description orelse "", footer_columns, maximum_footer_lines);
            if (self.options.repeat_clipped_label and PickerCore.textCells(item.label) >
                PickerCore.labelCells(item, columns))
            {
                lines += wrappedLineCount(item.label, footer_columns, maximum_footer_lines -| lines);
            }
            self.footer_lines = @max(self.footer_lines, lines);
        }
        var reserved_rows: usize = 3;
        if (self.title_lines != 0) reserved_rows += self.title_lines + 1;
        if (self.footer_lines != 0) reserved_rows += self.footer_lines + 1;
        self.core.setViewportRows(@min(@max(size.rows -| reserved_rows, 1), maximum_rows));
    }

    fn readByte(self: *Picker, timeout_ms: i32) !ReadSample {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return .timeout;
        var byte: [1]u8 = undefined;
        const count = try std.posix.read(self.stdin.handle, &byte);
        return if (count == 0) .eof else .{ .byte = byte[0] };
    }

    fn processByte(self: *Picker, byte: u8) error{OutOfMemory}!InputResult {
        switch (byte) {
            0x03, 0x07 => return .cancel,
            '\r', '\n' => return if (self.core.match_count == 0) .continue_running else .accept,
            0x7f, 0x08 => self.core.backspaceQuery(),
            0x15 => self.core.clearQuery(),
            0x0e => self.core.moveSelection(.next),
            0x10 => self.core.moveSelection(.previous),
            0x1b => return self.processEscape(),
            else => {
                if (byte < 0x20) return .continue_running;
                var sequence: [4]u8 = undefined;
                sequence[0] = byte;
                var length: usize = 1;
                const expected = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                while (length < expected) {
                    const next = self.readByte(escape_timeout_ms) catch break;
                    switch (next) {
                        .byte => |value| {
                            sequence[length] = value;
                            length += 1;
                        },
                        .timeout, .eof => break,
                    }
                }
                try self.core.appendQuery(sequence[0..length]);
            },
        }
        return .continue_running;
    }

    fn processEscape(self: *Picker) error{OutOfMemory}!InputResult {
        const first = self.readByte(escape_timeout_ms) catch return .cancel;
        const byte = switch (first) {
            .timeout, .eof => return .cancel,
            .byte => |value| value,
        };
        var sequence: [65]u8 = undefined;
        sequence[0] = byte;
        var length: usize = 1;
        if (byte == '[') {
            while (length < sequence.len) {
                const next = self.readByte(escape_timeout_ms) catch break;
                const value = switch (next) {
                    .timeout, .eof => break,
                    .byte => |next_byte| next_byte,
                };
                sequence[length] = value;
                length += 1;
                if ((value >= 0x40 and value <= 0x7e) or value < 0x20 or value > 0x7e) break;
            }
        } else if (byte == 'O') {
            const next = self.readByte(escape_timeout_ms) catch return .continue_running;
            if (next == .byte) {
                sequence[length] = next.byte;
                length += 1;
            }
        }
        applyAction(&self.core, LineEditor.decodeEscape(sequence[0..length]).action);
        return .continue_running;
    }

    fn paint(self: *Picker) Error!void {
        const size = Size.query(self.stdout_fd);
        if (size.columns != self.terminal_columns or size.rows != self.terminal_rows) self.layout(size);
        const columns = self.contentColumns(size.columns);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var frame: Frame = .{
            .writer = &output.writer,
            .columns = columns,
            .use_utf8 = self.options.use_utf8,
        };
        try frame.writer.writeAll(sync_begin);
        const climb = reflowClimb(self, size);
        if (climb != 0) try frame.writer.print("\x1b[{d}A", .{climb});
        if (self.painted) try frame.writer.writeByte('\r');
        if (self.title_lines != 0) try renderTitle(&frame, self.options.title.?, self.title_lines);
        try renderSearch(&frame, self);
        try frame.emit();
        var selected_label_clipped = false;
        if (self.core.match_count == 0) {
            try frame.row.writeAll(dim ++ "  (no matches)" ++ bold_off);
            try frame.emit();
        } else {
            const first_hidden = @min(
                self.core.first_visible + self.core.viewport_rows,
                self.core.match_count,
            );
            for (self.core.first_visible..first_hidden) |match_index| {
                try renderRow(
                    &frame,
                    self,
                    match_index,
                    match_index == self.core.selection,
                    if (match_index == self.core.selection) &selected_label_clipped else null,
                );
                try frame.emit();
            }
        }
        try renderFooter(&frame, self, selected_label_clipped);
        try frame.writer.writeAll(erase_below ++ sync_end);
        if (output.writer.end > self.core.limits.max_frame_bytes) return error.OutputTooLarge;
        try self.writer.writeAll(output.written());
        try self.writer.flush();
        self.previous_row_widths = frame.row_widths;
        self.previous_row_count = frame.row_count;
        self.painted = true;
    }

    fn erase(self: *Picker) std.Io.Writer.Error!void {
        if (self.painted and self.previous_row_count != 0) {
            const size = Size.query(self.stdout_fd);
            const climb = reflowClimb(self, size);
            try self.writer.writeAll(sync_begin);
            if (climb != 0) try self.writer.print("\x1b[{d}A", .{climb});
            try self.writer.writeAll("\r" ++ erase_below ++ sync_end);
        }
        try self.writer.writeAll(cursor_show);
        try self.writer.flush();
    }
};

pub fn run( // ziglint-ignore: Z015
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout_fd: std.posix.fd_t,
    writer: *std.Io.Writer,
    options: Options,
    limits: Limits,
) Error!?usize {
    if (options.items.len == 0) {
        if (options.empty_message) |message| {
            try writer.writeAll(message);
            try writer.writeByte('\n');
            try writer.flush();
        }
        return null;
    }
    const core = try PickerCore.Core.init(allocator, .{
        .title = options.title,
        .items = options.items,
        .empty_message = options.empty_message,
        .initial_index = options.initial_index,
        .repeat_clipped_label = options.repeat_clipped_label,
    }, limits);
    var picker: Picker = .{
        .allocator = allocator,
        .io = io,
        .stdin = stdin,
        .stdout_fd = stdout_fd,
        .writer = writer,
        .options = options,
        .core = core,
    };
    defer picker.core.deinit();
    picker.layout(Size.query(stdout_fd));
    var mode = PosixMode.init(stdin);
    mode.apply(.prompt_edit) catch return null;
    var restored = false;
    defer if (!restored) mode.restore() catch {};

    try writer.writeAll(cursor_hide);
    try writer.flush();
    errdefer picker.erase() catch {};
    try picker.paint();
    var result: ?usize = null;
    while (true) {
        const sample = picker.readByte(-1) catch break;
        const byte = switch (sample) {
            .byte => |value| value,
            .timeout, .eof => break,
        };
        switch (try picker.processByte(byte)) {
            .continue_running => try picker.paint(),
            .cancel => break,
            .accept => {
                result = picker.core.selectedItemIndex();
                break;
            },
        }
    }
    try picker.erase();
    try mode.restore();
    restored = true;
    return result;
}

const ReadSample = union(enum) { byte: u8, timeout, eof };
const InputResult = enum { continue_running, accept, cancel };

fn applyAction(core: *PickerCore.Core, action: LineEditor.EscapeAction) void {
    switch (action) {
        .history_previous => core.moveSelection(.previous),
        .history_next => core.moveSelection(.next),
        .line_start => core.selectFirst(),
        .line_end => core.selectLast(),
        .page_up => core.pageSelection(.previous),
        .page_down => core.pageSelection(.next),
        else => {},
    }
}

const Frame = struct {
    writer: *std.Io.Writer,
    row_storage: [8192]u8 = undefined,
    row: std.Io.Writer = undefined,
    row_ready: bool = false,
    row_count: usize = 0,
    row_widths: [maximum_frame_rows]usize = @splat(0),
    columns: usize,
    use_utf8: bool,

    fn initRow(self: *Frame) void {
        if (!self.row_ready) {
            self.row = .fixed(&self.row_storage);
            self.row_ready = true;
        }
    }

    fn emit(self: *Frame) std.Io.Writer.Error!void {
        self.initRow();
        if (self.row_count != 0) try self.writer.writeAll("\r\n");
        const bytes = self.row.buffered();
        const cells = try appendClippedLine(self.writer, bytes, self.columns, self.use_utf8);
        if (self.row_count < self.row_widths.len) self.row_widths[self.row_count] = cells;
        self.row_count += 1;
        try self.writer.writeAll(erase_line);
        self.row = .fixed(&self.row_storage);
        self.row_ready = true;
    }
};

fn renderTitle(frame: *Frame, title: []const u8, line_count: usize) std.Io.Writer.Error!void {
    var remaining = title;
    for (0..line_count) |line| {
        frame.initRow();
        try frame.row.writeAll(bold);
        if (line + 1 == line_count) {
            try appendClippedText(&frame.row, remaining, frame.columns, frame.use_utf8);
        } else {
            const cut = wrapRowBytes(remaining, frame.columns);
            try appendSanitized(&frame.row, remaining[0..cut.bytes]);
            remaining = remaining[cut.bytes + cut.separator_bytes ..];
        }
        try frame.row.writeAll(bold_off);
        try frame.emit();
    }
    try frame.emit();
}

fn renderSearch(frame: *Frame, picker: *const Picker) std.Io.Writer.Error!void {
    frame.initRow();
    const icon = if (frame.use_utf8) "⌕ " else "/ ";
    const text_cells = frame.columns -| PickerCore.marker_cells;
    try frame.row.writeAll(dim);
    try frame.row.writeAll(icon);
    if (picker.core.query.items.len == 0) {
        var buffer: [64]u8 = undefined;
        const placeholder = std.fmt.bufPrint(&buffer, "type to search {d} item{s}", .{
            picker.options.items.len,
            if (picker.options.items.len == 1) "" else "s",
        }) catch "type to search";
        try appendClippedText(&frame.row, placeholder, text_cells, frame.use_utf8);
        try frame.row.writeAll(bold_off);
        return;
    }
    var count_buffer: [40]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d}/{d}", .{
        picker.core.match_count,
        picker.options.items.len,
    }) catch "";
    const show_count = text_cells >= count.len + 3;
    const query_cells = if (show_count) text_cells - count.len - 2 else text_cells;
    try frame.row.writeAll(bold_off);
    try appendClippedText(&frame.row, picker.core.query.items, query_cells, frame.use_utf8);
    if (show_count) {
        try frame.row.writeAll("  " ++ dim);
        try frame.row.writeAll(count);
        try frame.row.writeAll(bold_off);
    }
}

fn renderRow(
    frame: *Frame,
    picker: *const Picker,
    match_index: usize,
    selected: bool,
    label_clipped: ?*bool,
) std.Io.Writer.Error!void {
    frame.initRow();
    const item = picker.options.items[picker.core.matches[match_index]];
    const row_cells = @max(frame.columns -| PickerCore.marker_cells, 1);
    if (selected) try frame.row.writeAll(picker.options.style.accent_open);
    try frame.row.writeAll(if (selected) if (frame.use_utf8) "→ " else "> " else "  ");
    if (selected) try frame.row.writeAll(picker.options.style.accent_close);
    const label_cells = PickerCore.labelCells(item, frame.columns);
    if (label_clipped) |value| value.* = PickerCore.textCells(item.label) > label_cells;
    if (item.dim) try frame.row.writeAll(dim) else if (selected) try frame.row.writeAll(bold);
    if (!item.dim) if (item.label_color) |color| try frame.row.writeAll(color);
    try appendClippedText(&frame.row, item.label, label_cells, frame.use_utf8);
    if (!item.dim and item.label_color != null) try frame.row.writeAll(fg_default);
    if (item.dim or selected) try frame.row.writeAll(bold_off);
    const current_cells = if (item.current) PickerCore.current_tag_cells else 0;
    if (item.current) {
        try frame.row.writeAll("  ");
        try frame.row.writeAll(picker.options.style.ok_open);
        try frame.row.writeAll(if (frame.use_utf8) "✓ current" else "* current");
        try frame.row.writeAll(picker.options.style.ok_close);
    }
    if (item.detail) |detail| if (detail.len != 0) {
        const separator_cells = if (item.dim)
            PickerCore.dim_detail_separator_cells
        else
            PickerCore.detail_separator_cells;
        const detail_cells = row_cells -| current_cells -| label_cells -| separator_cells;
        try frame.row.writeAll(dim);
        try frame.row.writeAll(if (item.dim) if (frame.use_utf8) " – " else " - " else "  ");
        try appendClippedText(&frame.row, detail, detail_cells, frame.use_utf8);
        try frame.row.writeAll(bold_off);
    };
}

fn renderFooter(frame: *Frame, picker: *const Picker, label_clipped: bool) std.Io.Writer.Error!void {
    if (picker.footer_lines == 0) return;
    try frame.emit();
    const selected = if (picker.core.selectedItemIndex()) |index| picker.options.items[index] else null;
    var combined: std.Io.Writer.Allocating = .init(picker.allocator);
    defer combined.deinit();
    if (selected) |item| {
        if (item.description) |description| if (description.len != 0) {
            const retained = @min(description.len, picker.core.limits.max_frame_bytes);
            try combined.writer.writeAll(description[0..retained]);
        };
        if (picker.options.repeat_clipped_label and label_clipped and
            combined.writer.end < picker.core.limits.max_frame_bytes)
        {
            if (combined.writer.end != 0) try combined.writer.writeByte('\n');
            const remaining_budget = picker.core.limits.max_frame_bytes - combined.writer.end;
            try combined.writer.writeAll(item.label[0..@min(item.label.len, remaining_budget)]);
        }
    }
    var remaining = combined.written();
    const columns = footerTextColumns(frame.columns);
    for (0..picker.footer_lines) |line| {
        frame.initRow();
        if (remaining.len != 0) {
            try frame.row.writeAll(dim ++ "  ");
            if (line + 1 == picker.footer_lines) {
                try appendClippedText(&frame.row, remaining, columns, frame.use_utf8);
                remaining = "";
            } else {
                const cut = wrapRowBytes(remaining, columns);
                try appendSanitized(&frame.row, remaining[0..cut.bytes]);
                remaining = remaining[cut.bytes + cut.separator_bytes ..];
            }
            try frame.row.writeAll(bold_off);
        }
        try frame.emit();
    }
}

fn appendClippedText(
    writer: *std.Io.Writer,
    value: []const u8,
    maximum_cells: usize,
    use_utf8: bool,
) std.Io.Writer.Error!void {
    if (maximum_cells == 0) return;
    const line_end = std.mem.indexOfAny(u8, value, "\r\n") orelse value.len;
    const natural_cells = text.DisplayWidth.visibleWidth(value[0..line_end], std.math.maxInt(usize));
    const clipped = line_end < value.len or natural_cells > maximum_cells;
    const budget = if (clipped) maximum_cells -| 1 else maximum_cells;
    var glyphs = text.DisplayWidth.iterator(value[0..line_end]);
    var cells: usize = 0;
    while (glyphs.next()) |glyph| {
        if (glyph.width > budget -| cells) break;
        try writer.writeAll(glyph.bytes);
        cells += glyph.width;
    }
    if (clipped) try writer.writeAll(if (use_utf8) "…" else ".");
}

fn appendSanitized(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var glyphs = text.DisplayWidth.iterator(value);
    while (glyphs.next()) |glyph| try writer.writeAll(glyph.bytes);
}

fn appendClippedLine(
    writer: *std.Io.Writer,
    value: []const u8,
    maximum_cells: usize,
    use_utf8: bool,
) std.Io.Writer.Error!usize {
    var offset: usize = 0;
    var cells: usize = 0;
    while (offset < value.len) {
        if (value[offset] == 0x1b) {
            const end = ansiEnd(value, offset);
            try writer.writeAll(value[offset..end]);
            offset = end;
            continue;
        }
        const glyph = text.DisplayWidth.next(value, offset).?;
        if (glyph.width > maximum_cells -| cells) {
            if (cells < maximum_cells) {
                try writer.writeAll(if (use_utf8) "…" else ".");
                cells += 1;
            }
            try writer.writeAll(reset);
            return cells;
        }
        try writer.writeAll(glyph.bytes);
        cells += glyph.width;
        offset += glyph.consumed;
    }
    return cells;
}

fn ansiEnd(value: []const u8, start: usize) usize {
    var end = start + 1;
    if (end < value.len and value[end] == '[') {
        end += 1;
        while (end < value.len and !(value[end] >= 0x40 and value[end] <= 0x7e)) end += 1;
        if (end < value.len) end += 1;
    }
    return end;
}

const WrapCut = struct { bytes: usize, separator_bytes: usize };

fn wrapRowBytes(value: []const u8, columns: usize) WrapCut {
    if (value.len == 0) return .{ .bytes = 0, .separator_bytes = 0 };
    var glyphs = text.DisplayWidth.iterator(value);
    var cells: usize = 0;
    var last_space: ?usize = null;
    while (glyphs.next()) |glyph| {
        if (value[glyphs.offset - glyph.consumed] == '\n' or value[glyphs.offset - glyph.consumed] == '\r') {
            return .{ .bytes = glyphs.offset - glyph.consumed, .separator_bytes = glyph.consumed };
        }
        if (glyph.width > columns -| cells) {
            if (last_space) |space| return .{ .bytes = space, .separator_bytes = 1 };
            return .{ .bytes = glyphs.offset - glyph.consumed, .separator_bytes = 0 };
        }
        cells += glyph.width;
        if (glyph.is_ascii_space) last_space = glyphs.offset - 1;
    }
    return .{ .bytes = value.len, .separator_bytes = 0 };
}

fn wrappedLineCount(value: []const u8, columns: usize, maximum: usize) usize {
    if (value.len == 0 or maximum == 0) return 0;
    var remaining = value;
    var lines: usize = 0;
    while (remaining.len != 0 and lines < maximum) : (lines += 1) {
        const cut = wrapRowBytes(remaining, columns);
        const consumed = cut.bytes + cut.separator_bytes;
        if (consumed == 0) break;
        remaining = remaining[consumed..];
    }
    return @max(lines, 1);
}

fn footerTextColumns(terminal_columns: usize) usize {
    return @max(terminal_columns -| PickerCore.marker_cells -| 1, 8);
}

fn reflowClimb(picker: *const Picker, size: Size) usize {
    if (!picker.painted or picker.previous_row_count == 0 or size.columns == 0) return 0;
    var physical_rows: usize = 0;
    for (picker.previous_row_widths[0..@min(picker.previous_row_count, maximum_frame_rows)]) |width| {
        physical_rows += @max((width + size.columns - 1) / size.columns, 1);
    }
    return @min(physical_rows -| 1, size.rows -| 1);
}

test "frame rendering sanitizes controls and never enters alternate screen" {
    const items = [_]Item{.{
        .label = "safe\x1b[2Jgone",
        .detail = "3m ago",
        .description = "provider · model",
    }};
    const core = try PickerCore.Core.init(std.testing.allocator, .{ .items = &items }, .{});
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var picker: Picker = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdin = .{ .handle = -1, .flags = .{ .nonblocking = false } },
        .stdout_fd = -1,
        .writer = &output.writer,
        .options = .{ .title = "resume", .items = &items },
        .core = core,
    };
    defer picker.core.deinit();
    picker.layout(.{ .columns = 40, .rows = 12 });
    try picker.paint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "safe?[2Jgone") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[?1049") == null);
    try std.testing.expect(output.writer.end <= picker.core.limits.max_frame_bytes);
}

test "escape navigation actions reuse line editor decoding" {
    const items = [_]Item{ .{ .label = "one" }, .{ .label = "two" } };
    var core = try PickerCore.Core.init(std.testing.allocator, .{ .items = &items }, .{});
    defer core.deinit();
    applyAction(&core, LineEditor.decodeEscape("[B").action);
    try std.testing.expectEqual(@as(usize, 1), core.selection);
    applyAction(&core, LineEditor.decodeEscape("[H").action);
    try std.testing.expectEqual(@as(usize, 0), core.selection);
}

test "wrapping and footer dimensions are bounded" {
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("one two", 4, 3));
    try std.testing.expectEqual(@as(usize, 3), wrappedLineCount("a\nb\nc\nd", 8, 3));
    try std.testing.expectEqual(@as(usize, 8), footerTextColumns(1));
}
