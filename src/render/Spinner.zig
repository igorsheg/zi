const std = @import("std");
const text = @import("../text/root.zig");
const Theme = @import("Theme.zig");

const frame_interval_ms: u64 = 80;
const label_settle_ms: i64 = 2000;
const label_show_grace_ms: i64 = 300;
const default_label = "working...";
const default_key = "working";
const sync_begin = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
const erase_line = "\x1b[K";
const erase_below = "\x1b[J";
const reset = "\x1b[0m";
const maximum_rows: usize = 8;

const frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

pub const WidthSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque) usize,

    pub fn resolve(self: WidthSource) usize {
        return @max(1, self.resolve_fn(self.context));
    }

    pub fn from(implementation: anytype) WidthSource {
        const Pointer = @TypeOf(implementation);
        const Implementation = @typeInfo(Pointer).pointer.child;
        const Adapter = struct {
            fn resolve(context: *const anyopaque) usize {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

pub const Row = struct {
    bytes: []const u8,
    cells: usize,
};

pub const ToolFrame = struct {
    row_widths: [maximum_rows]usize = @splat(0),
    row_count: usize = 0,
};

const StoredRow = struct {
    bytes: ?[]u8 = null,
    cells: usize = 0,
};

const Mode = enum { hidden, label, tool_status };

pub const Spinner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    theme: Theme,
    width_source: WidthSource,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    mode: Mode = .hidden,
    stop_requested: bool = false,
    write_error: ?std.Io.Writer.Error = null,

    displayed_label: []u8,
    displayed_key: []u8,
    pending_label: ?[]u8 = null,
    pending_key: ?[]u8 = null,
    pending_since_ms: i64 = 0,
    contradicted_since_ms: i64 = 0,

    parked_rows: usize = 0,
    origin_col: usize = 0,
    swap_open: bool = false,
    label_show_pending: bool = false,
    label_show_at_ms: i64 = 0,
    pending_parked_rows: usize = 0,
    pending_origin_col: usize = 0,

    tool_rows: [maximum_rows]StoredRow = @splat(.{}),
    tool_row_count: usize = 0,
    tool_view_dirty: bool = false,
    painted_frame: ToolFrame = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        writer: *std.Io.Writer,
        theme: Theme,
        width_source: WidthSource,
    ) (error{OutOfMemory} || std.Thread.SpawnError)!*Spinner {
        const spinner = try allocator.create(Spinner);
        errdefer allocator.destroy(spinner);
        const label = try allocator.dupe(u8, default_label);
        errdefer allocator.free(label);
        const key = try allocator.dupe(u8, default_key);
        errdefer allocator.free(key);
        spinner.* = .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .theme = theme,
            .width_source = width_source,
            .thread = undefined,
            .displayed_label = label,
            .displayed_key = key,
        };
        spinner.thread = try std.Thread.spawn(.{}, threadMain, .{spinner});
        return spinner;
    }

    pub fn destroy(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        self.hideLocked();
        if (self.swap_open) {
            self.write(sync_end);
            self.swap_open = false;
        }
        self.stop_requested = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();

        self.allocator.free(self.displayed_label);
        self.allocator.free(self.displayed_key);
        self.clearPending();
        self.freeToolRows();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn show(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requestLabelShowLocked(0, 0);
    }

    pub fn park(self: *Spinner, cursor_col: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requestLabelShowLocked(if (cursor_col > 0) 2 else 1, cursor_col);
    }

    pub fn hide(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.hideLocked();
    }

    pub fn swapBegin(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.mode != .hidden) {
            self.write(sync_begin);
            self.swap_open = true;
        }
        self.hideLocked();
    }

    pub fn swapEnd(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.swap_open) return;
        self.write(sync_end);
        self.flush();
        self.swap_open = false;
    }

    pub fn setLabel(self: *Spinner, key: []const u8, label: []const u8) error{OutOfMemory}!void {
        const new_key = if (key.len == 0) default_key else key;
        const new_label = if (label.len == 0) default_label else label;
        const owned_key = try self.allocator.dupe(u8, new_key);
        errdefer self.allocator.free(owned_key);
        const owned_label = try self.allocator.dupe(u8, new_label);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearPending();
        self.contradicted_since_ms = 0;
        self.allocator.free(self.displayed_key);
        self.allocator.free(self.displayed_label);
        self.displayed_key = owned_key;
        self.displayed_label = owned_label;
        if (self.mode == .label) self.drawFrameLocked();
    }

    pub fn requestLabel(self: *Spinner, key: []const u8, label: []const u8) error{OutOfMemory}!void {
        const requested_key = if (key.len == 0) default_key else key;
        const requested_label = if (label.len == 0) default_label else label;
        self.mutex.lockUncancelable(self.io);
        const unchanged = (std.mem.eql(u8, self.displayed_key, requested_key) and
            std.mem.eql(u8, self.displayed_label, requested_label)) or
            (self.pending_key != null and self.pending_label != null and
                std.mem.eql(u8, self.pending_key.?, requested_key) and
                std.mem.eql(u8, self.pending_label.?, requested_label));
        self.mutex.unlock(self.io);
        if (unchanged) return;

        const owned_key = try self.allocator.dupe(u8, requested_key);
        errdefer self.allocator.free(owned_key);
        const owned_label = try self.allocator.dupe(u8, requested_label);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (std.mem.eql(u8, self.displayed_key, requested_key)) {
            self.clearPending();
            self.contradicted_since_ms = 0;
            self.allocator.free(self.displayed_label);
            self.displayed_label = owned_label;
            self.allocator.free(owned_key);
            if (self.mode == .label) self.drawFrameLocked();
        } else if (self.pending_key != null and std.mem.eql(u8, self.pending_key.?, requested_key)) {
            self.allocator.free(self.pending_label.?);
            self.pending_label = owned_label;
            self.allocator.free(owned_key);
        } else {
            self.clearPending();
            self.pending_key = owned_key;
            self.pending_label = owned_label;
            self.pending_since_ms = self.nowMs();
            if (self.contradicted_since_ms == 0) self.contradicted_since_ms = self.pending_since_ms;
        }
        self.wake.signal(self.io);
    }

    pub fn setToolStatusView(self: *Spinner, original_rows: []const Row) error{OutOfMemory}!void {
        if (original_rows.len == 0) return;
        const rows = original_rows[original_rows.len - @min(original_rows.len, maximum_rows) ..];
        var copies: [maximum_rows]?[]u8 = @splat(null);
        var copied: usize = 0;
        errdefer for (copies[0..copied]) |bytes| self.allocator.free(bytes.?);
        for (rows, 0..) |row, index| {
            copies[index] = try self.allocator.dupe(u8, row.bytes);
            copied += 1;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.freeToolRows();
        for (rows, 0..) |row, index| {
            self.tool_rows[index] = .{ .bytes = copies[index], .cells = row.cells };
            copies[index] = null;
        }
        self.tool_row_count = rows.len;
        self.tool_view_dirty = true;
        self.showLocked(.tool_status, 0, 0);
    }

    pub fn columns(self: *Spinner) usize {
        return self.width_source.resolve();
    }

    pub fn check(self: *Spinner) std.Io.Writer.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.write_error) |err| return err;
    }

    fn requestLabelShowLocked(self: *Spinner, parked_rows: usize, origin_col: usize) void {
        if (self.mode != .hidden or self.swap_open) {
            self.showLocked(.label, parked_rows, origin_col);
            return;
        }
        self.label_show_pending = true;
        self.label_show_at_ms = self.nowMs() + label_show_grace_ms;
        self.pending_parked_rows = parked_rows;
        self.pending_origin_col = origin_col;
        self.wake.signal(self.io);
    }

    fn showLocked(self: *Spinner, mode: Mode, parked_rows: usize, origin_col: usize) void {
        self.label_show_pending = false;
        self.settleLabelLocked();
        if (self.mode == mode and self.parked_rows == parked_rows and self.origin_col == origin_col) return;
        const synced = self.mode != .hidden;
        if (synced) {
            self.write(sync_begin);
            self.eraseLocked();
        }
        self.mode = mode;
        self.parked_rows = parked_rows;
        self.origin_col = origin_col;
        for (0..parked_rows) |_| self.write("\n");
        self.drawFrameLocked();
        if (synced) {
            self.write(sync_end);
            self.flush();
        }
        self.wake.signal(self.io);
    }

    fn hideLocked(self: *Spinner) void {
        self.label_show_pending = false;
        if (self.mode == .hidden) return;
        self.eraseLocked();
        self.mode = .hidden;
        self.parked_rows = 0;
        self.origin_col = 0;
        self.freeToolRows();
    }

    fn eraseLocked(self: *Spinner) void {
        if (self.painted_frame.row_count != 0) {
            const terminal_columns = self.width_source.resolve();
            const climb = physicalRows(
                self.painted_frame.row_widths[0 .. self.painted_frame.row_count - 1],
                terminal_columns,
            );
            const last_wraps = self.painted_frame.row_widths[self.painted_frame.row_count - 1] > terminal_columns;
            self.write("\r");
            self.writeCursorMove(climb, 'A');
            self.write(if (climb != 0 or last_wraps) erase_below else erase_line);
            self.painted_frame.row_count = 0;
            self.flush();
            return;
        }
        self.write("\r" ++ erase_line);
        self.writeCursorMove(self.parked_rows, 'A');
        if (self.origin_col != 0) self.writeCursorColumn(self.origin_col + 1);
        self.flush();
    }

    fn drawFrameLocked(self: *Spinner) void {
        const glyph = self.glyphNow();
        switch (self.mode) {
            .hidden => {},
            .label => self.drawLabelLocked(glyph),
            .tool_status => self.drawToolViewLocked(glyph),
        }
    }

    fn drawLabelLocked(self: *Spinner, glyph: []const u8) void {
        const terminal_columns = self.width_source.resolve();
        const budget = terminal_columns -| 3;
        const end = cellPrefixEnd(self.displayed_label, budget);
        self.write("\r\x1b[2m");
        self.write(glyph);
        self.write(" ");
        self.write(self.displayed_label[0..end]);
        self.write(reset ++ erase_line);
        self.flush();
    }

    fn drawToolViewLocked(self: *Spinner, glyph: []const u8) void {
        if (!self.tool_view_dirty and self.painted_frame.row_count != 0) {
            self.write("\r");
            self.write(self.theme.chrome_dim.open);
            self.write(glyph);
            self.write(reset);
            self.flush();
            return;
        }
        var rows: [maximum_rows]Row = undefined;
        for (self.tool_rows[0..self.tool_row_count], 0..) |stored, index| {
            rows[index] = .{ .bytes = stored.bytes.?, .cells = stored.cells };
        }
        buildToolFrame(
            self.writer,
            rows[0..self.tool_row_count],
            glyph,
            self.theme.chrome_dim.open,
            self.width_source.resolve(),
            if (self.painted_frame.row_count != 0) &self.painted_frame else null,
            &self.painted_frame,
        ) catch |err| self.recordWriteError(err);
        self.flush();
        self.tool_view_dirty = false;
    }

    fn settleLabelLocked(self: *Spinner) void {
        const now = self.nowMs();
        if (self.pending_key != null and now - self.pending_since_ms >= label_settle_ms) {
            self.allocator.free(self.displayed_label);
            self.allocator.free(self.displayed_key);
            self.displayed_label = self.pending_label.?;
            self.displayed_key = self.pending_key.?;
            self.pending_label = null;
            self.pending_key = null;
            self.contradicted_since_ms = 0;
            return;
        }
        if (self.contradicted_since_ms == 0 or now - self.contradicted_since_ms < label_settle_ms or
            std.mem.eql(u8, self.displayed_key, default_key)) return;
        const key = self.allocator.dupe(u8, default_key) catch return;
        const label = self.allocator.dupe(u8, default_label) catch {
            self.allocator.free(key);
            return;
        };
        self.allocator.free(self.displayed_key);
        self.allocator.free(self.displayed_label);
        self.displayed_key = key;
        self.displayed_label = label;
        self.contradicted_since_ms = 0;
        if (self.pending_key != null and std.mem.eql(u8, self.pending_key.?, default_key)) self.clearPending();
    }

    fn clearPending(self: *Spinner) void {
        if (self.pending_label) |bytes| self.allocator.free(bytes);
        if (self.pending_key) |bytes| self.allocator.free(bytes);
        self.pending_label = null;
        self.pending_key = null;
    }

    fn freeToolRows(self: *Spinner) void {
        for (self.tool_rows[0..self.tool_row_count]) |*row| {
            if (row.bytes) |bytes| self.allocator.free(bytes);
            row.* = .{};
        }
        self.tool_row_count = 0;
    }

    fn glyphNow(self: *Spinner) []const u8 {
        const now: usize = @intCast(@max(0, self.nowMs()));
        return frames[now / frame_interval_ms % frames.len];
    }

    fn nowMs(self: *Spinner) i64 {
        const nanoseconds = std.Io.Clock.awake.now(self.io).nanoseconds;
        return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
    }

    fn writeCursorMove(self: *Spinner, amount: usize, direction: u8) void {
        if (amount == 0) return;
        var buffer: [32]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, "\x1b[{d}{c}", .{ amount, direction }) catch return;
        self.write(bytes);
    }

    fn writeCursorColumn(self: *Spinner, column: usize) void {
        var buffer: [32]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, "\x1b[{d}G", .{column}) catch return;
        self.write(bytes);
    }

    fn write(self: *Spinner, bytes: []const u8) void {
        if (self.write_error != null or bytes.len == 0) return;
        self.writer.writeAll(bytes) catch |err| self.recordWriteError(err);
    }

    fn flush(self: *Spinner) void {
        if (self.write_error != null) return;
        self.writer.flush() catch |err| self.recordWriteError(err);
    }

    fn recordWriteError(self: *Spinner, err: std.Io.Writer.Error) void {
        if (self.write_error == null) self.write_error = err;
    }
};

fn threadMain(spinner: *Spinner) void {
    const all_signals = std.posix.sigfillset();
    var ignored_mask: std.posix.sigset_t = undefined;
    const mask_result = std.c.pthread_sigmask(
        @intCast(std.posix.SIG.BLOCK),
        &all_signals,
        &ignored_mask,
    );
    std.debug.assert(mask_result == 0);

    spinner.mutex.lockUncancelable(spinner.io);
    while (!spinner.stop_requested) {
        if (spinner.mode == .hidden and !spinner.label_show_pending) {
            spinner.wake.waitUncancelable(spinner.io, &spinner.mutex);
            continue;
        }
        if (spinner.mode == .hidden and spinner.label_show_pending and spinner.nowMs() >= spinner.label_show_at_ms) {
            spinner.showLocked(.label, spinner.pending_parked_rows, spinner.pending_origin_col);
            continue;
        }
        if (spinner.mode != .hidden) {
            spinner.settleLabelLocked();
            spinner.drawFrameLocked();
        }
        spinner.mutex.unlock(spinner.io);
        spinner.io.sleep(.fromMilliseconds(frame_interval_ms), .awake) catch |err| switch (err) {
            error.Canceled => {},
        };
        spinner.mutex.lockUncancelable(spinner.io);
    }
    spinner.mutex.unlock(spinner.io);
}

pub fn buildToolFrame(
    writer: *std.Io.Writer,
    rows: []const Row,
    glyph: []const u8,
    chrome_open: []const u8,
    terminal_columns: usize,
    previous: ?*const ToolFrame,
    painted: *ToolFrame,
) std.Io.Writer.Error!void {
    try writer.writeAll(sync_begin);
    if (previous) |frame| {
        const climb = physicalRows(frame.row_widths[0..frame.row_count -| 1], terminal_columns);
        if (climb != 0) try writer.print("\x1b[{d}A", .{climb});
    }
    try writer.writeByte('\r');
    painted.* = .{};
    for (rows, 0..) |row, index| {
        const last = index + 1 == rows.len;
        try writer.writeAll(row.bytes);
        if (painted.row_count < painted.row_widths.len) {
            painted.row_widths[painted.row_count] = row.cells;
            painted.row_count += 1;
        }
        try writer.writeAll(if (last) erase_below else erase_line ++ "\r\n");
    }
    try writer.writeByte('\r');
    try writer.writeAll(chrome_open);
    try writer.writeAll(glyph);
    try writer.writeAll(reset ++ sync_end);
}

fn physicalRows(widths: []const usize, columns: usize) usize {
    var rows: usize = 0;
    const safe_columns = @max(1, columns);
    for (widths) |width| rows +|= @max(1, (width + safe_columns - 1) / safe_columns);
    return rows;
}

fn cellPrefixEnd(bytes: []const u8, maximum_cells: usize) usize {
    var end: usize = 0;
    var cells: usize = 0;
    var iterator = text.DisplayWidth.iterator(bytes);
    while (iterator.next()) |glyph| {
        if (glyph.width > maximum_cells -| cells) break;
        end = iterator.offset;
        cells += glyph.width;
    }
    return end;
}

test "tool frame paints rows and accounts for previous reflow" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var painted: ToolFrame = .{};
    const rows = [_]Row{
        .{ .bytes = "<older>", .cells = 7 },
        .{ .bytes = "<newest>", .cells = 8 },
    };
    try buildToolFrame(&output.writer, &rows, "*", "<chrome>", 80, null, &painted);
    try std.testing.expectEqualStrings(
        sync_begin ++ "\r<older>" ++ erase_line ++ "\r\n<newest>" ++ erase_below ++
            "\r<chrome>*" ++ reset ++ sync_end,
        output.written(),
    );
    try std.testing.expectEqual(@as(usize, 2), painted.row_count);

    output.writer.end = 0;
    const previous: ToolFrame = .{ .row_widths = .{ 100, 10, 0, 0, 0, 0, 0, 0 }, .row_count = 2 };
    try buildToolFrame(&output.writer, rows[0..1], "*", "", 40, &previous, &painted);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[3A") != null);
}
