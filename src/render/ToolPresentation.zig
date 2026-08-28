//! Interactive tool-call headers and bounded output previews.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const text = @import("../text/root.zig");
const tool = @import("../tool/root.zig");
const Theme = @import("Theme.zig");
const ToolRenderer = @import("ToolRenderer.zig");

const ToolPresentation = @This();

pub const Error = ToolRenderer.Error;

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const bold_off = "\x1b[22m";
const dim = "\x1b[2m";
const header_extra_cells: usize = 20;
const minimum_display_cells: usize = 8;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
theme: Theme,
width: usize,
active: ?ToolRenderer = null,
active_style: tool.Tool.OutputStyle = .plain,
error_value: ?Error = null,
cluster_open: bool = false,
cluster_cells: usize = 0,
wrote_block: bool = false,
needs_separator: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    theme: Theme,
    width: usize,
) ToolPresentation {
    return .{
        .allocator = allocator,
        .writer = writer,
        .theme = theme,
        .width = width,
    };
}

pub fn deinit(self: *ToolPresentation) void {
    self.close();
    self.* = undefined;
}

pub fn resetTurn(self: *ToolPresentation, width: usize) void {
    self.close();
    self.width = width;
    self.error_value = null;
    self.cluster_open = false;
    self.cluster_cells = 0;
    self.wrote_block = false;
    self.needs_separator = false;
}

pub fn setWidth(self: *ToolPresentation, width: usize) void {
    self.width = width;
}

pub fn requireSeparator(self: *ToolPresentation) void {
    self.needs_separator = true;
}

pub fn beginTool(
    self: *ToolPresentation,
    observation: agent.Loop.ToolObservation,
) ?tool.Tool.DisplaySink {
    self.finishActive();
    const display: tool.Tool.Display = observation.display orelse .{};
    const preview = if (observation.action == .run)
        display.preview(observation.effective_arguments_json)
    else
        tool.Tool.PreviewMode.head;
    if (preview == .collapsed) {
        self.renderCollapsed(observation, display);
        return null;
    }

    self.closeCluster();
    self.openBlock();
    self.renderHeader(observation, display);
    if (self.error_value != null) return null;
    const mode: ToolRenderer.Mode = switch (preview) {
        .head => .head,
        .head_tail => .head_tail,
        .collapsed => unreachable,
    };
    self.active = ToolRenderer.init(
        self.allocator,
        self.writer,
        self.theme,
        self.width,
        mode,
    );
    self.active_style = display.output_style;
    return self.active.?.sink();
}

pub fn endTool(
    self: *ToolPresentation,
    observation: agent.Loop.ToolObservation,
    result: *const ai.Item.ToolResult,
) void {
    if (self.active == null) return;
    var renderer = &self.active.?;
    const display_called = renderer.display_was_called;
    if (!display_called) {
        const visible_len = result.output.len -| result.hidden_tail_bytes;
        const visible = result.output[0..visible_len];
        switch (observation.action) {
            .refuse => renderer.feed("[refused: --raw, no tools advertised]") catch
                self.recordError(error.OutOfMemory),
            .skip => renderer.feed("[interrupted]") catch self.recordError(error.OutOfMemory),
            .run => {
                if (self.active_style == .unified_diff and visible.len == 0) {
                    renderer.feed("(no changes)") catch self.recordError(error.OutOfMemory);
                } else {
                    if (self.active_style == .unified_diff and std.mem.startsWith(u8, visible, "--- ")) {
                        renderer.setMode(.unified_diff);
                    }
                    renderer.feed(visible) catch self.recordError(error.OutOfMemory);
                }
            },
        }
    }
    renderer.finalize() catch |err| self.recordError(err);
    const needs_diff_fallback = self.active_style == .unified_diff and
        display_called and renderer.rowCount() == 0 and result.output.len != 0;
    renderer.deinit();
    self.active = null;

    if (needs_diff_fallback) {
        var fallback = ToolRenderer.init(
            self.allocator,
            self.writer,
            self.theme,
            self.width,
            .head,
        );
        defer fallback.deinit();
        fallback.feed(result.output) catch self.recordError(error.OutOfMemory);
        fallback.finalize() catch |err| self.recordError(err);
    }
}

pub fn closeCluster(self: *ToolPresentation) void {
    if (!self.cluster_open) return;
    self.write("\n");
    self.cluster_open = false;
    self.cluster_cells = 0;
}

pub fn close(self: *ToolPresentation) void {
    self.finishActive();
    self.closeCluster();
    self.flush();
}

pub fn check(self: *const ToolPresentation) Error!void {
    if (self.error_value) |err| return err;
}

fn finishActive(self: *ToolPresentation) void {
    if (self.active) |*renderer| {
        renderer.finalize() catch |err| self.recordError(err);
        renderer.deinit();
        self.active = null;
    }
}

fn renderHeader(
    self: *ToolPresentation,
    observation: agent.Loop.ToolObservation,
    display: tool.Tool.Display,
) void {
    const name = if (observation.call.name.len == 0) "?" else observation.call.name;
    self.write(self.theme.chrome.open);
    self.write("[");
    self.writeSafeFlat(name);
    self.write("]");
    self.write(self.theme.chrome.close);

    const argument = self.displayArgument(display, observation.effective_arguments_json);
    defer if (argument) |bytes| self.allocator.free(bytes);
    if (argument) |bytes| {
        const extra = self.displayExtra(display, observation.effective_arguments_json);
        defer if (extra) |value| self.allocator.free(value);
        self.write(" ");
        self.write(bold);
        self.writeReflowed(bytes, display.header_rows, name, if (extra) |value| value else "");
        self.write(bold_off);
        if (extra) |value| if (value.len != 0) {
            self.write(dim);
            self.write(value);
            self.write(reset);
        };
    } else if (observation.effective_arguments_json.len != 0) {
        const flat = self.sanitizeFlat(observation.effective_arguments_json) catch {
            self.recordError(error.OutOfMemory);
            return;
        };
        defer self.allocator.free(flat);
        const tag_cells = text.DisplayWidth.visibleWidth(name, std.math.maxInt(usize)) + 3;
        const available = @max(minimum_display_cells, self.width -| tag_cells);
        const clipped = self.truncateCells(flat, available) catch {
            self.recordError(error.OutOfMemory);
            return;
        };
        defer self.allocator.free(clipped);
        self.write(" ");
        self.write(dim);
        self.write(clipped);
        self.write(reset);
    }
    self.write("\n");
    self.flush();
}

fn renderCollapsed(
    self: *ToolPresentation,
    observation: agent.Loop.ToolObservation,
    display: tool.Tool.Display,
) void {
    const name = if (observation.call.name.len == 0) "?" else observation.call.name;
    const argument = self.collapsedArgument(display, observation.effective_arguments_json) catch {
        self.recordError(error.OutOfMemory);
        return;
    };
    defer self.allocator.free(argument);
    const tag_cells = text.DisplayWidth.visibleWidth(name, std.math.maxInt(usize)) + 3;
    const appended_cells = 2 + text.DisplayWidth.visibleWidth(argument, std.math.maxInt(usize));
    const can_append = self.cluster_open and std.mem.eql(u8, name, "read") and
        self.cluster_cells + appended_cells <= self.width -| 1;
    if (can_append) {
        self.write(dim);
        self.write(", ");
        self.write(argument);
        self.write(reset);
        self.cluster_cells +|= appended_cells;
        self.flush();
        return;
    }

    self.closeCluster();
    self.openBlock();
    const available = @max(minimum_display_cells, self.width -| tag_cells -| 1);
    const clipped = self.truncateCells(argument, available) catch {
        self.recordError(error.OutOfMemory);
        return;
    };
    defer self.allocator.free(clipped);
    self.write(self.theme.chrome_dim.open);
    self.write("[");
    self.writeSafeFlat(name);
    self.write("]");
    self.write(self.theme.chrome_dim.close);
    self.write(dim);
    self.write(" ");
    self.write(clipped);
    self.write(reset);
    self.cluster_cells = tag_cells + text.DisplayWidth.visibleWidth(clipped, std.math.maxInt(usize));
    self.cluster_open = std.mem.eql(u8, name, "read");
    if (!self.cluster_open) self.write("\n");
    self.flush();
}

fn openBlock(self: *ToolPresentation) void {
    if (self.needs_separator or self.wrote_block) self.write("\n");
    self.needs_separator = false;
    self.wrote_block = true;
}

fn displayArgument(
    self: *ToolPresentation,
    display: tool.Tool.Display,
    arguments_json: ?[]const u8,
) ?[]u8 {
    const arg_name = display.arg_name orelse return null;
    const source = arguments_json orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(arg_name) orelse return null;
    if (value != .string) return null;
    return self.sanitizeFlat(value.string) catch {
        self.recordError(error.OutOfMemory);
        return null;
    };
}

fn displayExtra(
    self: *ToolPresentation,
    display: tool.Tool.Display,
    arguments_json: ?[]const u8,
) ?[]u8 {
    const formatter = display.format_extra orelse return null;
    const raw = formatter(self.allocator, arguments_json) catch {
        self.recordError(error.OutOfMemory);
        return null;
    } orelse return null;
    defer self.allocator.free(raw);
    const safe = self.sanitizeFlat(raw) catch {
        self.recordError(error.OutOfMemory);
        return null;
    };
    if (text.DisplayWidth.visibleWidth(safe, header_extra_cells + 1) <= header_extra_cells) return safe;
    defer self.allocator.free(safe);
    return self.truncateCells(safe, header_extra_cells) catch {
        self.recordError(error.OutOfMemory);
        return null;
    };
}

fn collapsedArgument(
    self: *ToolPresentation,
    display: tool.Tool.Display,
    arguments_json: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const argument = self.displayArgument(display, arguments_json);
    defer if (argument) |bytes| self.allocator.free(bytes);
    const collapsed = if (display.collapse_argument) |collapse|
        try collapse(self.allocator, argument)
    else if (argument) |bytes|
        try self.allocator.dupe(u8, bytes)
    else
        try self.allocator.dupe(u8, "");
    defer self.allocator.free(collapsed);

    const extra = self.displayExtra(display, arguments_json);
    defer if (extra) |bytes| self.allocator.free(bytes);
    const joined = if (extra) |bytes|
        try std.mem.concat(self.allocator, u8, &.{ collapsed, bytes })
    else
        try self.allocator.dupe(u8, collapsed);
    defer self.allocator.free(joined);
    return self.sanitizeFlat(joined);
}

fn writeReflowed(
    self: *ToolPresentation,
    bytes: []const u8,
    configured_rows: usize,
    name: []const u8,
    extra: []const u8,
) void {
    const rows = std.math.clamp(configured_rows, 1, 16);
    const tag_cells = text.DisplayWidth.visibleWidth(name, std.math.maxInt(usize)) + 3;
    const first_width = @max(minimum_display_cells, self.width -| tag_cells);
    const continuation_width = @max(minimum_display_cells, self.width);
    const extra_cells = text.DisplayWidth.visibleWidth(extra, header_extra_cells);
    var row: usize = 0;
    var row_cells: usize = 0;
    var offset: usize = 0;

    while (offset < bytes.len) {
        while (offset < bytes.len and bytes[offset] == ' ') offset += 1;
        if (offset == bytes.len) break;
        const word_start = offset;
        while (offset < bytes.len and bytes[offset] != ' ') offset += 1;
        const word = bytes[word_start..offset];
        const word_cells = text.DisplayWidth.visibleWidth(word, std.math.maxInt(usize));
        var row_width = if (row == 0) first_width else continuation_width;
        if (row + 1 == rows) row_width -|= extra_cells;

        if (row + 1 == rows) {
            const separator_cells: usize = @intFromBool(row_cells != 0);
            const available = row_width -| row_cells -| separator_cells;
            if (row_cells != 0 and available != 0) self.write(" ");
            const remainder = bytes[word_start..];
            const clipped = self.truncateCells(remainder, available) catch {
                self.recordError(error.OutOfMemory);
                return;
            };
            defer self.allocator.free(clipped);
            self.write(clipped);
            return;
        }

        const separator_cells: usize = @intFromBool(row_cells != 0);
        if (word_cells +| separator_cells <= row_width -| row_cells) {
            if (separator_cells != 0) self.write(" ");
            self.write(word);
            row_cells += separator_cells + word_cells;
            continue;
        }
        if (row_cells == 0) {
            const prefix_end = cellPrefixEnd(word, row_width);
            self.write(word[0..prefix_end]);
            self.write("\n");
            row += 1;
            offset = word_start + prefix_end;
            continue;
        }

        self.write("\n");
        row += 1;
        row_cells = 0;
        offset = word_start;
    }
}

fn sanitizeFlat(self: *ToolPresentation, bytes: []const u8) error{OutOfMemory}![]u8 {
    const valid = text.Utf8.sanitize(self.allocator, bytes, 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResultTooLarge => return self.allocator.dupe(u8, "?"),
    };
    defer self.allocator.free(valid);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(self.allocator);
    var previous_space = false;
    var glyphs = text.DisplayWidth.iterator(valid);
    while (true) {
        const start = glyphs.offset;
        const glyph = glyphs.next() orelse break;
        const whitespace = valid[start] == ' ' or valid[start] == '\t' or
            valid[start] == '\n' or valid[start] == '\r';
        if (whitespace) {
            if (!previous_space) try result.append(self.allocator, ' ');
            previous_space = true;
        } else {
            try result.appendSlice(self.allocator, glyph.bytes);
            previous_space = false;
        }
    }
    return result.toOwnedSlice(self.allocator);
}

fn cellPrefixEnd(bytes: []const u8, maximum_cells: usize) usize {
    var end: usize = 0;
    var cells: usize = 0;
    var glyphs = text.DisplayWidth.iterator(bytes);
    while (glyphs.next()) |glyph| {
        if (glyph.width > maximum_cells -| cells) break;
        end = glyphs.offset;
        cells += glyph.width;
    }
    return end;
}

fn truncateCells(
    self: *ToolPresentation,
    bytes: []const u8,
    maximum_cells: usize,
) error{OutOfMemory}![]u8 {
    if (text.DisplayWidth.visibleWidth(bytes, maximum_cells +| 1) <= maximum_cells) {
        return self.allocator.dupe(u8, bytes);
    }
    const dots = @min(maximum_cells, 3);
    const prefix_cells = maximum_cells - dots;
    var end: usize = 0;
    var cells: usize = 0;
    var glyphs = text.DisplayWidth.iterator(bytes);
    while (glyphs.next()) |glyph| {
        if (glyph.width > prefix_cells -| cells) break;
        end = glyphs.offset;
        cells += glyph.width;
    }
    const result = try self.allocator.alloc(u8, end + dots);
    @memcpy(result[0..end], bytes[0..end]);
    @memset(result[end..], '.');
    return result;
}

fn writeSafeFlat(self: *ToolPresentation, bytes: []const u8) void {
    const safe = self.sanitizeFlat(bytes) catch {
        self.recordError(error.OutOfMemory);
        return;
    };
    defer self.allocator.free(safe);
    self.write(safe);
}

fn recordError(self: *ToolPresentation, err: Error) void {
    if (self.error_value == null) self.error_value = err;
}

fn write(self: *ToolPresentation, bytes: []const u8) void {
    if (self.error_value != null or bytes.len == 0) return;
    self.writer.writeAll(bytes) catch |err| self.recordError(err);
}

fn flush(self: *ToolPresentation) void {
    if (self.error_value != null) return;
    self.writer.flush() catch |err| self.recordError(err);
}

fn testTheme() !Theme {
    return Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
}

const fake_definition: tool.Tool.Definition = .{
    .name = "fake",
    .description = "fake",
    .parameters = &.{},
};

const FakeTool = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        _: std.Io,
        _: *FakeTool,
        _: ?[]const u8,
        _: tool.Tool.RunContext,
    ) tool.Tool.RunError!tool.Tool.Result {
        return .{ .output = try allocator.dupe(u8, "ok") };
    }
};

fn testObservation(selected: ?tool.Tool.Tool, arguments: []const u8) agent.Loop.ToolObservation {
    return namedTestObservation("fake", selected, arguments);
}

fn readObservation(selected: ?tool.Tool.Tool, arguments: []const u8) agent.Loop.ToolObservation {
    return namedTestObservation("read", selected, arguments);
}

fn namedTestObservation(
    comptime name: []const u8,
    selected: ?tool.Tool.Tool,
    arguments: []const u8,
) agent.Loop.ToolObservation {
    const call = &struct {
        const value: ai.Item.ToolCall = .{
            .id = @constCast("id"),
            .name = @constCast(name),
            .arguments_json = @constCast("{}"),
        };
    }.value;
    return .{
        .call = call,
        .effective_arguments_json = arguments,
        .display = if (selected) |value| value.display else null,
        .action = .run,
    };
}

test "verbose tool presentation renders a safe header and bounded result" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var fake: FakeTool = .{};
    const selected = tool.Tool.Tool.from(&fake, fake_definition, .{ .arg_name = "command" });
    var presentation = init(std.testing.allocator, &output.writer, try testTheme(), 40);
    defer presentation.deinit();
    const observed = testObservation(selected, "{\"command\":\"echo hi\\nthere\"}");
    try std.testing.expect(presentation.beginTool(observed) != null);
    const result: ai.Item.ToolResult = .{ .call_id = @constCast("id"), .output = @constCast("done") };
    presentation.endTool(observed, &result);
    try presentation.check();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "[fake]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "echo hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "done") != null);
}

test "collapsed reads coalesce and omit result previews" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var fake: FakeTool = .{};
    const selected = tool.Tool.Tool.from(&fake, fake_definition, .{
        .arg_name = "path",
        .preview_mode = .collapsed,
    });
    var presentation = init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer presentation.deinit();
    const first = readObservation(selected, "{\"path\":\"a.zig\"}");
    const second = readObservation(selected, "{\"path\":\"b.zig\"}");
    try std.testing.expect(presentation.beginTool(first) == null);
    try std.testing.expect(presentation.beginTool(second) == null);
    const result: ai.Item.ToolResult = .{ .call_id = @constCast("id"), .output = @constCast("secret") };
    presentation.endTool(first, &result);
    presentation.endTool(second, &result);
    presentation.close();
    try presentation.check();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), ", b.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "secret") == null);
}

test "hidden result tail is not rendered" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var fake: FakeTool = .{};
    const selected = tool.Tool.Tool.from(&fake, fake_definition, .{});
    var presentation = init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer presentation.deinit();
    const observed = testObservation(selected, "{}");
    _ = presentation.beginTool(observed);
    const result: ai.Item.ToolResult = .{
        .call_id = @constCast("id"),
        .output = @constCast("visiblemodel-only"),
        .hidden_tail_bytes = "model-only".len,
    };
    presentation.endTool(observed, &result);
    try presentation.check();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "model-only") == null);
}

test "unified diff output is colored and empty output reports no changes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var fake: FakeTool = .{};
    const selected = tool.Tool.Tool.from(&fake, fake_definition, .{ .output_style = .unified_diff });
    var presentation = init(std.testing.allocator, &output.writer, try testTheme(), 80);
    defer presentation.deinit();
    const observed = testObservation(selected, "{}");
    _ = presentation.beginTool(observed);
    const diff: ai.Item.ToolResult = .{
        .call_id = @constCast("id"),
        .output = @constCast("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"),
    };
    presentation.endTool(observed, &diff);
    _ = presentation.beginTool(observed);
    const empty: ai.Item.ToolResult = .{ .call_id = @constCast("id"), .output = @constCast("") };
    presentation.endTool(observed, &empty);
    try presentation.check();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[31m-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "(no changes)") != null);
}
