const std = @import("std");
const agent = @import("../agent/root.zig");
const terminal = @import("../terminal/root.zig");
const text = @import("../text/root.zig");
const SelectionPicker = @import("SelectionPicker.zig");

pub const maximum_rows: usize = 200;
pub const maximum_label_cells: usize = 512;
pub const maximum_row_storage: usize = 1024 * 1024;

pub const Request = struct {
    title: []const u8,
    turns: []const agent.Session.TypedTurn,
};

pub const Outcome = union(enum) {
    canceled,
    selected: usize,
};

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, Request) anyerror!Outcome,

    pub fn run(self: Runner, request: Request) !Outcome {
        return self.run_fn(self.context, request);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("TurnPicker.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const ErasedAdapter = struct {
            fn run(context: *anyopaque, request: Request) anyerror!Outcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(request);
            }
        };
        return .{ .context = implementation, .run_fn = ErasedAdapter.run };
    }
};

/// Bounded adapter from typed turns to the shared terminal selection picker.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    picker: SelectionPicker.Runner,

    pub fn run(self: *Adapter, request: Request) !Outcome {
        if (request.turns.len == 0) return .canceled;
        const start = request.turns.len -| maximum_rows;
        const turns = request.turns[start..];
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const rows = try temporary.alloc(terminal.Picker.Item, turns.len);
        var used: usize = 0;
        for (turns, rows, 0..) |turn, *row, index| {
            const rows_after = turns.len - index - 1;
            const reserved_fallback = rows_after * "(empty)".len;
            const available = maximum_row_storage -| used -| reserved_fallback;
            const label = try makeLabel(temporary, turn.text, available);
            used += label.len;
            row.* = .{ .label = label };
        }
        const selected = try self.picker.run(request.title, rows, rows.len - 1) orelse return .canceled;
        if (selected >= rows.len) return .canceled;
        return .{ .selected = request.turns[start + selected].ordinal };
    }
};

fn makeLabel(allocator: std.mem.Allocator, input: []const u8, byte_limit: usize) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var offset: usize = 0;
    var cells: usize = 0;
    var pending_space = false;
    var clipped = false;
    while (offset < input.len) {
        const byte = input[offset];
        if (byte < 0x80 and (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte))) {
            pending_space = output.items.len != 0;
            offset += 1;
            continue;
        }
        const glyph = text.DisplayWidth.next(input, offset).?;
        offset += glyph.consumed;
        const space_bytes: usize = @intFromBool(pending_space);
        const space_cells: usize = space_bytes;
        if (space_cells + glyph.width > maximum_label_cells -| cells or
            space_bytes + glyph.bytes.len > byte_limit -| output.items.len)
        {
            clipped = true;
            break;
        }
        if (pending_space) {
            try output.append(allocator, ' ');
            cells += 1;
            pending_space = false;
        }
        try output.appendSlice(allocator, glyph.bytes);
        cells += glyph.width;
    }
    if (output.items.len == 0) {
        if (byte_limit < "(empty)".len) return error.OutOfMemory;
        return allocator.dupe(u8, "(empty)");
    }
    if (clipped and byte_limit >= "...".len) {
        const byte_cap = byte_limit - "...".len;
        const cell_cap = maximum_label_cells - "...".len;
        var scan: usize = 0;
        var retained: usize = 0;
        var retained_cells: usize = 0;
        while (scan < output.items.len) {
            const glyph = text.DisplayWidth.next(output.items, scan).?;
            if (scan + glyph.consumed > byte_cap or retained_cells + glyph.width > cell_cap) break;
            scan += glyph.consumed;
            retained = scan;
            retained_cells += glyph.width;
        }
        output.shrinkRetainingCapacity(retained);
        try output.appendSlice(allocator, "...");
    }
    return output.toOwnedSlice(allocator);
}

const CapturePicker = struct {
    selected: ?usize = null,
    expected_title: []const u8 = "title",
    labels: [maximum_rows][]const u8 = undefined,
    owned: std.ArrayList([]u8) = .empty,
    count: usize = 0,
    initial: usize = 0,

    fn deinit(self: *CapturePicker) void {
        for (self.owned.items) |label| std.testing.allocator.free(label);
        self.owned.deinit(std.testing.allocator);
        self.* = undefined;
    }

    pub fn run(
        self: *CapturePicker,
        title: []const u8,
        items: []const terminal.Picker.Item,
        initial_index: usize,
    ) !?usize {
        try std.testing.expectEqualStrings(self.expected_title, title);
        self.count = items.len;
        self.initial = initial_index;
        for (items, 0..) |item, index| {
            const copy = try std.testing.allocator.dupe(u8, item.label);
            errdefer std.testing.allocator.free(copy);
            try self.owned.append(std.testing.allocator, copy);
            self.labels[index] = copy;
        }
        return self.selected;
    }
};

fn typed(ordinal: usize, value: []const u8) agent.Session.TypedTurn {
    return .{ .ordinal = ordinal, .item_index = ordinal, .text = value };
}

test "maps capped newest rows back to original typed ordinals" {
    var turns: [maximum_rows + 2]agent.Session.TypedTurn = undefined;
    var text_buffer: [maximum_rows + 2][8]u8 = undefined;
    var lengths: [maximum_rows + 2]usize = undefined;
    for (&turns, &text_buffer, &lengths, 0..) |*turn, *buffer, *length, index| {
        const rendered = try std.fmt.bufPrint(buffer, "t{d}", .{index});
        length.* = rendered.len;
        turn.* = typed(index, buffer[0..length.*]);
    }
    var picker: CapturePicker = .{ .selected = 0 };
    defer picker.deinit();
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .picker = SelectionPicker.Runner.from(&picker) };
    const result = try adapter.run(.{ .title = "title", .turns = &turns });
    try std.testing.expectEqual(@as(usize, 2), result.selected);
    try std.testing.expectEqual(maximum_rows, picker.count);
    try std.testing.expectEqual(maximum_rows - 1, picker.initial);
}

test "labels flatten whitespace controls and handle malformed utf8" {
    const turns = [_]agent.Session.TypedTurn{typed(0, "  one\n\ttwo\x1b\xff  ")};
    var picker: CapturePicker = .{ .selected = 0 };
    defer picker.deinit();
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .picker = SelectionPicker.Runner.from(&picker) };
    _ = try adapter.run(.{ .title = "title", .turns = &turns });
    try std.testing.expectEqualStrings("one two ?", picker.labels[0]);
}

test "labels cap display cells with wide and combining glyphs" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..300) |_| try input.appendSlice(std.testing.allocator, "界e\xcc\x81");
    const turns = [_]agent.Session.TypedTurn{typed(0, input.items)};
    var picker: CapturePicker = .{ .selected = 0 };
    defer picker.deinit();
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .picker = SelectionPicker.Runner.from(&picker) };
    _ = try adapter.run(.{ .title = "title", .turns = &turns });
    try std.testing.expect(text.DisplayWidth.visibleWidth(picker.labels[0], 1000) <= maximum_label_cells);
    try std.testing.expect(std.mem.endsWith(u8, picker.labels[0], "..."));
}

test "empty labels use fallback and cancellation is preserved" {
    const turns = [_]agent.Session.TypedTurn{typed(7, " \n\t")};
    var picker: CapturePicker = .{ .selected = null };
    defer picker.deinit();
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .picker = SelectionPicker.Runner.from(&picker) };
    try std.testing.expect((try adapter.run(.{ .title = "title", .turns = &turns })) == .canceled);
    try std.testing.expectEqualStrings("(empty)", picker.labels[0]);
}

test "aggregate row storage remains bounded for combining-heavy rows" {
    const combining_count = maximum_row_storage / 2;
    const input = try std.testing.allocator.alloc(u8, combining_count * 2);
    defer std.testing.allocator.free(input);
    for (0..combining_count) |index| @memcpy(input[index * 2 ..][0..2], "\xcc\x81");
    var turns: [maximum_rows]agent.Session.TypedTurn = undefined;
    for (&turns, 0..) |*turn, index| turn.* = typed(index, input);
    var picker: CapturePicker = .{ .selected = 0 };
    defer picker.deinit();
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .picker = SelectionPicker.Runner.from(&picker) };
    _ = try adapter.run(.{ .title = "title", .turns = &turns });
    var total: usize = 0;
    for (picker.labels[0..picker.count]) |label| total += label.len;
    try std.testing.expect(total <= maximum_row_storage);
}
