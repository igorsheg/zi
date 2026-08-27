const std = @import("std");

const DisplayWidth = @import("../text/DisplayWidth.zig");
const MarkdownOutput = @import("MarkdownOutput.zig");

const MarkdownTable = @This();

pub const Error = MarkdownOutput.Error;

pub const Step = enum {
    advanced,
    @"defer",
    pass,
};

pub const max_columns: usize = 32;
pub const max_rows: usize = 2048;
pub const max_source_bytes: usize = 64 * 1024;
pub const max_capture_bytes: usize = 8 * 1024 * 1024;

const column_separator_cells: usize = 3;
const ansi_bold = "\x1b[1m";
const ansi_bold_off = "\x1b[22m";
const ansi_dim = "\x1b[2m";
const glyph_bullet = "\xe2\x80\xa2";
const glyph_hline = "\xe2\x94\x80";
const glyph_vline = "\xe2\x94\x82";
const glyph_cross = "\xe2\x94\xbc";
const table_separator = " " ++ ansi_dim ++ glyph_vline ++ ansi_bold_off ++ " ";

/// Parser operations needed by the table collector. The implementation is
/// erased, but all calls remain synchronous and all byte slices are borrowed.
pub const Context = struct {
    context: *anyopaque,
    direct_sink: MarkdownOutput.Sink,
    emit_text_fn: *const fn (*anyopaque, []const u8) Error!void,
    emit_raw_fn: *const fn (*anyopaque, []const u8) Error!void,
    replay_raw_fn: *const fn (*anyopaque, []const u8) Error!void,
    open_bold_fn: *const fn (*anyopaque) Error!void,
    close_bold_fn: *const fn (*anyopaque) Error!void,
    render_inline_fn: *const fn (*anyopaque, []const u8, bool, MarkdownOutput.Sink) Error!void,
    commit_pending_fn: *const fn (*anyopaque) Error!void,
    row_reset_fn: *const fn (*anyopaque) Error!void,
    styled: bool,
    wrap_width: usize,

    pub fn emitText(self: Context, bytes: []const u8) Error!void {
        return self.emit_text_fn(self.context, bytes);
    }

    pub fn emitRaw(self: Context, bytes: []const u8) Error!void {
        return self.emit_raw_fn(self.context, bytes);
    }

    pub fn replayRaw(self: Context, bytes: []const u8) Error!void {
        return self.replay_raw_fn(self.context, bytes);
    }

    pub fn openBold(self: Context) Error!void {
        return self.open_bold_fn(self.context);
    }

    pub fn closeBold(self: Context) Error!void {
        return self.close_bold_fn(self.context);
    }

    pub fn renderInline(
        self: Context,
        bytes: []const u8,
        bold_base: bool,
        sink: MarkdownOutput.Sink,
    ) Error!void {
        return self.render_inline_fn(self.context, bytes, bold_base, sink);
    }

    pub fn commitPending(self: Context) Error!void {
        return self.commit_pending_fn(self.context);
    }

    pub fn rowReset(self: Context) Error!void {
        return self.row_reset_fn(self.context);
    }

    /// Construct a context from a single-item pointer whose public `table*`
    /// methods implement this interface. The direct sink is kept separate because
    /// aligned tables bypass the parser's wrapping layer.
    pub fn from(
        implementation: anytype,
        direct_sink: MarkdownOutput.Sink,
        styled: bool,
        wrap_width: usize,
    ) Context {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("MarkdownTable.Context.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emitText(context: *anyopaque, bytes: []const u8) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableEmitText(bytes);
            }

            fn emitRaw(context: *anyopaque, bytes: []const u8) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableEmitRaw(bytes);
            }

            fn replayRaw(context: *anyopaque, bytes: []const u8) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableReplayRaw(bytes);
            }

            fn openBold(context: *anyopaque) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableOpenBold();
            }

            fn closeBold(context: *anyopaque) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableCloseBold();
            }

            fn renderInline(
                context: *anyopaque,
                bytes: []const u8,
                bold_base: bool,
                sink: MarkdownOutput.Sink,
            ) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableRenderInline(bytes, bold_base, sink);
            }

            fn commitPending(context: *anyopaque) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableCommitPending();
            }

            fn rowReset(context: *anyopaque) Error!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tableRowReset();
            }
        };

        return .{
            .context = implementation,
            .direct_sink = direct_sink,
            .emit_text_fn = Adapter.emitText,
            .emit_raw_fn = Adapter.emitRaw,
            .replay_raw_fn = Adapter.replayRaw,
            .open_bold_fn = Adapter.openBold,
            .close_bold_fn = Adapter.closeBold,
            .render_inline_fn = Adapter.renderInline,
            .commit_pending_fn = Adapter.commitPending,
            .row_reset_fn = Adapter.rowReset,
            .styled = styled,
            .wrap_width = wrap_width,
        };
    }
};

allocator: std.mem.Allocator,
collecting: bool = false,
buffer: std.ArrayList(u8) = .empty,

pub fn init(allocator: std.mem.Allocator) MarkdownTable {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *MarkdownTable) void {
    self.buffer.deinit(self.allocator);
}

/// Reset the collection while retaining the source-buffer allocation.
pub fn reset(self: *MarkdownTable) void {
    self.collecting = false;
    self.buffer.clearRetainingCapacity();
}

pub fn isCollecting(self: *const MarkdownTable) bool {
    return self.collecting;
}

/// Probe two complete lines for a GFM header and delimiter row. A deferred
/// probe leaves the offset untouched because another feed may complete a line.
pub fn tryStart(self: *MarkdownTable, work: []const u8, offset: *usize) Error!Step {
    if (self.collecting) return .pass;

    const first_newline = findNewline(work, offset.*) orelse return .@"defer";
    const second_start = first_newline + 1;
    const second_newline = findNewline(work, second_start) orelse return .@"defer";
    const pair_end = second_newline + 1;
    const pair_len = pair_end - offset.*;
    if (pair_len > max_source_bytes) return .pass;

    if (!headerMatchesDelimiter(
        work[offset.*..first_newline],
        work[second_start..second_newline],
    )) return .pass;

    try self.appendSource(work[offset.*..pair_end]);
    self.collecting = true;
    offset.* = pair_end;
    return .advanced;
}

/// Consume one complete body row. A line which cannot belong to the table is
/// deliberately left unconsumed after the table has been finalized.
pub fn step(
    self: *MarkdownTable,
    context: Context,
    work: []const u8,
    offset: *usize,
) Error!Step {
    if (!self.collecting) return .pass;

    const newline = findNewline(work, offset.*) orelse return .@"defer";
    const line = work[offset.*..newline];
    var blank = true;
    var has_pipe = false;
    for (line) |byte| {
        if (!isTrimByte(byte)) blank = false;
        if (byte == '|') has_pipe = true;
    }

    const line_end = newline + 1;
    const line_len = line_end - offset.*;
    if (blank or !has_pipe or line_len > max_source_bytes -| self.buffer.items.len) {
        try self.finalize(context);
        return .pass;
    }

    try self.appendSource(work[offset.*..line_end]);
    offset.* = line_end;
    return .advanced;
}

/// Preserve a newline-less row once it grows beyond the retained-source cap.
/// The partial row is already parser-owned input, so it is emitted only after
/// the completed table prefix has been sent through the normal wrapped path.
pub fn bailPartial(self: *MarkdownTable, context: Context, partial: []const u8) Error!bool {
    if (!self.collecting or partial.len <= max_source_bytes) return false;

    const retained = self.buffer.items;
    self.emitAndResetPartial(context, retained, partial) catch |err| return err;
    return true;
}

/// Give a final incomplete row one chance to complete the table, including
/// the special case where the header and delimiter were both waiting in tail.
pub fn finish(
    self: *MarkdownTable,
    context: Context,
    tail: *std.ArrayList(u8),
) Error!void {
    if (!self.collecting and tail.items.len > 0 and tail.items[0] == '|') {
        if (try self.promoteEofHeader(tail)) {
            self.collecting = true;
        }
    }

    if (!self.collecting) return;

    var blank = true;
    var has_pipe = false;
    for (tail.items) |byte| {
        if (!isTrimByte(byte)) blank = false;
        if (byte == '|') has_pipe = true;
    }
    if (tail.items.len > 0 and !blank and has_pipe and
        tail.items.len <= max_source_bytes -| self.buffer.items.len -| 1)
    {
        try self.appendSourceLine(tail.items);
        tail.clearRetainingCapacity();
    }

    try self.finalize(context);
}

fn findNewline(bytes: []const u8, start: usize) ?usize {
    if (start > bytes.len) return null;
    return std.mem.indexOfScalarPos(u8, bytes, start, '\n');
}

fn emitAndResetPartial(
    self: *MarkdownTable,
    context: Context,
    retained: []const u8,
    partial: []const u8,
) Error!void {
    context.emitText(retained) catch |err| {
        self.reset();
        _ = context.rowReset() catch {};
        return err;
    };
    self.reset();
    context.emitText(partial) catch |err| {
        _ = context.rowReset() catch {};
        return err;
    };
    try context.rowReset();
}

fn appendSource(self: *MarkdownTable, bytes: []const u8) Error!void {
    if (bytes.len > max_source_bytes -| self.buffer.items.len) return error.OutputTooLarge;
    const new_len = self.buffer.items.len + bytes.len;
    try self.buffer.ensureTotalCapacityPrecise(self.allocator, new_len);
    self.buffer.appendSliceAssumeCapacity(bytes);
}

fn appendSourceLine(self: *MarkdownTable, bytes: []const u8) Error!void {
    const remaining = max_source_bytes -| self.buffer.items.len;
    if (remaining == 0) return error.OutputTooLarge;
    if (bytes.len >= remaining) return error.OutputTooLarge;
    const new_len = self.buffer.items.len + bytes.len + 1;
    try self.buffer.ensureTotalCapacityPrecise(self.allocator, new_len);
    self.buffer.appendSliceAssumeCapacity(bytes);
    self.buffer.appendAssumeCapacity('\n');
}

fn promoteEofHeader(self: *MarkdownTable, tail: *std.ArrayList(u8)) Error!bool {
    const newline = findNewline(tail.items, 0) orelse return false;
    if (tail.items.len >= max_source_bytes) return false;
    if (!headerMatchesDelimiter(tail.items[0..newline], tail.items[newline + 1 ..])) return false;

    try self.appendSourceLine(tail.items);
    tail.clearRetainingCapacity();
    return true;
}

fn headerMatchesDelimiter(header: []const u8, delimiter: []const u8) bool {
    var header_spans: [max_columns]Span = undefined;
    var delimiter_spans: [max_columns]Span = undefined;
    const header_count = splitRow(header, &header_spans);
    const delimiter_count = delimiterCount(delimiter, &delimiter_spans);
    return header_count >= 1 and header_count <= max_columns and
        delimiter_count == header_count;
}

fn delimiterCount(line: []const u8, spans: *[max_columns]Span) usize {
    const count = splitRow(line, spans);
    if (count < 1 or count > max_columns) return 0;

    for (spans[0..count]) |span| {
        var start = span.start;
        var end = span.end;
        if (start == end) return 0;
        if (line[start] == ':') start += 1;
        if (end > start and line[end - 1] == ':') end -= 1;
        if (start >= end) return 0;
        for (line[start..end]) |byte| {
            if (byte != '-') return 0;
        }
    }
    return count;
}

const Span = struct {
    start: usize,
    end: usize,
};

fn splitRow(line: []const u8, spans: *[max_columns]Span) usize {
    var start: usize = 0;
    var end: usize = line.len;
    while (start < end and isTrimByte(line[start])) start += 1;
    while (end > start and isTrimByte(line[end - 1])) end -= 1;

    if (start < end and line[start] == '|') start += 1;
    if (end > start and line[end - 1] == '|') end -= 1;

    var count: usize = 0;
    var cell_start = start;
    var index = start;
    while (true) {
        if (index == end or line[index] == '|') {
            var cell_end = index;
            while (cell_start < cell_end and isTrimByte(line[cell_start])) cell_start += 1;
            while (cell_end > cell_start and isTrimByte(line[cell_end - 1])) cell_end -= 1;
            if (count < spans.len) spans[count] = .{ .start = cell_start, .end = cell_end };
            count += 1;
            if (index == end) break;
            cell_start = index + 1;
        }
        index += 1;
    }
    return count;
}

fn isTrimByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn finalize(self: *MarkdownTable, context: Context) Error!void {
    const result = self.finalizeInner(context) catch |err| {
        self.reset();
        _ = context.rowReset() catch {};
        return err;
    };
    self.reset();
    try context.rowReset();
    return result;
}

fn finalizeInner(self: *MarkdownTable, context: Context) Error!void {
    try context.commitPending();

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const temporary = arena.allocator();

    var row_count: usize = 0;
    var row_start: usize = 0;
    for (self.buffer.items, 0..) |byte, index| {
        if (byte == '\n') {
            row_count += 1;
            if (row_count > max_rows) {
                try context.emitText(self.buffer.items);
                return;
            }
            row_start = index + 1;
        }
    }
    if (row_start != self.buffer.items.len) {
        try context.emitText(self.buffer.items);
        return;
    }
    if (row_count < 2) {
        try context.emitText(self.buffer.items);
        return;
    }

    const rows = try temporary.alloc(Row, row_count);
    var row_index: usize = 0;
    row_start = 0;
    for (self.buffer.items, 0..) |byte, index| {
        if (byte == '\n') {
            rows[row_index] = .{ .bytes = self.buffer.items[row_start..index] };
            row_index += 1;
            row_start = index + 1;
        }
    }

    var header_spans: [max_columns]Span = undefined;
    var delimiter_spans: [max_columns]Span = undefined;
    const columns = splitRow(rows[0].bytes, &header_spans);
    const delimiter_columns = delimiterCount(rows[1].bytes, &delimiter_spans);
    if (columns < 1 or columns > max_columns or delimiter_columns != columns) {
        try context.emitText(self.buffer.items);
        return;
    }

    const body_count = row_count - 2;
    for (rows[2..]) |row| {
        var body_spans: [max_columns]Span = undefined;
        if (splitRow(row.bytes, &body_spans) > columns) {
            try context.emitText(self.buffer.items);
            return;
        }
    }

    const total_cells = (body_count + 1) * columns;
    const grid = try temporary.alloc(Cell, total_cells);
    var capture_budget: usize = 0;

    for (0..columns) |column| {
        const span = header_spans[column];
        grid[column] = try renderCell(
            context,
            temporary,
            &capture_budget,
            rows[0].bytes[span.start..span.end],
            true,
        );
    }

    for (0..body_count) |body| {
        var body_spans: [max_columns]Span = undefined;
        const body_columns = splitRow(rows[body + 2].bytes, &body_spans);
        for (0..columns) |column| {
            const source = if (column < body_columns) blk: {
                const span = body_spans[column];
                break :blk rows[body + 2].bytes[span.start..span.end];
            } else "";
            grid[(body + 1) * columns + column] = try renderCell(
                context,
                temporary,
                &capture_budget,
                source,
                false,
            );
        }
    }

    var widths: [max_columns]usize = undefined;
    var total_width: usize = 0;
    for (0..columns) |column| {
        var width: usize = 1;
        for (0..body_count + 1) |row| {
            width = @max(width, grid[row * columns + column].width);
        }
        widths[column] = width;
        total_width = total_width +| width;
        if (column + 1 < columns) total_width = total_width +| column_separator_cells;
    }

    if (context.wrap_width == 0 or total_width <= context.wrap_width or body_count == 0) {
        try emitAligned(context, rows, grid, widths[0..columns], columns, body_count);
    } else {
        try emitReflowed(context, grid, columns, body_count);
    }
}

const Row = struct {
    bytes: []const u8,
};

const Cell = struct {
    bytes: []const u8,
    kinds: []const MarkdownOutput.Kind,
    width: usize,
};

const Capture = struct {
    allocator: std.mem.Allocator,
    budget: *usize,
    bytes: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(MarkdownOutput.Kind) = .empty,

    pub fn emit(self: *Capture, bytes: []const u8, kind: MarkdownOutput.Kind) Error!void {
        if (bytes.len > max_capture_bytes -| self.budget.*) return error.OutputTooLarge;
        const new_len = self.bytes.items.len + bytes.len;
        const new_kind_len = self.kinds.items.len + bytes.len;
        try self.bytes.ensureTotalCapacity(self.allocator, new_len);
        try self.kinds.ensureTotalCapacity(self.allocator, new_kind_len);
        self.bytes.appendSliceAssumeCapacity(bytes);
        self.kinds.appendNTimesAssumeCapacity(kind, bytes.len);
        self.budget.* += bytes.len;
    }
};

fn renderCell(
    context: Context,
    allocator: std.mem.Allocator,
    capture_budget: *usize,
    source: []const u8,
    bold_base: bool,
) Error!Cell {
    var capture: Capture = .{ .allocator = allocator, .budget = capture_budget };
    try context.renderInline(source, bold_base, MarkdownOutput.Sink.from(&capture));

    return .{
        .bytes = capture.bytes.items,
        .kinds = capture.kinds.items,
        .width = cellWidth(capture.bytes.items, capture.kinds.items),
    };
}

fn cellWidth(bytes: []const u8, kinds: []const MarkdownOutput.Kind) usize {
    var width: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const kind = kinds[start];
        var end = start + 1;
        while (end < bytes.len and kinds[end] == kind) end += 1;
        if (kind == .content) {
            width +|= DisplayWidth.visibleWidth(bytes[start..end], std.math.maxInt(usize));
        }
        start = end;
    }
    return width;
}

fn emitReflowed(
    context: Context,
    grid: []const Cell,
    columns: usize,
    body_count: usize,
) Error!void {
    for (0..body_count) |body| {
        const row = grid[(body + 1) * columns .. (body + 2) * columns];
        for (0..columns) |column| {
            if (column == 0) try emitWrappedBullet(context) else try context.emitText("  ");
            try context.openBold();
            try emitCellWrapped(context, &grid[column]);
            try context.closeBold();
            try context.emitText(": ");
            try emitCellWrapped(context, &row[column]);
            try context.emitText("\n");
        }
    }
}

fn emitWrappedBullet(context: Context) Error!void {
    try emitWrappedGeneratedRaw(context, ansi_dim);
    try context.emitText(glyph_bullet ++ " ");
    try emitWrappedGeneratedRaw(context, ansi_bold_off);
}

fn emitWrappedGeneratedRaw(context: Context, bytes: []const u8) Error!void {
    if (context.styled) try context.emitRaw(bytes);
}

fn emitCellWrapped(context: Context, cell: *const Cell) Error!void {
    var start: usize = 0;
    while (start < cell.bytes.len) {
        const kind = cell.kinds[start];
        var end = start + 1;
        while (end < cell.bytes.len and cell.kinds[end] == kind) end += 1;
        if (kind == .raw) {
            try context.replayRaw(cell.bytes[start..end]);
        } else {
            try context.emitText(cell.bytes[start..end]);
        }
        start = end;
    }
}

fn emitDirectText(context: Context, bytes: []const u8) Error!void {
    try context.direct_sink.emit(bytes, .content);
}

fn emitDirectGeneratedRaw(context: Context, bytes: []const u8) Error!void {
    if (context.styled) try context.direct_sink.emit(bytes, .raw);
}

fn emitDirectSpaces(context: Context, count: usize) Error!void {
    const spaces = "                                ";
    var remaining = count;
    while (remaining != 0) {
        const amount = @min(remaining, spaces.len);
        try emitDirectText(context, spaces[0..amount]);
        remaining -= amount;
    }
}

fn emitDirectGlyphs(context: Context, count: usize, glyph: []const u8) Error!void {
    var buffer: [96]u8 = undefined;
    var remaining = count;
    while (remaining != 0) {
        const amount = @min(remaining, 32);
        var used: usize = 0;
        for (0..amount) |_| {
            @memcpy(buffer[used..][0..glyph.len], glyph);
            used += glyph.len;
        }
        try emitDirectText(context, buffer[0..used]);
        remaining -= amount;
    }
}

fn emitCellDirect(
    context: Context,
    cell: *const Cell,
    column_width: usize,
    alignment: u8,
    bold: bool,
    last: bool,
) Error!void {
    const padding = column_width -| cell.width;
    var left: usize = 0;
    var right: usize = 0;
    switch (alignment) {
        'R' => left = padding,
        'C' => {
            left = padding / 2;
            right = padding - left;
        },
        else => right = padding,
    }
    try emitDirectSpaces(context, left);
    if (bold) try emitDirectGeneratedRaw(context, ansi_bold);
    try emitCellDirectBytes(context, cell);
    if (bold) try emitDirectGeneratedRaw(context, ansi_bold_off);
    if (!last) try emitDirectSpaces(context, right);
}

fn emitCellDirectBytes(context: Context, cell: *const Cell) Error!void {
    var start: usize = 0;
    while (start < cell.bytes.len) {
        const kind = cell.kinds[start];
        var end = start + 1;
        while (end < cell.bytes.len and cell.kinds[end] == kind) end += 1;
        try context.direct_sink.emit(cell.bytes[start..end], kind);
        start = end;
    }
}

fn emitColumnSeparator(context: Context) Error!void {
    try emitDirectText(context, " ");
    try emitDirectGeneratedRaw(context, ansi_dim);
    try emitDirectText(context, glyph_vline);
    try emitDirectGeneratedRaw(context, ansi_bold_off);
    try emitDirectText(context, " ");
}

fn emitRule(
    context: Context,
    widths: []const usize,
    columns: usize,
) Error!void {
    try emitDirectGeneratedRaw(context, ansi_dim);
    for (0..columns) |column| {
        try emitDirectGlyphs(context, widths[column], glyph_hline);
        if (column + 1 < columns) {
            try emitDirectGlyphs(context, 1, glyph_hline);
            try emitDirectText(context, glyph_cross);
            try emitDirectGlyphs(context, 1, glyph_hline);
        }
    }
    try emitDirectGeneratedRaw(context, ansi_bold_off);
}

fn alignmentFromDelimiter(line: []const u8, span: Span) u8 {
    const left_colon = span.start < span.end and line[span.start] == ':';
    const right_colon = span.end > span.start and line[span.end - 1] == ':';
    return if (left_colon and right_colon) 'C' else if (right_colon) 'R' else 'L';
}

fn emitAligned(
    context: Context,
    rows: []const Row,
    grid: []const Cell,
    widths: []const usize,
    columns: usize,
    body_count: usize,
) Error!void {
    var delimiter_spans: [max_columns]Span = undefined;
    _ = splitRow(rows[1].bytes, &delimiter_spans);
    var alignments: [max_columns]u8 = undefined;
    for (0..columns) |column| alignments[column] = alignmentFromDelimiter(rows[1].bytes, delimiter_spans[column]);

    for (0..columns) |column| {
        try emitCellDirect(context, &grid[column], widths[column], alignments[column], true, column + 1 == columns);
        if (column + 1 < columns) try emitColumnSeparator(context);
    }
    try emitDirectText(context, "\n");
    try emitRule(context, widths, columns);
    try emitDirectText(context, "\n");

    for (0..body_count) |body| {
        for (0..columns) |column| {
            try emitCellDirect(
                context,
                &grid[(body + 1) * columns + column],
                widths[column],
                alignments[column],
                false,
                column + 1 == columns,
            );
            if (column + 1 < columns) try emitColumnSeparator(context);
        }
        try emitDirectText(context, "\n");
    }
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    table: MarkdownTable,
    text: std.ArrayList(u8) = .empty,
    raw: std.ArrayList(u8) = .empty,
    wire: std.ArrayList(u8) = .empty,
    styled: bool = true,
    wrap_width: usize = 40,
    inline_bytewise: bool = false,
    commits: usize = 0,
    row_resets: usize = 0,

    fn init(allocator: std.mem.Allocator, wrap_width: usize) TestFixture {
        return .{
            .allocator = allocator,
            .table = MarkdownTable.init(allocator),
            .wrap_width = wrap_width,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.table.deinit();
        self.text.deinit(self.allocator);
        self.raw.deinit(self.allocator);
        self.wire.deinit(self.allocator);
    }

    fn clearOutput(self: *TestFixture) void {
        self.text.clearRetainingCapacity();
        self.raw.clearRetainingCapacity();
        self.wire.clearRetainingCapacity();
        self.commits = 0;
        self.row_resets = 0;
        self.inline_bytewise = false;
    }

    fn reset(self: *TestFixture, wrap_width: usize) void {
        self.table.reset();
        self.clearOutput();
        self.wrap_width = wrap_width;
        self.styled = true;
    }

    fn appendOutput(self: *TestFixture, bytes: []const u8, kind: MarkdownOutput.Kind) Error!void {
        const destination = if (kind == .raw) &self.raw else &self.text;
        try destination.appendSlice(self.allocator, bytes);
        try self.wire.appendSlice(self.allocator, bytes);
    }

    pub fn directEmit(
        erased: *anyopaque,
        bytes: []const u8,
        kind: MarkdownOutput.Kind,
    ) Error!void {
        const self: *TestFixture = @ptrCast(@alignCast(erased));
        try self.appendOutput(bytes, kind);
    }

    pub fn tableEmitText(self: *TestFixture, bytes: []const u8) Error!void {
        try self.appendOutput(bytes, .content);
    }

    pub fn tableEmitRaw(self: *TestFixture, bytes: []const u8) Error!void {
        if (self.styled) try self.appendOutput(bytes, .raw);
    }

    pub fn tableReplayRaw(self: *TestFixture, bytes: []const u8) Error!void {
        try self.tableEmitRaw(bytes);
    }

    pub fn tableOpenBold(self: *TestFixture) Error!void {
        try self.tableEmitRaw(ansi_bold);
    }

    pub fn tableCloseBold(self: *TestFixture) Error!void {
        try self.tableEmitRaw(ansi_bold_off);
    }

    pub fn tableRenderInline(
        self: *TestFixture,
        bytes: []const u8,
        bold_base: bool,
        sink: MarkdownOutput.Sink,
    ) Error!void {
        _ = bold_base;
        if (self.inline_bytewise) {
            for (bytes, 0..) |_, index| {
                try sink.emit(bytes[index .. index + 1], .content);
            }
        } else {
            try sink.emit(bytes, .content);
        }
    }

    pub fn tableCommitPending(self: *TestFixture) Error!void {
        self.commits += 1;
    }

    pub fn tableRowReset(self: *TestFixture) Error!void {
        self.row_resets += 1;
    }

    fn context(self: *TestFixture) Context {
        return Context.from(
            self,
            .{ .context = self, .emit_fn = directEmit },
            self.styled,
            self.wrap_width,
        );
    }

    fn renderTable(self: *TestFixture, input: []const u8) Error!void {
        var work: std.ArrayList(u8) = .empty;
        defer work.deinit(self.allocator);
        try work.appendSlice(self.allocator, input);

        var offset: usize = 0;
        const first = try self.table.tryStart(work.items, &offset);
        if (first == .@"defer") {
            try self.table.finish(self.context(), &work);
            return;
        }
        if (first != .advanced) return;

        while (offset < work.items.len) {
            switch (try self.table.step(self.context(), work.items, &offset)) {
                .advanced => {},
                .@"defer" => {
                    var tail: std.ArrayList(u8) = .empty;
                    defer tail.deinit(self.allocator);
                    try tail.appendSlice(self.allocator, work.items[offset..]);
                    try self.table.finish(self.context(), &tail);
                    break;
                },
                .pass => break,
            }
        }

        if (self.table.isCollecting()) {
            var tail: std.ArrayList(u8) = .empty;
            defer tail.deinit(self.allocator);
            try self.table.finish(self.context(), &tail);
        }
    }
};

test "collection leaves deferred and terminating rows unconsumed" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(std.testing.allocator);
    try work.appendSlice(std.testing.allocator, "| A |\n|---|\n| x |");

    var offset: usize = 0;
    try std.testing.expectEqual(Step.advanced, try fixture.table.tryStart(work.items, &offset));
    try std.testing.expectEqual(@as(usize, 12), offset);
    const before = offset;
    try std.testing.expectEqual(
        Step.@"defer",
        try fixture.table.step(fixture.context(), work.items, &offset),
    );
    try std.testing.expectEqual(before, offset);

    try work.appendSlice(std.testing.allocator, "\n");
    try std.testing.expectEqual(
        Step.advanced,
        try fixture.table.step(fixture.context(), work.items, &offset),
    );
    try std.testing.expectEqual(work.items.len, offset);

    try work.appendSlice(std.testing.allocator, "after\n");
    const terminating_offset = offset;
    try std.testing.expectEqual(
        Step.pass,
        try fixture.table.step(fixture.context(), work.items, &offset),
    );
    try std.testing.expectEqual(terminating_offset, offset);
    try std.testing.expect(!fixture.table.isCollecting());
    try std.testing.expectEqual(@as(usize, 1), fixture.commits);
    try std.testing.expectEqual(@as(usize, 1), fixture.row_resets);
    try std.testing.expectEqualStrings(
        ansi_bold ++ "A" ++ ansi_bold_off ++ "\n" ++ ansi_dim ++ glyph_hline ++ ansi_bold_off ++ "\n" ++ "x\n",
        fixture.wire.items,
    );
}

test "aligned layout preserves callback kinds" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    try fixture.renderTable("| Name | Age |\n|---|---|\n| Bob | 30 |\n| Alice | 7 |");
    try std.testing.expectEqualStrings(
        ansi_bold ++ "Name" ++ ansi_bold_off ++ " " ++ table_separator ++ ansi_bold ++ "Age" ++ ansi_bold_off ++
            "\n" ++ ansi_dim ++ glyph_hline ** 6 ++ glyph_cross ++ glyph_hline ** 4 ++ ansi_bold_off ++ "\n" ++
            "Bob  " ++ table_separator ++ "30\n" ++ "Alice" ++ table_separator ++ "7\n",
        fixture.wire.items,
    );
    const expected_raw = ansi_bold ++ ansi_bold_off ++ ansi_dim ++ ansi_bold_off ++ ansi_bold ++
        ansi_bold_off ++ ansi_dim ++ ansi_bold_off ++ ansi_dim ++ ansi_bold_off ++ ansi_dim ++ ansi_bold_off;
    try std.testing.expectEqualStrings(expected_raw, fixture.raw.items);
    try std.testing.expect(std.mem.indexOf(u8, fixture.text.items, "Alice") != null);
}

test "unstyled layout suppresses only generated sgr" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();
    fixture.styled = false;

    try fixture.renderTable("| A | B |\n|---|---|\n| 1 | 2 |");
    try std.testing.expectEqualStrings("", fixture.raw.items);
    try std.testing.expect(std.mem.indexOfScalar(u8, fixture.wire.items, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.wire.items, "A " ++ glyph_vline ++ " B") != null);
}

test "delimiter edge colons select left right and center alignment" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    try fixture.renderTable(
        "| L | R | C |\n|:--|--:|:-:|\n| aaaa | bbbb | cccc |\n| x | y | z |",
    );
    try std.testing.expectEqualStrings(
        ansi_bold ++ "L" ++ ansi_bold_off ++ "   " ++ table_separator ++ "   " ++ ansi_bold ++ "R" ++ ansi_bold_off ++
            table_separator ++ " " ++ ansi_bold ++ "C" ++ ansi_bold_off ++ "\n" ++ ansi_dim ++
            glyph_hline ** 5 ++ glyph_cross ++ glyph_hline ** 6 ++ glyph_cross ++ glyph_hline ** 5 ++ ansi_bold_off ++
            "\n" ++ "aaaa" ++ table_separator ++ "bbbb" ++ table_separator ++ "cccc\n" ++
            "x   " ++ table_separator ++ "   y" ++ table_separator ++ " z\n",
        fixture.wire.items,
    );
}

test "wide tables reflow as labeled records" {
    var fixture = TestFixture.init(std.testing.allocator, 20);
    defer fixture.deinit();

    try fixture.renderTable(
        "| Component | Role | Owner |\n|---|---|---|\n" ++
            "| parser | reads tokens | ann |\n| writer | emits bytes | bob |",
    );
    try std.testing.expectEqualStrings(
        ansi_dim ++ glyph_bullet ++ " " ++ ansi_bold_off ++ ansi_bold ++ "Component" ++ ansi_bold_off ++
            ": parser\n  " ++ ansi_bold ++ "Role" ++ ansi_bold_off ++ ": reads tokens\n  " ++ ansi_bold ++
            "Owner" ++ ansi_bold_off ++ ": ann\n" ++ ansi_dim ++ glyph_bullet ++ " " ++ ansi_bold_off ++
            ansi_bold ++ "Component" ++ ansi_bold_off ++ ": writer\n  " ++ ansi_bold ++ "Role" ++
            ansi_bold_off ++ ": emits bytes\n  " ++ ansi_bold ++ "Owner" ++ ansi_bold_off ++ ": bob\n",
        fixture.wire.items,
    );
}

test "invalid delimiters pass without consuming input" {
    const cases = [_][]const u8{
        "| a | b |\nplain prose\n",
        "| A | B |\n|---|---|---|\n",
        "| A | B |\n|:-:-|---|\n",
    };
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    for (cases) |input| {
        var work: std.ArrayList(u8) = .empty;
        defer work.deinit(std.testing.allocator);
        try work.appendSlice(std.testing.allocator, input);
        var offset: usize = 0;
        try std.testing.expectEqual(Step.pass, try fixture.table.tryStart(work.items, &offset));
        try std.testing.expectEqual(@as(usize, 0), offset);
        try std.testing.expect(!fixture.table.isCollecting());
        fixture.reset(40);
    }
}

test "eof completes final body row and retains header-only grid" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    try fixture.renderTable("| A | B |\n|---|---|\n| 1 | 2 |");
    try std.testing.expectEqualStrings(
        ansi_bold ++ "A" ++ ansi_bold_off ++ table_separator ++ ansi_bold ++ "B" ++ ansi_bold_off ++ "\n" ++
            ansi_dim ++ glyph_hline ** 2 ++ glyph_cross ++ glyph_hline ** 2 ++ ansi_bold_off ++ "\n" ++
            "1" ++ table_separator ++ "2\n",
        fixture.wire.items,
    );

    fixture.reset(5);
    try fixture.renderTable("| AB | CD |\n|---|---|");
    try std.testing.expectEqualStrings(
        ansi_bold ++ "AB" ++ ansi_bold_off ++ table_separator ++ ansi_bold ++ "CD" ++ ansi_bold_off ++ "\n" ++
            ansi_dim ++ glyph_hline ** 3 ++ glyph_cross ++ glyph_hline ** 3 ++ ansi_bold_off ++ "\n",
        fixture.wire.items,
    );
}

test "split utf8 callback chunks are measured after assembly" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();
    fixture.inline_bytewise = true;

    try fixture.renderTable("| X | Y |\n|---|---|\n| éé | z |");
    try std.testing.expectEqualStrings(
        ansi_bold ++ "X" ++ ansi_bold_off ++ "  " ++ ansi_dim ++ glyph_vline ++ ansi_bold_off ++ " " ++
            ansi_bold ++ "Y" ++ ansi_bold_off ++ "\n" ++ ansi_dim ++ glyph_hline ** 3 ++ glyph_cross ++
            glyph_hline ** 2 ++ ansi_bold_off ++ "\néé" ++ table_separator ++ "z\n",
        fixture.wire.items,
    );
}

test "literal and escaped pipes use lossless fallback" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    const literal = "| Cmd | Meaning |\n|---|---|\n| `ls | wc` | count lines |\n";
    try fixture.renderTable(literal);
    try std.testing.expectEqualStrings(literal, fixture.wire.items);
    try std.testing.expectEqualStrings("", fixture.raw.items);

    fixture.reset(40);
    const escaped = "| Expr | Meaning |\n|---|---|\n| a \\| b | union |\n";
    try fixture.renderTable(escaped);
    try std.testing.expectEqualStrings(escaped, fixture.wire.items);
}

test "row span overflow falls back without dropping the tail" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "| H |\n|---|\n");
    for (0..2100) |row| {
        var line: [32]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&line, "| r{} |\n", .{row});
        try input.appendSlice(std.testing.allocator, rendered);
    }

    try fixture.renderTable(input.items);
    try std.testing.expect(std.mem.indexOf(u8, fixture.wire.items, "r0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixture.wire.items, "r2099") != null);
    try std.testing.expectEqualStrings("", fixture.raw.items);
}

test "oversized partial row bails losslessly" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(std.testing.allocator);
    const header = "| H |\n|---|\n";
    try work.appendSlice(std.testing.allocator, header);
    var offset: usize = 0;
    try std.testing.expectEqual(Step.advanced, try fixture.table.tryStart(work.items, &offset));

    const partial = try fixture.allocator.alloc(u8, max_source_bytes + 4464);
    defer fixture.allocator.free(partial);
    partial[0] = '|';
    partial[1] = ' ';
    @memset(partial[2 .. partial.len - 2], 'a');
    partial[partial.len - 2] = ' ';
    partial[partial.len - 1] = '|';
    try std.testing.expect(try fixture.table.bailPartial(fixture.context(), partial));
    try std.testing.expect(!fixture.table.isCollecting());
    try std.testing.expect(std.mem.startsWith(u8, fixture.wire.items, header));
    try std.testing.expect(std.mem.indexOf(u8, fixture.wire.items, "aaaaaaaaaaaaaaaaaaaa") != null);
}

test "oversized complete body row remains unconsumed" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "| H |\n|---|\n");
    const body_offset = input.items.len;
    try input.appendSlice(std.testing.allocator, "| ");
    try input.appendNTimes(std.testing.allocator, 'a', 70000);
    try input.appendSlice(std.testing.allocator, " |\n");

    var offset: usize = 0;
    try std.testing.expectEqual(Step.advanced, try fixture.table.tryStart(input.items, &offset));
    try std.testing.expectEqual(body_offset, offset);
    try std.testing.expectEqual(Step.pass, try fixture.table.step(fixture.context(), input.items, &offset));
    try std.testing.expectEqual(body_offset, offset);
    try std.testing.expect(!fixture.table.isCollecting());
    try std.testing.expect(std.mem.startsWith(u8, fixture.wire.items, ansi_bold));
}

test "oversized header pair passes before collection" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "| ");
    try input.appendNTimes(std.testing.allocator, 'H', 70000);
    try input.appendSlice(std.testing.allocator, " |\n|---|\n");

    var offset: usize = 0;
    try std.testing.expectEqual(Step.pass, try fixture.table.tryStart(input.items, &offset));
    try std.testing.expectEqual(@as(usize, 0), offset);
    try std.testing.expect(!fixture.table.isCollecting());
}

test "over-cap eof row remains in tail" {
    var fixture = TestFixture.init(std.testing.allocator, 40);
    defer fixture.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    const header = "| H |\n|---|\n";
    try input.appendSlice(std.testing.allocator, header);
    try input.appendSlice(std.testing.allocator, "| ");
    try input.appendNTimes(std.testing.allocator, 'a', 60000);
    try input.appendSlice(std.testing.allocator, " |\n");

    var offset: usize = 0;
    try std.testing.expectEqual(Step.advanced, try fixture.table.tryStart(input.items, &offset));
    try std.testing.expectEqual(Step.advanced, try fixture.table.step(fixture.context(), input.items, &offset));

    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(std.testing.allocator);
    try tail.appendSlice(std.testing.allocator, "| ");
    try tail.appendNTimes(std.testing.allocator, 'b', 10000);
    try tail.appendSlice(std.testing.allocator, " |");
    const tail_length = tail.items.len;
    try fixture.table.finish(fixture.context(), &tail);
    try std.testing.expectEqual(tail_length, tail.items.len);
    try std.testing.expect(std.mem.startsWith(u8, tail.items, "| bbbbbbbbbb"));
    try std.testing.expect(!fixture.table.isCollecting());
}
