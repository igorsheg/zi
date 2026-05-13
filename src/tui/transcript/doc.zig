const std = @import("std");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const surface_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const wrap_mod = @import("../wrap/display.zig");
const grapheme = @import("../grapheme.zig");
const layout_mod = @import("layout.zig");
const md_parser = @import("../markdown/parser.zig");
const md_render = @import("../markdown/render.zig");

const Region = surface_mod.Region;
const Color = cell_mod.Color;
const Allocator = std.mem.Allocator;
const Segment = layout_mod.Segment;
const Row = layout_mod.Row;

pub fn isDoc(value: std.json.Value) bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return false,
    };
    const schema = switch (obj.get("schema") orelse return false) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.eql(u8, schema, "zi.doc.v1");
}

pub const Role = enum { normal, muted, title, accent, success, warning, danger, code };

pub const Style = struct {
    role: Role = .normal,
    attrs: cell_mod.Attributes = .{},
};

pub const Span = struct {
    text: []const u8,
    style: Style = .{},
    link: ?[]const u8 = null,
};

pub const Text = struct {
    indent_cols: u32 = 0,
    text: []const u8,
    style: Style = .{},
    collapsed_lines: ?u32 = null,
};

pub const Line = struct {
    indent_cols: u32 = 0,
    marker: ?Span = null,
    spans: []const Span = &.{},
};

pub const Group = struct {
    indent_cols: u32 = 0,
    max_blocks: ?u32 = null,
    blocks: []const Block = &.{},
};

pub const Block = union(enum) {
    line: Line,
    text: Text,
    markdown: Text,
    group: Group,
    separator,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    layout_arena: std.heap.ArenaAllocator,
    blocks: []const Block = &.{},
    rows: []const Row = &.{},
    layout_width: u32 = 0,
    layout_width_method: grapheme.WidthMethod = .wcwidth,
    layout_expanded: bool = false,
    layout_theme: ?*const theme_mod.Theme = null,
    layout_valid: bool = false,

    pub fn parse(parent_allocator: Allocator, value: std.json.Value) !*Doc {
        if (!isDoc(value)) return error.InvalidDoc;
        const self = try parent_allocator.create(Doc);
        errdefer parent_allocator.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .layout_arena = std.heap.ArenaAllocator.init(parent_allocator),
        };
        errdefer self.arena.deinit();
        errdefer self.layout_arena.deinit();

        const obj = value.object;
        const json_blocks = switch (obj.get("blocks") orelse return error.InvalidDoc) {
            .array => |a| a.items,
            else => return error.InvalidDoc,
        };
        self.blocks = try parseBlocks(self.arena.allocator(), json_blocks, 0);
        return self;
    }

    pub fn deinit(self: *Doc, parent_allocator: Allocator) void {
        self.layout_arena.deinit();
        self.arena.deinit();
        parent_allocator.destroy(self);
    }

    pub fn invalidateLayout(self: *Doc) void {
        self.layout_valid = false;
    }

    pub fn measure(self: *Doc, allocator: Allocator, width: u32, expanded: bool, width_method: grapheme.WidthMethod) u32 {
        self.ensureLayout(allocator, width, expanded, width_method, themes_builtin.dark()) catch return 0;
        return @intCast(self.rows.len);
    }

    pub fn renderSlice(self: *Doc, allocator: Allocator, region: Region, theme: *const theme_mod.Theme, expanded: bool, first_row: u32) void {
        self.ensureLayout(allocator, region.width, expanded, region.buf.width_method, theme) catch return;
        layout_mod.renderRowsSlice(self.rows, region, first_row);
    }

    fn ensureLayout(self: *Doc, allocator: Allocator, width: u32, expanded: bool, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) !void {
        _ = allocator;
        if (self.layout_valid and self.layout_width == width and self.layout_expanded == expanded and self.layout_width_method == width_method and self.layout_theme == theme) return;
        _ = self.layout_arena.reset(.retain_capacity);
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        try appendBlockRows(self.layout_arena.allocator(), &rows, self.blocks, width, expanded, width_method, theme);
        self.rows = try rows.toOwnedSlice(self.layout_arena.allocator());
        self.layout_width = width;
        self.layout_expanded = expanded;
        self.layout_width_method = width_method;
        self.layout_theme = theme;
        self.layout_valid = true;
    }
};

const ParseError = error{OutOfMemory};

fn parseBlocks(arena: Allocator, values: []const std.json.Value, base_indent_cols: u32) ParseError![]const Block {
    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    try blocks.ensureTotalCapacity(arena, values.len);
    for (values) |value| if (try parseBlock(arena, value, base_indent_cols)) |block| try blocks.append(arena, block);
    return blocks.items;
}

fn parseBlock(arena: Allocator, value: std.json.Value, base_indent_cols: u32) ParseError!?Block {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const typ = stringField(obj, "type") orelse return null;
    const indent_cols = base_indent_cols + intField(obj, "indent", 0) * 2;

    if (std.mem.eql(u8, typ, "separator")) return .separator;
    if (std.mem.eql(u8, typ, "line")) return .{ .line = .{
        .indent_cols = indent_cols,
        .marker = if (obj.get("marker")) |m| try parseSpan(arena, m) else null,
        .spans = if (obj.get("spans")) |s| try parseSpans(arena, s) else &.{},
    } };
    if (std.mem.eql(u8, typ, "text") or std.mem.eql(u8, typ, "markdown")) {
        const text = stringField(obj, "text") orelse "";
        const parsed = Text{
            .indent_cols = indent_cols,
            .text = try arena.dupe(u8, text),
            .style = parseStyle(obj.get("style")),
            .collapsed_lines = if (obj.get("collapsed_lines") != null) intField(obj, "collapsed_lines", 0) else null,
        };
        return if (std.mem.eql(u8, typ, "markdown")) .{ .markdown = parsed } else .{ .text = parsed };
    }
    if (std.mem.eql(u8, typ, "group")) {
        const json_blocks = switch (obj.get("blocks") orelse return null) {
            .array => |a| a.items,
            else => return null,
        };
        const max_blocks = if (obj.get("collapsed")) |c| blk: {
            const co = switch (c) {
                .object => |o| o,
                else => break :blk null,
            };
            break :blk intField(co, "max_blocks", 0);
        } else null;
        return .{ .group = .{
            .indent_cols = indent_cols,
            .max_blocks = max_blocks,
            .blocks = try parseBlocks(arena, json_blocks, indent_cols),
        } };
    }
    return null;
}

fn parseSpans(arena: Allocator, value: std.json.Value) ParseError![]const Span {
    const items = switch (value) {
        .array => |a| a.items,
        else => return &.{},
    };
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    try spans.ensureTotalCapacity(arena, items.len);
    for (items) |item| if (try parseSpan(arena, item)) |span| try spans.append(arena, span);
    return spans.items;
}

fn parseSpan(arena: Allocator, value: std.json.Value) ParseError!?Span {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const text = stringField(obj, "text") orelse return null;
    return .{ .text = try arena.dupe(u8, text), .style = parseStyle(obj.get("style")), .link = if (stringField(obj, "link")) |l| try arena.dupe(u8, l) else null };
}

const LayoutError = error{OutOfMemory};

fn appendBlockRows(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), blocks: []const Block, width: u32, expanded: bool, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) LayoutError!void {
    for (blocks) |block| try appendBlockRow(arena, rows, block, width, expanded, width_method, theme);
}

fn appendBlockRow(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), block: Block, width: u32, expanded: bool, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) LayoutError!void {
    switch (block) {
        .separator => try appendSeparatorRow(arena, rows, width, theme),
        .line => |line| try appendLineRow(arena, rows, line, width_method, theme),
        .text => |text| try appendTextRows(arena, rows, text, width, expanded, width_method, theme),
        .markdown => |text| try appendMarkdownRows(arena, rows, text, width, expanded, width_method, theme),
        .group => |group| {
            const start_len = rows.items.len;
            const child_width = if (width > group.indent_cols) width - group.indent_cols else 1;
            var child_rows: std.ArrayListUnmanaged(Row) = .empty;
            try appendBlockRows(arena, &child_rows, group.blocks, child_width, expanded, width_method, theme);
            const all = child_rows.items;
            const visible = if (expanded or group.max_blocks == null) all.len else @min(all.len, group.max_blocks.?);
            try rows.appendSlice(arena, all[0..visible]);
            if (!expanded and group.max_blocks != null and all.len > visible) {
                try appendTextSegmentRow(arena, rows, group.indent_cols, "... more", .{ .role = .muted }, null, theme);
            }
            _ = start_len;
        },
    }
}

fn appendMarkdownRows(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), text: Text, width: u32, expanded: bool, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) LayoutError!void {
    const w = if (width > text.indent_cols) width - text.indent_cols else 1;
    const ast = md_parser.parseDocument(text.text, arena) catch return appendTextRows(arena, rows, text, width, expanded, width_method, theme);
    const rendered = md_render.renderDocument(ast, w, theme, .{ .fg = fg(theme, text.style.role), .bg = Color.default, .attrs = text.style.attrs }, "  ", arena, width_method) catch return appendTextRows(arena, rows, text, width, expanded, width_method, theme);
    const visible = if (expanded or text.collapsed_lines == null) rendered.len else @min(rendered.len, text.collapsed_lines.?);
    for (rendered[0..visible]) |line| {
        var segments: std.ArrayListUnmanaged(Segment) = .empty;
        var col = text.indent_cols;
        for (line.spans) |span| {
            if (span.text.len == 0) continue;
            try segments.append(arena, .{ .x = col, .text = span.text, .style = .{ .fg = span.fg, .bg = span.bg, .attrs = span.attrs } });
            col += @intCast(grapheme.strWidth(span.text, width_method));
        }
        try rows.append(arena, .{ .segments = try segments.toOwnedSlice(arena) });
    }
    if (!expanded and text.collapsed_lines != null and rendered.len > visible) {
        try appendTextSegmentRow(arena, rows, text.indent_cols, "... more", .{ .role = .muted }, null, theme);
    }
}

fn appendTextRows(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), text: Text, width: u32, expanded: bool, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) LayoutError!void {
    const w = if (width > text.indent_cols) width - text.indent_cols else 1;
    const wrapped = try wrap_mod.wordWrap(text.text, @intCast(w), arena, width_method);
    const visible = if (expanded or text.collapsed_lines == null) wrapped.len else @min(wrapped.len, text.collapsed_lines.?);
    for (wrapped[0..visible]) |line| try appendTextSegmentRow(arena, rows, text.indent_cols, line.text(text.text), text.style, null, theme);
    if (!expanded and text.collapsed_lines != null and wrapped.len > visible) {
        try appendTextSegmentRow(arena, rows, text.indent_cols, "... more", .{ .role = .muted }, null, theme);
    }
}

fn appendSeparatorRow(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), width: u32, theme: *const theme_mod.Theme) LayoutError!void {
    const text = try arena.alloc(u8, width * "─".len);
    var i: usize = 0;
    while (i < width) : (i += 1) @memcpy(text[i * "─".len ..][0.."─".len], "─");
    try appendTextSegmentRow(arena, rows, 0, text, .{ .role = .muted }, null, theme);
}

fn appendTextSegmentRow(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), x: u32, text: []const u8, style: Style, link: ?[]const u8, theme: *const theme_mod.Theme) LayoutError!void {
    _ = link;
    const segments = try arena.alloc(Segment, 1);
    segments[0] = .{ .x = x, .text = text, .style = drawStyle(style, theme) };
    try rows.append(arena, .{ .segments = segments });
}

fn appendLineRow(arena: Allocator, rows: *std.ArrayListUnmanaged(Row), line: Line, width_method: grapheme.WidthMethod, theme: *const theme_mod.Theme) LayoutError!void {
    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    const extra: usize = if (line.marker != null) 2 else 0;
    try segments.ensureTotalCapacity(arena, line.spans.len + extra);
    var col = line.indent_cols;
    if (line.marker) |marker| {
        try segments.append(arena, .{ .x = col, .text = marker.text, .style = drawStyle(marker.style, theme) });
        col += @intCast(grapheme.strWidth(marker.text, width_method));
        try segments.append(arena, .{ .x = col, .text = " " });
        col += 1;
    }
    for (line.spans) |span| {
        try segments.append(arena, .{ .x = col, .text = span.text, .style = drawStyle(span.style, theme) });
        col += @intCast(grapheme.strWidth(span.text, width_method));
    }
    try rows.append(arena, .{ .segments = try segments.toOwnedSlice(arena) });
}

fn drawStyle(style: Style, theme: *const theme_mod.Theme) layout_mod.Style {
    return .{ .fg = fg(theme, style.role), .bg = Color.default, .attrs = style.attrs };
}

fn parseStyle(value: ?std.json.Value) Style {
    const obj = switch (value orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };
    return .{ .role = parseRole(stringField(obj, "role")), .attrs = .{ .bold = boolField(obj, "bold"), .dim = boolField(obj, "dim"), .italic = boolField(obj, "italic"), .underline = boolField(obj, "underline") } };
}

fn parseRole(value: ?[]const u8) Role {
    const role = value orelse return .normal;
    if (std.mem.eql(u8, role, "muted")) return .muted;
    if (std.mem.eql(u8, role, "title")) return .title;
    if (std.mem.eql(u8, role, "accent")) return .accent;
    if (std.mem.eql(u8, role, "success")) return .success;
    if (std.mem.eql(u8, role, "warning")) return .warning;
    if (std.mem.eql(u8, role, "danger")) return .danger;
    if (std.mem.eql(u8, role, "code")) return .code;
    return .normal;
}

fn fg(theme: *const theme_mod.Theme, role: Role) Color {
    return switch (role) {
        .normal => Color.default,
        .muted => theme.fg(.muted),
        .title => theme.fg(.tool_title),
        .accent => theme.fg(.accent),
        .success => theme.fg(.success),
        .warning => theme.fg(.warning),
        .danger => theme.fg(.@"error"),
        .code => theme.fg(.md_code),
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}
fn intField(obj: std.json.ObjectMap, key: []const u8, default: u32) u32 {
    return switch (obj.get(key) orelse return default) {
        .integer => |i| if (i >= 0) @intCast(i) else default,
        .float => |f| if (f >= 0) @intFromFloat(f) else default,
        else => default,
    };
}

const testing = std.testing;
fn parseDocValue(allocator: Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
}

fn rowAscii(buf: *const surface_mod.Buffer, y: u32, out: []u8) []const u8 {
    var len: usize = 0;
    var x: u32 = 0;
    while (x < buf.width and len < out.len) : (x += 1) {
        const cell = buf.get(x, y);
        if (cell.width == 0) continue;
        switch (cell.grapheme) {
            .codepoint => |cp| out[len] = if (cp <= 0x7f) @intCast(cp) else '?',
            .pooled => out[len] = '?',
        }
        len += 1;
    }
    return std.mem.trimEnd(u8, out[0..len], " ");
}

test "zi doc parses once and renders collapsed lines with wcwidth" {
    var parsed = try parseDocValue(testing.allocator,
        \\{"schema":"zi.doc.v1","blocks":[
        \\  {"type":"line","spans":[{"text":"Title","style":{"role":"title","bold":true}}]},
        \\  {"type":"text","text":"alpha beta gamma","collapsed_lines":1}
        \\]}
    );
    defer parsed.deinit();
    const doc = try Doc.parse(testing.allocator, parsed.value);
    defer doc.deinit(testing.allocator);

    const h = doc.measure(testing.allocator, 8, false, .wcwidth);
    try testing.expectEqual(@as(u32, 3), h);

    var buf = try surface_mod.Buffer.init(testing.allocator, 8, h, .wcwidth);
    defer buf.deinit();
    doc.renderSlice(testing.allocator, buf.region(), themes_builtin.dark(), false, 0);

    var line: [32]u8 = undefined;
    try testing.expectEqualStrings("Title", rowAscii(&buf, 0, &line));
    try testing.expectEqualStrings("alpha", rowAscii(&buf, 1, &line));
    try testing.expectEqualStrings("... more", rowAscii(&buf, 2, &line));
}

test "zi doc collapsed group truncates and skip rows" {
    var parsed = try parseDocValue(testing.allocator,
        \\{"schema":"zi.doc.v1","blocks":[
        \\  {"type":"group","collapsed":{"max_blocks":1},"blocks":[
        \\    {"type":"line","spans":[{"text":"one"}]},
        \\    {"type":"line","spans":[{"text":"two"}]}
        \\  ]},
        \\  {"type":"line","spans":[{"text":"tail"}]}
        \\]}
    );
    defer parsed.deinit();
    const doc = try Doc.parse(testing.allocator, parsed.value);
    defer doc.deinit(testing.allocator);

    const h = doc.measure(testing.allocator, 16, false, .wcwidth);
    try testing.expectEqual(@as(u32, 3), h);

    var buf = try surface_mod.Buffer.init(testing.allocator, 16, 2, .wcwidth);
    defer buf.deinit();
    doc.renderSlice(testing.allocator, buf.region(), themes_builtin.dark(), false, 1);

    var line: [32]u8 = undefined;
    try testing.expectEqualStrings("... more", rowAscii(&buf, 0, &line));
    try testing.expectEqualStrings("tail", rowAscii(&buf, 1, &line));
}

test "zi doc accepts zero collapsed lines" {
    var parsed = try parseDocValue(testing.allocator,
        \\{"schema":"zi.doc.v1","blocks":[{"type":"text","text":"alpha beta","collapsed_lines":0}]}
    );
    defer parsed.deinit();
    const doc = try Doc.parse(testing.allocator, parsed.value);
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), doc.measure(testing.allocator, 8, false, .wcwidth));
    var buf = try surface_mod.Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    doc.renderSlice(testing.allocator, buf.region(), themes_builtin.dark(), false, 0);

    var line: [32]u8 = undefined;
    try testing.expectEqualStrings("... more", rowAscii(&buf, 0, &line));
}

test "zi doc group accepts max_blocks zero" {
    var parsed = try parseDocValue(testing.allocator,
        \\{"schema":"zi.doc.v1","blocks":[{"type":"group","collapsed":{"max_blocks":0},"blocks":[{"type":"line","spans":[{"text":"hidden"}]}]}]}
    );
    defer parsed.deinit();
    const doc = try Doc.parse(testing.allocator, parsed.value);
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), doc.measure(testing.allocator, 20, false, .wcwidth));
    try testing.expectEqual(@as(u32, 1), doc.measure(testing.allocator, 20, true, .wcwidth));
}

test "zi doc layout cache invalidates on width expanded and width method" {
    var parsed = try parseDocValue(testing.allocator,
        \\{"schema":"zi.doc.v1","blocks":[{"type":"text","text":"alpha beta gamma","collapsed_lines":1}]}
    );
    defer parsed.deinit();
    const doc = try Doc.parse(testing.allocator, parsed.value);
    defer doc.deinit(testing.allocator);

    const h1 = doc.measure(testing.allocator, 20, false, .wcwidth);
    try testing.expect(doc.layout_valid);
    try testing.expectEqual(@as(u32, 20), doc.layout_width);
    try testing.expectEqual(grapheme.WidthMethod.wcwidth, doc.layout_width_method);
    try testing.expect(!doc.layout_expanded);

    const h2 = doc.measure(testing.allocator, 6, false, .wcwidth);
    try testing.expect(h2 > h1);
    try testing.expectEqual(@as(u32, 6), doc.layout_width);

    _ = doc.measure(testing.allocator, 6, true, .wcwidth);
    try testing.expect(doc.layout_expanded);

    _ = doc.measure(testing.allocator, 6, true, .unicode);
    try testing.expectEqual(grapheme.WidthMethod.unicode, doc.layout_width_method);
}
