const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const glyphs = @import("glyphs.zig");
const layout = @import("layout.zig");
const screen = @import("screen.zig");

pub const args_preview_bytes_max: usize = 2 * 1024;
pub const tool_body_bytes_max: usize = 64 * 1024;
pub const tail_line_count: usize = 5;
pub const tail_line_bytes_max: usize = 200;
pub const output_truncated_text = "[output truncated]";
pub const duration_tick_ms: u64 = 100;

const title_bytes_max: usize = 160;
const footer_bytes_max: usize = 256;

pub const Status = enum { pending, running, done, failed, aborted };

pub const Presentation = enum { generic, command, file, patch };
pub const BodyMode = enum { visible, hidden_on_success, summary_only };
pub const CollapseMode = enum { head, tail };
pub const LiveUpdates = enum { show_tail, suppress };

pub const Collapse = struct {
    mode: CollapseMode = .tail,
    lines_max: u8 = 5,
};

pub const ToolDisplay = struct {
    presentation: Presentation = .generic,
    body_mode: BodyMode = .visible,
    collapse: Collapse = .{},
    shows_duration: bool = false,
    live_updates: LiveUpdates = .suppress,
};

pub const default_tool_display: ToolDisplay = .{};

pub fn statusStyle(status: Status) screen.Style {
    return switch (status) {
        .pending => screen.text.muted,
        .running => screen.text.accent,
        .done => screen.text.success,
        .failed, .aborted => screen.text.error_,
    };
}

pub fn statusText(status: Status) []const u8 {
    return switch (status) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .failed => "error",
        .aborted => "aborted",
    };
}

pub const TailBuffer = struct {
    lines: [tail_line_count][tail_line_bytes_max]u8 = undefined,
    lens: [tail_line_count]usize = @splat(0),
    count: usize = 0,
    pending_carriage_return: bool = false,

    pub fn update(self: *TailBuffer, text: []const u8) void {
        for (text) |byte| {
            if (byte == '\r') {
                self.pending_carriage_return = true;
                continue;
            }
            if (self.pending_carriage_return) {
                self.pending_carriage_return = false;
                if (byte == '\n') {
                    self.newLine();
                    continue;
                }
                self.resetCurrentLine();
            }
            switch (byte) {
                '\n' => self.newLine(),
                '\t' => {
                    self.pushByte(' ');
                    self.pushByte(' ');
                },
                else => self.pushByte(byte),
            }
        }
    }

    pub fn line(self: *const TailBuffer, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        return self.lines[index][0..self.lens[index]];
    }

    pub fn isEmpty(self: *const TailBuffer) bool {
        return self.count == 0 or (self.count == 1 and self.lens[0] == 0);
    }

    fn ensureLine(self: *TailBuffer) void {
        if (self.count == 0) {
            self.count = 1;
            self.lens[0] = 0;
        }
    }

    fn pushByte(self: *TailBuffer, byte: u8) void {
        self.ensureLine();
        const index = self.count - 1;
        if (self.lens[index] == tail_line_bytes_max) {
            std.mem.copyForwards(u8, self.lines[index][0 .. tail_line_bytes_max - 1], self.lines[index][1..tail_line_bytes_max]);
            self.lens[index] -= 1;
        }
        self.lines[index][self.lens[index]] = byte;
        self.lens[index] += 1;
    }

    fn resetCurrentLine(self: *TailBuffer) void {
        self.ensureLine();
        self.lens[self.count - 1] = 0;
    }

    fn newLine(self: *TailBuffer) void {
        self.ensureLine();
        if (self.count < tail_line_count) {
            self.lens[self.count] = 0;
            self.count += 1;
            return;
        }
        for (1..tail_line_count) |index| {
            @memcpy(&self.lines[index - 1], &self.lines[index]);
            self.lens[index - 1] = self.lens[index];
        }
        self.lens[tail_line_count - 1] = 0;
    }
};

pub fn layoutTool(allocator: std.mem.Allocator, tool: anytype, width: u16, expanded: bool) ![]layout.Line {
    const rail = statusStyle(tool.status);
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 10);

    try appendTitleLine(allocator, &out, tool, width, expanded);

    const visible_body = toolBodyVisible(tool, expanded);
    if (visible_body) try appendToolPlainLine(allocator, &out, glyphs.tool_top_line, width, rail);
    if (visible_body) {
        if (tool.status == .running and !tool.tail.isEmpty()) {
            for (0..tool.tail.count) |index| try appendToolBodyText(allocator, &out, tool.tail.line(index), width, tool.display.presentation, rail);
        } else if (tool.body.items.len > 0) {
            if (expanded) {
                try appendToolBodyText(allocator, &out, tool.body.items, width, tool.display.presentation, rail);
            } else {
                const preview = collapsedBodyPreview(tool.body.items, tool.display.collapse);
                if (preview.omitted_lines > 0 and preview.omitted_before) {
                    const marker = try collapseHint(allocator, tool.display.collapse.mode, preview.omitted_lines);
                    try appendToolBodyTextStyled(allocator, &out, marker, width, tool.display.presentation, rail, screen.text.muted);
                }
                try appendToolBodyText(allocator, &out, preview.text, width, tool.display.presentation, rail);
                if (preview.omitted_lines > 0 and !preview.omitted_before) {
                    const marker = try collapseHint(allocator, tool.display.collapse.mode, preview.omitted_lines);
                    try appendToolBodyTextStyled(allocator, &out, marker, width, tool.display.presentation, rail, screen.text.muted);
                }
            }
        } else if (tool.body_truncated) {
            try appendToolBodyTextStyled(allocator, &out, output_truncated_text, width, tool.display.presentation, rail, screen.text.muted);
        }
        try appendToolPlainLine(allocator, &out, glyphs.tool_bottom_line, width, rail);
    }

    if (try toolFooterLine(allocator, tool)) |footer| try appendToolPlainLine(allocator, &out, footer, width, screen.text.muted);
    return out.toOwnedSlice(allocator);
}

pub fn appendTextContent(writer: *std.Io.Writer.Allocating, content: []const ai.ToolResultContent, max_bytes: usize, truncated: *bool) !void {
    for (content) |item| switch (item) {
        .text => |text| try appendBounded(writer, text.text, max_bytes, truncated),
        .image => |image| try appendBounded(writer, imageFallbackText(image.mime_type), max_bytes, truncated),
    };
}

pub fn appendBounded(writer: *std.Io.Writer.Allocating, text: []const u8, max_bytes: usize, truncated: *bool) !void {
    if (writer.written().len >= max_bytes) {
        truncated.* = true;
        return;
    }
    const remaining = max_bytes - writer.written().len;
    if (text.len <= remaining) {
        try writer.writer.writeAll(text);
        return;
    }
    try writer.writer.writeAll(agent.utf8Prefix(text, remaining));
    truncated.* = true;
}

fn appendTitleLine(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), tool: anytype, width: u16, expanded: bool) !void {
    const title = try toolTitleLine(allocator, tool, expanded);
    const clipped = screen.sliceForColumns(title, width);
    var line: layout.Line = .{};
    try appendTitleSegments(&line, clipped, tool.display.presentation);
    try out.append(allocator, line);
}

pub fn toolTitleLine(allocator: std.mem.Allocator, tool: anytype, expanded: bool) ![]const u8 {
    const title = if (!expanded and tool.compact_title.len > 0) tool.compact_title else tool.title;
    const base = if (title.len == 0) tool.name else title;
    return switch (tool.status) {
        .failed => std.fmt.allocPrint(allocator, "{s} (error)", .{screen.sliceForColumns(base, title_bytes_max - " (error)".len)}),
        .aborted => std.fmt.allocPrint(allocator, "{s} (aborted)", .{screen.sliceForColumns(base, title_bytes_max - " (aborted)".len)}),
        else => if (base.len <= title_bytes_max) base else screen.sliceForColumns(base, title_bytes_max),
    };
}

fn appendTitleSegments(line: *layout.Line, title: []const u8, presentation: Presentation) !void {
    if (title.len == 0) return;
    const first_space = std.mem.indexOfScalar(u8, title, ' ') orelse {
        try line.append(.{ .text = title, .style = screen.text.tool_title });
        return;
    };
    try addTitleSegment(line, title[0..first_space], if (presentation == .command) screen.text.bash_mode else screen.text.tool_title);
    try addTitleSegment(line, title[first_space .. first_space + 1], screen.text.muted);
    const rest = title[first_space + 1 ..];
    if (std.mem.endsWith(u8, title, " (ctrl+o to expand)")) {
        try addHintedTitleRest(line, rest);
    } else switch (presentation) {
        .file, .patch => try addFileTitleRest(line, rest),
        .command => try addCommandTitleRest(line, rest),
        .generic => try addTitleSegment(line, rest, screen.text.tool_title),
    }
}

fn addTitleSegment(line: *layout.Line, text: []const u8, style: screen.Style) !void {
    if (text.len == 0) return;
    try line.append(.{ .text = text, .style = style });
}

fn addHintedTitleRest(line: *layout.Line, rest: []const u8) !void {
    const hint = " (ctrl+o to expand)";
    const body = rest[0 .. rest.len - hint.len];
    try addFileTitleRest(line, body);
    try addTitleSegment(line, hint, screen.text.muted);
}

fn addFileTitleRest(line: *layout.Line, rest: []const u8) !void {
    if (lineRangeStart(rest)) |range_start| {
        try addTitleSegment(line, rest[0..range_start], screen.text.tool_title);
        try addTitleSegment(line, rest[range_start..], screen.text.warning);
    } else {
        try addTitleSegment(line, rest, screen.text.tool_title);
    }
}

fn addCommandTitleRest(line: *layout.Line, rest: []const u8) !void {
    const timeout = " (timeout ";
    if (std.mem.lastIndexOf(u8, rest, timeout)) |index| {
        try addTitleSegment(line, rest[0..index], screen.text.bash_mode);
        try addTitleSegment(line, rest[index..], screen.text.muted);
    } else {
        try addTitleSegment(line, rest, screen.text.bash_mode);
    }
}

fn lineRangeStart(text: []const u8) ?usize {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    if (colon + 1 >= text.len or !std.ascii.isDigit(text[colon + 1])) return null;
    for (text[colon + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '-') return null;
    }
    return colon;
}

fn toolBodyVisible(tool: anytype, expanded: bool) bool {
    const has_body = (tool.status == .running and !tool.tail.isEmpty()) or tool.body.items.len > 0 or tool.body_truncated;
    if (!has_body) return false;
    return switch (tool.display.body_mode) {
        .visible, .summary_only => true,
        .hidden_on_success => expanded or tool.status != .done,
    };
}

fn appendToolPlainLine(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), text: []const u8, width: u16, style: screen.Style) !void {
    try layout.appendPlainLine(allocator, out, text, width, style);
}

fn appendToolBodyText(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), text: []const u8, width: u16, presentation: Presentation, rail: screen.Style) !void {
    try appendToolBodyTextStyled(allocator, out, text, width, presentation, rail, screen.text.tool_output);
}

fn appendToolBodyTextStyled(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), text: []const u8, width: u16, presentation: Presentation, rail: screen.Style, base_style: screen.Style) !void {
    if (text.len == 0) return;
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try appendToolBodyPhysicalLine(allocator, out, text[start..end], width, presentation, rail, base_style);
        if (end == text.len) break;
        start = end + 1;
    }
}

fn appendToolBodyPhysicalLine(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), text: []const u8, width: u16, presentation: Presentation, rail: screen.Style, base_style: screen.Style) !void {
    const line_style = toolBodyLineStyle(presentation, text, base_style);
    const prefix_width = screen.displayWidth(glyphs.tool_body_prefix);
    const body_width: u16 = if (width <= prefix_width) 0 else @intCast(@as(usize, width) - prefix_width);
    if (text.len == 0 or body_width == 0) {
        var line: layout.Line = .{};
        try line.append(.{ .text = screen.sliceForColumns(glyphs.tool_body_prefix, width), .style = rail });
        try out.append(allocator, line);
        return;
    }
    var start: usize = 0;
    while (start < text.len) {
        const end = layout.sliceEndForWidth(text, start, body_width);
        var line: layout.Line = .{};
        try line.append(.{ .text = glyphs.tool_body_prefix, .style = rail });
        try line.append(.{ .text = text[start..end], .style = line_style });
        try out.append(allocator, line);
        start = end;
    }
}

fn toolBodyLineStyle(presentation: Presentation, line: []const u8, fallback: screen.Style) screen.Style {
    if (isToolWarningLine(line)) return screen.text.warning;
    if (presentation != .patch or line.len == 0) return fallback;
    if (std.mem.startsWith(u8, line, "@@")) return screen.diff.context;
    return switch (line[0]) {
        '+' => screen.diff.added,
        '-' => screen.diff.removed,
        else => fallback,
    };
}

fn isToolWarningLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "[Truncated:") or
        std.mem.startsWith(u8, line, "[First line") or
        std.mem.startsWith(u8, line, "[Line ") or
        std.mem.startsWith(u8, line, "[Showing ") or
        std.mem.startsWith(u8, line, "[Write omitted") or
        std.mem.startsWith(u8, line, "[File omitted");
}

const BodyPreview = struct { text: []const u8, omitted_lines: usize, omitted_before: bool = false };

fn collapsedBodyPreview(text: []const u8, collapse: Collapse) BodyPreview {
    return switch (collapse.mode) {
        .head => collapsedHeadPreview(text, collapse.lines_max),
        .tail => collapsedTailPreview(text, collapse.lines_max),
    };
}

fn collapseHint(allocator: std.mem.Allocator, mode: CollapseMode, hidden_lines: usize) ![]const u8 {
    return switch (mode) {
        .tail => std.fmt.allocPrint(allocator, "... ({d} earlier lines, ctrl+o to expand)", .{hidden_lines}),
        .head => std.fmt.allocPrint(allocator, "... ({d} more lines, ctrl+o to expand)", .{hidden_lines}),
    };
}

fn collapsedHeadPreview(text: []const u8, lines_max: usize) BodyPreview {
    const line_count = countPhysicalLines(text);
    if (line_count <= lines_max) return .{ .text = text, .omitted_lines = 0 };
    return .{ .text = text[0..lineStart(text, lines_max + 1)], .omitted_lines = line_count - lines_max };
}

fn collapsedTailPreview(text: []const u8, lines_max: usize) BodyPreview {
    if (lines_max == 0) return .{ .text = "", .omitted_lines = countPhysicalLines(text), .omitted_before = true };
    const line_count = countPhysicalLines(text);
    if (line_count <= lines_max) return .{ .text = text, .omitted_lines = 0 };
    const hidden_lines = line_count - lines_max;
    return .{ .text = text[lineStart(text, hidden_lines + 1)..], .omitted_lines = hidden_lines, .omitted_before = true };
}

fn lineStart(text: []const u8, line_number: usize) usize {
    if (line_number <= 1) return 0;
    var current_line: usize = 1;
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            current_line += 1;
            if (current_line == line_number) return index + 1;
        }
    }
    return text.len;
}

pub fn countPhysicalLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

fn toolFooterLine(allocator: std.mem.Allocator, tool: anytype) !?[]const u8 {
    var duration_buffer: [64]u8 = undefined;
    const duration = durationText(&duration_buffer, tool);
    if (tool.footer.len == 0 and duration.len == 0) return null;
    const body = if (tool.footer.len == 0)
        duration
    else if (duration.len == 0)
        tool.footer
    else
        try std.fmt.allocPrint(allocator, "{s} • {s}", .{ tool.footer, duration });
    return @as(?[]const u8, try std.fmt.allocPrint(allocator, "[{s}]", .{screen.sliceForColumns(body, footer_bytes_max - 2)}));
}

fn durationText(buffer: []u8, tool: anytype) []const u8 {
    if (!tool.display.shows_duration) return "";
    switch (tool.status) {
        .running => if (tool.elapsed_ms) |elapsed_ms| return durationChip(buffer, "Elapsed", elapsed_ms),
        .done, .failed => if (tool.duration_ms) |duration_ms| return durationChip(buffer, "Took", duration_ms),
        .aborted => if (tool.duration_ms) |duration_ms| return durationChip(buffer, "Ran", duration_ms),
        else => {},
    }
    return "";
}

fn durationChip(buffer: []u8, label: []const u8, elapsed_ms: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {d}.{d}s", .{
        label,
        elapsed_ms / std.time.ms_per_s,
        (elapsed_ms % std.time.ms_per_s) / duration_tick_ms,
    }) catch "";
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

test "tail buffer keeps the last five normalized lines" {
    var tail: TailBuffer = .{};
    tail.update("zero\none\ntwo\rthree\tfour\nfive\nsix");

    try std.testing.expectEqual(@as(usize, 5), tail.count);
    try std.testing.expectEqualStrings("zero", tail.line(0));
    try std.testing.expectEqualStrings("one", tail.line(1));
    try std.testing.expectEqualStrings("three  four", tail.line(2));
    try std.testing.expectEqualStrings("six", tail.line(4));
}

test "tail buffer coalesces CRLF and treats bare CR as line reset" {
    var crlf_tail: TailBuffer = .{};
    crlf_tail.update("one\r\ntwo\r");
    crlf_tail.update("\nthree");
    try std.testing.expectEqual(@as(usize, 3), crlf_tail.count);
    try std.testing.expectEqualStrings("one", crlf_tail.line(0));
    try std.testing.expectEqualStrings("two", crlf_tail.line(1));
    try std.testing.expectEqualStrings("three", crlf_tail.line(2));

    var progress_tail: TailBuffer = .{};
    progress_tail.update("download 10%\rdownload 20%\ncomplete");
    try std.testing.expectEqual(@as(usize, 2), progress_tail.count);
    try std.testing.expectEqualStrings("download 20%", progress_tail.line(0));
    try std.testing.expectEqualStrings("complete", progress_tail.line(1));
}

test "bounded append reports truncation" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var truncated = false;
    try appendBounded(&writer, "abcdef", 4, &truncated);
    try std.testing.expectEqualStrings("abcd", writer.written());
    try std.testing.expect(truncated);
}

test "tool body wraps with repeated rail prefix" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "abcdef");
    const tool = .{
        .name = "bash",
        .title = "$ echo",
        .compact_title = "",
        .display = ToolDisplay{},
        .status = Status.done,
        .elapsed_ms = @as(?u64, null),
        .duration_ms = @as(?u64, null),
        .tail = TailBuffer{},
        .body = body,
        .body_truncated = false,
        .footer = "",
    };
    const lines = try layoutTool(std.testing.allocator, tool, 5, true);
    defer std.testing.allocator.free(lines);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("│ abc", lines[2].copyText(&buffer));
    try std.testing.expectEqualStrings("│ def", lines[3].copyText(&buffer));
}

test "successful hidden tool body appears when expanded" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "secret");
    const tool = .{
        .name = "read",
        .title = "read file.zig",
        .compact_title = "",
        .display = ToolDisplay{ .body_mode = .hidden_on_success },
        .status = Status.done,
        .elapsed_ms = @as(?u64, null),
        .duration_ms = @as(?u64, null),
        .tail = TailBuffer{},
        .body = body,
        .body_truncated = false,
        .footer = "",
    };
    const collapsed = try layoutTool(std.testing.allocator, tool, 40, false);
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);

    const expanded = try layoutTool(std.testing.allocator, tool, 40, true);
    defer std.testing.allocator.free(expanded);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("│ secret", expanded[2].copyText(&buffer));
}

test "tool golden rhythm covers every status transition" {
    const TestTool = struct {
        name: []const u8,
        title: []const u8,
        compact_title: []const u8,
        display: ToolDisplay,
        status: Status,
        elapsed_ms: ?u64,
        duration_ms: ?u64,
        tail: TailBuffer,
        body: std.ArrayList(u8),
        body_truncated: bool,
        footer: []const u8,
    };
    const cases = [_]struct {
        status: Status,
        title: []const u8,
        footer: ?[]const u8,
    }{
        .{ .status = .pending, .title = "$ echo hi", .footer = null },
        .{ .status = .running, .title = "$ echo hi", .footer = "[Elapsed 1.2s]" },
        .{ .status = .done, .title = "$ echo hi", .footer = "[Took 1.2s]" },
        .{ .status = .failed, .title = "$ echo hi (error)", .footer = "[Took 1.2s]" },
        .{ .status = .aborted, .title = "$ echo hi (aborted)", .footer = "[Ran 1.2s]" },
    };

    for (cases) |case| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(std.testing.allocator);
        try body.appendSlice(std.testing.allocator, "output");
        const terminal = case.status == .done or case.status == .failed or case.status == .aborted;
        const tool: TestTool = .{
            .name = "bash",
            .title = "$ echo hi",
            .compact_title = "",
            .display = ToolDisplay{ .shows_duration = true },
            .status = case.status,
            .elapsed_ms = if (case.status == .running) @as(?u64, 1234) else null,
            .duration_ms = if (terminal) @as(?u64, 1234) else null,
            .tail = TailBuffer{},
            .body = body,
            .body_truncated = false,
            .footer = "",
        };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const lines = try layoutTool(arena.allocator(), tool, 80, true);
        try std.testing.expectEqual(@as(usize, if (case.footer == null) 4 else 5), lines.len);
        for (lines) |line| try std.testing.expect(screen.Style.eql(line.row_style, screen.surface.transparent));
        var buffer: [96]u8 = undefined;
        try std.testing.expectEqualStrings(case.title, lines[0].copyText(&buffer));
        try std.testing.expectEqualStrings(glyphs.tool_top_line, lines[1].copyText(&buffer));
        try std.testing.expectEqualStrings("│ output", lines[2].copyText(&buffer));
        try std.testing.expectEqualStrings(glyphs.tool_bottom_line, lines[3].copyText(&buffer));
        if (case.footer) |footer| try std.testing.expectEqualStrings(footer, lines[4].copyText(&buffer));
    }
}

test "duration footer renders outside tool rail" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const tool = .{
        .name = "bash",
        .title = "$ pwd",
        .compact_title = "",
        .display = ToolDisplay{ .shows_duration = true },
        .status = Status.done,
        .elapsed_ms = @as(?u64, null),
        .duration_ms = @as(?u64, 1234),
        .tail = TailBuffer{},
        .body = body,
        .body_truncated = false,
        .footer = "Truncated: x",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try layoutTool(arena.allocator(), tool, 80, true);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("[Truncated: x • Took 1.2s]", lines[1].copyText(&buffer));
}

test "aborted duration uses ran label" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const tool = .{
        .name = "bash",
        .title = "$ sleep 10",
        .compact_title = "",
        .display = ToolDisplay{ .shows_duration = true },
        .status = Status.aborted,
        .elapsed_ms = @as(?u64, null),
        .duration_ms = @as(?u64, 3400),
        .tail = TailBuffer{},
        .body = body,
        .body_truncated = false,
        .footer = "",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try layoutTool(arena.allocator(), tool, 80, true);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[Ran 3.4s]", lines[1].copyText(&buffer));
}

test {
    std.testing.refAllDecls(@This());
}
