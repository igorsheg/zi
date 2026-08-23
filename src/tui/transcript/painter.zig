// Adapted from fx's transcript block preparation and painter ownership.
// Licensed under Apache-2.0 and adapted to Zi's typed terminal surfaces.
const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const Store = @import("Store.zig");
const tool_group_projection = @import("tool_group_projection.zig");

const Style = terminal_render.Surface.Style;

pub const RowProvenance = union(enum) {
    entry: u32,
    block_separator,
    footer_boundary,
};

pub const PreparedRow = struct {
    provenance: RowProvenance,
    source: []const u8,
    style: Style,
};

pub const Projection = struct {
    rows: []const PreparedRow,
};

/// Rebuilds semantic transcript entries for the current width. No wrapping is
/// retained across frames, matching fx's paint-time reflow contract.
pub fn prepare(
    arena: std.mem.Allocator,
    store: *const Store.Store,
    columns: u16,
) !Projection {
    var rows: std.ArrayList(PreparedRow) = .empty;
    const entries = store.items();
    const tool_projection = try tool_group_projection.build(arena, entries);
    var previous_kind: ?Store.EntryClass = null;
    for (entries, tool_projection.actions) |entry, action| {
        const source = switch (action) {
            .keep => entry.textBytes() orelse return error.MissingEntryPresentation,
            .hide => continue,
            .override => |bytes| bytes,
        };
        const kind = entry.class();
        if (previous_kind) |previous| {
            try appendBlankRows(
                arena,
                &rows,
                transcript_blocks.default_block_gap_policy.gapBetween(previous, kind),
                .block_separator,
            );
        }
        if (kind == .user_turn) {
            const card = try user_message_card.build(arena, source, columns);
            for (card.rows) |row_source| try rows.append(arena, .{
                .provenance = .{ .entry = entry.id() },
                .source = row_source,
                .style = .{},
            });
        } else {
            try wrapEntryRows(arena, source, columns, entry.id(), &rows);
        }
        previous_kind = kind;
    }
    try appendBlankRows(
        arena,
        &rows,
        transcript_blocks.footerBoundaryGapRows(previous_kind),
        .footer_boundary,
    );
    return .{ .rows = try rows.toOwnedSlice(arena) };
}

pub fn paint(surface: *terminal_render.Surface, row: u16, prepared: PreparedRow) !void {
    if (prepared.provenance != .entry) return;
    try paintSourceRange(surface, row, prepared.source, prepared.style);
}

pub fn belongsToEntry(row: PreparedRow, entry_id: u32) bool {
    return switch (row.provenance) {
        .entry => |id| id == entry_id,
        .block_separator, .footer_boundary => false,
    };
}

fn appendBlankRows(
    arena: std.mem.Allocator,
    rows: *std.ArrayList(PreparedRow),
    count: u16,
    provenance: RowProvenance,
) !void {
    for (0..count) |_| try rows.append(arena, .{
        .provenance = provenance,
        .source = "",
        .style = .{},
    });
}

fn wrapEntryRows(
    arena: std.mem.Allocator,
    source: []const u8,
    columns: u16,
    entry_id: u32,
    rows: *std.ArrayList(PreparedRow),
) !void {
    var line_start: usize = 0;
    while (line_start < source.len) {
        const newline = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        try wrapLine(arena, source, line_start, newline, columns, entry_id, rows);
        line_start = newline + 1;
    }
}

fn wrapLine(
    arena: std.mem.Allocator,
    source: []const u8,
    start_byte: usize,
    end_byte: usize,
    columns: u16,
    entry_id: u32,
    rows: *std.ArrayList(PreparedRow),
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
                .provenance = .{ .entry = entry_id },
                .source = source[row_start .. start_byte + index],
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
        .provenance = .{ .entry = entry_id },
        .source = source[row_start..end_byte],
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

test "painter preserves semantic provenance and connected user rails" {
    var store = Store.Store.init(std.testing.allocator, 1024);
    defer store.deinit();
    _ = try store.appendSealed(.user_turn, "hello world");
    _ = try store.appendSealed(.assistant_turn, "answer\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const projection = try prepare(arena.allocator(), &store, 8);
    try std.testing.expect(projection.rows.len >= 4);
    try std.testing.expect(projection.rows[0].provenance == .entry);
    try std.testing.expect(std.mem.find(u8, projection.rows[0].source, "┃") != null);
    try std.testing.expect(projection.rows[2].provenance == .block_separator);
    try std.testing.expect(projection.rows[projection.rows.len - 1].provenance == .footer_boundary);
}
