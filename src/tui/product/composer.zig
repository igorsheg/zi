const std = @import("std");
const wrap = @import("wrap.zig");

pub const buffer_size_bytes_max: usize = 16 * 1024;
pub const submit_size_bytes_max: usize = buffer_size_bytes_max;
pub const visible_rows_max: usize = 4;

pub const ComposerCommand = union(enum) {
    insert_utf8: []const u8,
    backspace,
    move_left,
    move_right,
    move_start,
    move_end,
    newline,
    clear,
    submit,
};

pub const ComposerBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    cursor_byte_index: usize = 0,
    revision: u64 = 0,
    projection_cache: ?ComposerProjectionCache = null,

    pub fn deinit(self: *ComposerBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ComposerBuffer) void {
        if (self.bytes.items.len == 0 and self.cursor_byte_index == 0) return;
        self.bytes.clearRetainingCapacity();
        self.cursor_byte_index = 0;
        self.bumpRevision();
    }

    pub fn text(self: ComposerBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn apply(self: *ComposerBuffer, allocator: std.mem.Allocator, command: ComposerCommand) !?[]u8 {
        switch (command) {
            .insert_utf8 => |bytes| try self.insertUtf8(allocator, bytes),
            .backspace => self.backspace(),
            .move_left => self.moveLeft(),
            .move_right => self.moveRight(),
            .move_start => self.moveStart(),
            .move_end => self.moveEnd(),
            .newline => try self.insertUtf8(allocator, "\n"),
            .clear => self.clear(),
            .submit => return try self.takeSubmit(allocator),
        }
        return null;
    }

    pub fn insertUtf8(self: *ComposerBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, bytes, '\r') == null) {
            try self.insertNormalized(allocator, bytes);
            return;
        }

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(allocator);
        try normalized.ensureTotalCapacity(allocator, bytes.len);
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            if (byte == '\r') {
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') index += 1;
                normalized.appendAssumeCapacity('\n');
            } else {
                normalized.appendAssumeCapacity(byte);
            }
        }
        try self.insertNormalized(allocator, normalized.items);
    }

    fn insertNormalized(self: *ComposerBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.bytes.items.len + bytes.len > buffer_size_bytes_max) return error.ComposerTooLarge;
        try self.bytes.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
        self.bumpRevision();
    }

    pub fn backspace(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        const start = wrap.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
        self.cursor_byte_index = start;
        self.bumpRevision();
    }

    pub fn moveLeft(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = wrap.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
        self.bumpRevision();
    }

    pub fn moveRight(self: *ComposerBuffer) void {
        if (self.cursor_byte_index >= self.bytes.items.len) return;
        self.cursor_byte_index = wrap.nextGraphemeEnd(self.bytes.items, self.cursor_byte_index);
        self.bumpRevision();
    }

    pub fn moveStart(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = 0;
        self.bumpRevision();
    }

    pub fn moveEnd(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == self.bytes.items.len) return;
        self.cursor_byte_index = self.bytes.items.len;
        self.bumpRevision();
    }

    pub fn visualRows(self: *ComposerBuffer, width: u16) usize {
        return self.cachedProjection(width).projection.total_rows;
    }

    pub fn visibleRows(
        self: *ComposerBuffer,
        width: u16,
        out: *[visible_rows_max]ComposerVisualRow,
    ) ComposerProjection {
        const cached = self.cachedProjection(width);
        @memcpy(
            out[0..cached.projection.visible_count],
            cached.rows[0..cached.projection.visible_count],
        );
        return cached.projection;
    }

    fn cachedProjection(self: *ComposerBuffer, width: u16) ComposerProjectionCache {
        if (self.projection_cache) |cache| {
            if (cache.revision == self.revision and cache.width == width) return cache;
        }
        var cache: ComposerProjectionCache = .{
            .revision = self.revision,
            .width = width,
            .rows = undefined,
            .projection = undefined,
        };
        cache.projection = projectVisualRows(self.*, width, &cache.rows);
        self.projection_cache = cache;
        return cache;
    }

    fn bumpRevision(self: *ComposerBuffer) void {
        std.debug.assert(self.revision < std.math.maxInt(u64));
        self.revision += 1;
        self.projection_cache = null;
    }

    pub fn takeSubmit(self: *ComposerBuffer, allocator: std.mem.Allocator) !?[]u8 {
        if (self.bytes.items.len == 0) return null;
        if (self.bytes.items.len > submit_size_bytes_max) return error.ComposerTooLarge;
        const trimmed = std.mem.trim(u8, self.bytes.items, " \t\n\r");
        if (trimmed.len == 0) {
            self.clear();
            return null;
        }
        const owned = try allocator.dupe(u8, trimmed);
        self.clear();
        return owned;
    }
};

pub const ComposerVisualRow = struct {
    text: []const u8,
};

const ComposerProjectionCache = struct {
    revision: u64,
    width: u16,
    projection: ComposerProjection,
    rows: [visible_rows_max]ComposerVisualRow,
};

pub const ComposerProjection = struct {
    first_visible_row: usize,
    visible_count: usize,
    total_rows: usize,
    cursor_visible: bool,
    cursor_visible_row: usize,
    cursor_display_col: usize,
};

fn projectVisualRows(
    composer: ComposerBuffer,
    width: u16,
    out: *[visible_rows_max]ComposerVisualRow,
) ComposerProjection {
    std.debug.assert(composer.cursor_byte_index <= composer.text().len);
    var builder: ComposerProjectionBuilder = .{ .out = out, .cursor_byte_index = composer.cursor_byte_index };
    builder.project(composer.text(), width);
    return builder.finish();
}

const CursorPosition = struct {
    row: usize = 0,
    col: usize = 0,
    found: bool = false,
};

const ComposerProjectionBuilder = struct {
    out: *[visible_rows_max]ComposerVisualRow,
    cursor_byte_index: usize,
    total_rows: usize = 0,
    cursor: CursorPosition = .{},

    fn project(self: *ComposerProjectionBuilder, bytes: []const u8, width: u16) void {
        if (bytes.len == 0) {
            self.cursor = .{ .row = 0, .col = 0, .found = true };
            self.emit(.{ .text = "" });
            return;
        }

        const wrap_width = @max(width, 1);
        var start: usize = 0;
        while (start < bytes.len) {
            const line = wrap.nextVisualLineBreak(bytes, start, wrap_width);
            if (line.next == start) break;
            self.captureCursor(bytes, line);
            self.emit(.{ .text = bytes[line.start..line.end] });
            start = line.next;
        }
        if (bytes[bytes.len - 1] == '\n') {
            if (self.cursor_byte_index == bytes.len) self.cursor = .{
                .row = self.total_rows,
                .col = 0,
                .found = true,
            };
            self.emit(.{ .text = "" });
        }
    }

    fn captureCursor(self: *ComposerProjectionBuilder, bytes: []const u8, line: wrap.VisualLineBreak) void {
        if (self.cursor.found) return;
        if (self.cursor_byte_index < line.start or self.cursor_byte_index > line.end) return;
        const col = if (self.cursor_byte_index == line.end)
            line.width
        else
            wrap.displayWidth(bytes[line.start..self.cursor_byte_index]);
        self.cursor = .{ .row = self.total_rows, .col = col, .found = true };
    }

    fn emit(self: *ComposerProjectionBuilder, row: ComposerVisualRow) void {
        self.out[self.total_rows % visible_rows_max] = row;
        self.total_rows += 1;
    }

    fn finish(self: *ComposerProjectionBuilder) ComposerProjection {
        if (!self.cursor.found) self.cursor = .{
            .row = if (self.total_rows == 0) 0 else self.total_rows - 1,
            .col = 0,
            .found = true,
        };
        const visible_count = @min(self.total_rows, visible_rows_max);
        const first_visible_row = self.total_rows - visible_count;
        self.rotateVisibleRows(first_visible_row, visible_count);
        const cursor_visible = self.cursor.row >= first_visible_row and
            self.cursor.row < first_visible_row + visible_count;
        return .{
            .first_visible_row = first_visible_row,
            .visible_count = visible_count,
            .total_rows = self.total_rows,
            .cursor_visible = cursor_visible,
            .cursor_visible_row = if (cursor_visible) self.cursor.row - first_visible_row else 0,
            .cursor_display_col = if (cursor_visible) self.cursor.col else 0,
        };
    }

    fn rotateVisibleRows(
        self: *ComposerProjectionBuilder,
        first_visible_row: usize,
        visible_count: usize,
    ) void {
        var ordered: [visible_rows_max]ComposerVisualRow = undefined;
        var index: usize = 0;
        while (index < visible_count) : (index += 1) {
            ordered[index] = self.out[(first_visible_row + index) % visible_rows_max];
        }
        @memcpy(self.out[0..visible_count], ordered[0..visible_count]);
    }
};

// Composer wrapping follows display rows, not physical newlines. This keeps the
// future editor contract honest: storage remains one UTF-8 buffer, while the
// render projection owns visual wrapping and tail selection.
// Composer projection is cached because status animations can render at 60 FPS
// while the editor text is unchanged. Mutations must invalidate the cache.
