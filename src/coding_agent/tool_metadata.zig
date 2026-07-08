const std = @import("std");
const ai = @import("../ai/root.zig");
const partial_json = @import("../ai/utils/partial_json.zig");

pub const title_bytes_max: usize = 160;
pub const metadata_bytes_max: usize = 192;

pub const Presentation = enum { generic, command, file, patch, symbols };
pub const BodyMode = enum { visible, hidden_on_success, summary_only };
pub const CollapseMode = enum { head, tail };
pub const LiveUpdates = enum { show_tail, suppress };

pub const Collapse = struct {
    mode: CollapseMode = .tail,
    lines_max: u8 = 5,
};

pub const Display = struct {
    presentation: Presentation = .generic,
    body_mode: BodyMode = .visible,
    collapse: Collapse = .{},
    shows_duration: bool = false,
    live_updates: LiveUpdates = .suppress,
};

pub const BodyUpdate = union(enum) {
    unchanged,
    clear,
    replace: BodyReplacement,
};

pub const BodyReplacement = struct {
    body: []const u8,
    footer: []const u8 = "",
};

pub const CallView = struct {
    title: ?[]const u8 = null,
    compact_title: ?[]const u8 = null,
    display: Display = .{},
    body_update: BodyUpdate = .unchanged,
};

pub const ResultView = struct {
    output: ?[]u8 = null,
    footer: ?[]u8 = null,
};
const ToolKind = enum { bash, read, symbols, edit, write, custom };

fn kind(name: []const u8) ToolKind {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "symbols")) return .symbols;
    if (std.mem.eql(u8, name, "edit")) return .edit;
    if (std.mem.eql(u8, name, "write")) return .write;
    return .custom;
}

pub fn displayForTool(name: []const u8) Display {
    return switch (kind(name)) {
        .bash => .{
            .presentation = .command,
            .collapse = .{ .mode = .tail, .lines_max = 5 },
            .shows_duration = true,
            .live_updates = .show_tail,
        },
        .read => .{
            .presentation = .file,
            .body_mode = .hidden_on_success,
            .collapse = .{ .mode = .head, .lines_max = 10 },
        },
        .symbols => .{
            .presentation = .symbols,
            .collapse = .{ .mode = .head, .lines_max = 10 },
        },
        .edit => .{
            .presentation = .patch,
            .collapse = .{ .mode = .head, .lines_max = 10 },
        },
        .write => .{
            .presentation = .file,
            .body_mode = .summary_only,
            .collapse = .{ .mode = .head, .lines_max = 10 },
            .live_updates = .suppress,
        },
        .custom => .{},
    };
}

pub fn callViewForValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !CallView {
    return .{
        .title = try titleForValue(allocator, name, value),
        .compact_title = try compactTitleForValue(allocator, name, value),
        .display = displayForTool(name),
        .body_update = try bodyUpdateForValue(allocator, name, value),
    };
}

pub fn partialCallView(allocator: std.mem.Allocator, name: []const u8, args_json_prefix: []const u8) !CallView {
    return .{
        .title = try partialTitleFor(allocator, name, args_json_prefix),
        .display = displayForTool(name),
        .body_update = try bodyUpdateForPartial(allocator, name, args_json_prefix),
    };
}

pub fn resultView(allocator: std.mem.Allocator, name: []const u8, is_error: bool, content: []const ai.ToolResultContent, details: ?std.json.Value) !ResultView {
    const output = try resultOutput(allocator, name, is_error, content, details);
    errdefer if (output) |value| allocator.free(value);

    var metadata_buffer: [metadata_bytes_max]u8 = undefined;
    const metadata = metadataForDetails(&metadata_buffer, name, details);
    const footer = if (metadata.len > 0) try allocator.dupe(u8, metadata) else null;
    return .{ .output = output, .footer = footer };
}

pub fn titleFor(allocator: std.mem.Allocator, name: []const u8, args_json_prefix: []const u8) ![]const u8 {
    return (try partialTitleFor(allocator, name, args_json_prefix)) orelse try allocator.dupe(u8, name);
}

pub fn partialTitleFor(allocator: std.mem.Allocator, name: []const u8, args_json_prefix: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        if (try stringFromPartialJson(allocator, args_json_prefix, &.{"command"})) |command| {
            defer allocator.free(command);
            return @as(?[]const u8, try commandTitle(allocator, command, null));
        }
    } else if (isPathTool(name)) {
        if (try stringFromPartialJson(allocator, args_json_prefix, &.{ "path", "file_path" })) |path| {
            defer allocator.free(path);
            return @as(?[]const u8, try pathTitle(allocator, name, path, null, null));
        }
    }
    return null;
}

pub fn titleForValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) ![]const u8 {
    var buffer: [title_bytes_max]u8 = undefined;
    const title = formatCallTitle(&buffer, name, value);
    if (title.len > 0) return allocator.dupe(u8, title);
    return allocator.dupe(u8, name);
}

pub fn compactTitleForValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !?[]const u8 {
    if (kind(name) != .read) return null;
    var buffer: [title_bytes_max]u8 = undefined;
    const title = formatCompactCallTitle(&buffer, name, value);
    return if (title.len > 0) @as(?[]const u8, try allocator.dupe(u8, title)) else null;
}

pub fn bodyUpdateForValue(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !BodyUpdate {
    if (kind(name) != .write) return .unchanged;
    const content = argString(value, "content") orelse return .unchanged;
    const body = trimTrailingEmptyLines(content);
    if (body.len == 0) return .clear;
    return .{ .replace = .{ .body = try allocator.dupe(u8, body) } };
}

pub fn bodyUpdateForPartial(allocator: std.mem.Allocator, name: []const u8, args_json_prefix: []const u8) !BodyUpdate {
    if (kind(name) != .write) return .unchanged;
    const content = (try stringFromPartialJson(allocator, args_json_prefix, &.{"content"})) orelse return .unchanged;
    defer allocator.free(content);
    const body = trimTrailingEmptyLines(content);
    if (body.len == 0) return .clear;
    return .{ .replace = .{ .body = try allocator.dupe(u8, body) } };
}

pub fn formatCallTitle(buffer: []u8, tool_name: []const u8, args_value: std.json.Value) []const u8 {
    var title: TitleBuilder = .{ .buffer = buffer };
    switch (kind(tool_name)) {
        .bash => {
            title.add("$ ");
            title.add(argStringOrEllipsis(args_value, "command"));
            if (argInt(args_value, "timeout")) |timeout| {
                title.add(" (timeout ");
                title.addInt(timeout);
                title.add("s)");
            }
        },
        .read => {
            title.add("read ");
            title.add(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
            addReadLineRange(&title, args_value);
        },
        .symbols, .edit, .write => {
            title.add(tool_name);
            title.add(" ");
            title.add(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
        },
        .custom => return "",
    }
    return title.slice();
}

pub fn formatCompactCallTitle(buffer: []u8, tool_name: []const u8, args_value: std.json.Value) []const u8 {
    if (kind(tool_name) != .read) return "";
    const classification = compactReadClassification(args_value) orelse return "";
    var title: TitleBuilder = .{ .buffer = buffer };
    switch (classification.kind) {
        .skill => {
            title.add("[skill] ");
            title.add(classification.label);
        },
        .docs => {
            title.add("read docs ");
            title.add(classification.label);
        },
        .resource => {
            title.add("read resource ");
            title.add(classification.label);
        },
    }
    addReadLineRange(&title, args_value);
    title.add(" (ctrl+o to expand)");
    return title.slice();
}

fn commandTitle(allocator: std.mem.Allocator, command: []const u8, timeout: ?i64) ![]const u8 {
    var buffer: [title_bytes_max]u8 = undefined;
    var title: TitleBuilder = .{ .buffer = buffer[0..] };
    title.add("$ ");
    title.add(command);
    if (timeout) |value| {
        title.add(" (timeout ");
        title.addInt(value);
        title.add("s)");
    }
    return allocator.dupe(u8, title.slice());
}

fn pathTitle(allocator: std.mem.Allocator, name: []const u8, path: []const u8, offset: ?i64, limit: ?i64) ![]const u8 {
    var buffer: [title_bytes_max]u8 = undefined;
    var title: TitleBuilder = .{ .buffer = buffer[0..] };
    title.add(name);
    title.add(" ");
    title.add(path);
    if (std.mem.eql(u8, name, "read")) addLineRange(&title, offset, limit);
    return allocator.dupe(u8, title.slice());
}

pub fn resultOutput(allocator: std.mem.Allocator, tool_name: []const u8, is_error: bool, content: []const ai.ToolResultContent, details: ?std.json.Value) !?[]u8 {
    const text = try formatResultContent(allocator, content, .{ .trim_trailing_empty_lines = shouldTrimResult(tool_name, is_error) });
    return resultOutputFromOwnedText(allocator, tool_name, is_error, text, details);
}

fn resultOutputFromOwnedText(allocator: std.mem.Allocator, tool_name: []const u8, is_error: bool, owned_text: ?[]u8, details: ?std.json.Value) !?[]u8 {
    var text = owned_text;
    errdefer if (text) |value| allocator.free(value);
    if (shouldHideSuccessfulToolResult(tool_name, is_error, details)) {
        if (text) |value| allocator.free(value);
        return null;
    }
    if (kind(tool_name) == .edit and !is_error) {
        if (details) |value| if (value == .object) if (value.object.get("diff")) |diff| if (diff == .string) {
            if (text) |owned| allocator.free(owned);
            text = null;
            return @as(?[]u8, try allocator.dupe(u8, diff.string));
        };
    }
    const output = text orelse return null;
    text = null;
    return @as(?[]u8, try normalizeResultOutput(allocator, tool_name, details, output));
}

pub fn shouldHideSuccessfulToolResult(tool_name: []const u8, is_error: bool, details: ?std.json.Value) bool {
    if (is_error) return false;
    if (kind(tool_name) != .write) return false;
    const value = details orelse return false;
    if (value != .object) return false;
    return jsonInt(value.object, "bytesWritten") != null;
}

const ResultFormatOptions = struct {
    trim_trailing_empty_lines: bool = false,
};

fn formatResultContent(allocator: std.mem.Allocator, content: []const ai.ToolResultContent, options: ResultFormatOptions) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |text_content| if (options.trim_trailing_empty_lines) trimTrailingEmptyLines(text_content.text) else text_content.text,
            .image => |image| imageFallbackText(image.mime_type),
        };
        if (text.len == 0) continue;
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(text);
        wrote_any = true;
    }
    if (!wrote_any) {
        writer.deinit();
        return null;
    }
    return @as(?[]u8, try writer.toOwnedSlice());
}

fn normalizeResultOutput(allocator: std.mem.Allocator, tool_name: []const u8, details: ?std.json.Value, owned_text: []u8) ![]u8 {
    errdefer allocator.free(owned_text);
    const body = try resultBodyFromDetails(allocator, tool_name, details, owned_text) orelse return owned_text;
    allocator.free(owned_text);
    return body;
}

fn resultBodyFromDetails(allocator: std.mem.Allocator, tool_name: []const u8, details: ?std.json.Value, text: []const u8) !?[]u8 {
    const value = details orelse return null;
    if (value != .object) return null;
    return switch (kind(tool_name)) {
        .bash => bashBodyFromDetails(allocator, value.object, text),
        .read => readBodyFromDetails(allocator, value.object, text),
        .symbols, .edit, .write, .custom => null,
    };
}

fn bashBodyFromDetails(allocator: std.mem.Allocator, object: std.json.ObjectMap, text: []const u8) !?[]u8 {
    const output = outputPrefixFromDetails(object, text) orelse return null;
    const trimmed = trimTrailingEmptyLines(output);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    if (trimmed.len > 0) {
        try writer.writer.writeAll(trimmed);
        wrote_any = true;
    }
    try writeBashStatus(&writer.writer, object, &wrote_any);
    return @as(?[]u8, try writer.toOwnedSlice());
}

fn readBodyFromDetails(allocator: std.mem.Allocator, object: std.json.ObjectMap, text: []const u8) !?[]u8 {
    const output = outputPrefixFromDetails(object, text) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, trimTrailingEmptyLines(output)));
}

fn outputPrefixFromDetails(object: std.json.ObjectMap, text: []const u8) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    const output_bytes = jsonInt(truncation, "outputBytes") orelse return null;
    if (output_bytes < 0) return null;
    const end = std.math.cast(usize, output_bytes) orelse return null;
    if (end > text.len) return null;
    return utf8Prefix(text, end);
}

fn writeBashStatus(writer: *std.Io.Writer, object: std.json.ObjectMap, wrote_any: *bool) !void {
    if (jsonInt(object, "exitCode")) |code| {
        if (code == 0) return;
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command exited with code {d}", .{code});
        return;
    }
    if (jsonBool(object, "timedOut") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("Command timed out");
        return;
    }
    if (jsonBool(object, "outputLimitExceeded") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("bash output limit exceeded");
        return;
    }
    if (jsonBool(object, "cancelled") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("Command aborted");
        return;
    }
    if (jsonInt(object, "signal")) |signal| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command killed by signal {d}", .{signal});
        return;
    }
    if (jsonInt(object, "stopped")) |signal| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command stopped by signal {d}", .{signal});
        return;
    }
    if (jsonInt(object, "unknown")) |code| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command exited with unknown status {d}", .{code});
    }
}

fn writeStatusSeparator(writer: *std.Io.Writer, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte('\n');
    wrote_any.* = true;
}

pub fn metadataForDetails(buffer: []u8, tool_name: []const u8, details: ?std.json.Value) []const u8 {
    const value = details orelse return "";
    if (value != .object) return "";
    return switch (kind(tool_name)) {
        .bash => bashMetadata(buffer, value.object) orelse "",
        .read => readMetadata(buffer, value.object) orelse "",
        .symbols, .edit, .write, .custom => "",
    };
}

fn bashMetadata(buffer: []u8, object: std.json.ObjectMap) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    if (!(jsonBool(truncation, "truncated") orelse false)) return null;
    const by = jsonString(truncation, "truncatedBy") orelse "";
    const output_lines = jsonInt(truncation, "outputLines") orelse 0;
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("Truncated: ") catch return null;
    if (std.mem.eql(u8, by, "lines")) {
        const total_lines = jsonInt(truncation, "totalLines") orelse 0;
        writer.print("showing {d} of {d} lines", .{ output_lines, total_lines }) catch return null;
    } else {
        const max_bytes = jsonInt(truncation, "maxBytes") orelse 0;
        writer.print("{d} lines shown (", .{output_lines}) catch return null;
        writeByteSize(&writer, max_bytes) catch return null;
        writer.writeAll(" limit)") catch return null;
    }
    return writer.buffered();
}

fn readMetadata(buffer: []u8, object: std.json.ObjectMap) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    const next_offset = jsonInt(object, "nextOffset");
    const first_line_exceeds = jsonBool(truncation, "firstLineExceedsLimit") orelse false;
    const truncated = jsonBool(truncation, "truncated") orelse false;
    const remaining = jsonInt(truncation, "remainingLines") orelse 0;
    var writer = std.Io.Writer.fixed(buffer);
    var wrote_chip = false;

    if ((jsonBool(truncation, "userLimit") orelse false) and remaining > 0) {
        writer.print("Limited: {d} more lines in file", .{remaining}) catch return null;
        if (next_offset) |offset| writer.print("; use offset={d} to continue", .{offset}) catch return null;
        wrote_chip = true;
    }

    if (first_line_exceeds or truncated) {
        if (wrote_chip) writer.writeAll(" • ") catch return null;
        if (first_line_exceeds) {
            const max_bytes = jsonInt(truncation, "maxBytes") orelse 0;
            writer.writeAll("Truncated: first line exceeds ") catch return null;
            writeByteSize(&writer, max_bytes) catch return null;
            writer.writeAll(" limit") catch return null;
        } else {
            const by = jsonString(truncation, "truncatedBy") orelse "";
            const output_lines = jsonInt(truncation, "outputLines") orelse 0;
            writer.writeAll("Truncated: ") catch return null;
            if (std.mem.eql(u8, by, "lines")) {
                const total_lines = jsonInt(truncation, "totalLines") orelse 0;
                writer.print("showing {d} of {d} lines", .{ output_lines, total_lines }) catch return null;
            } else {
                const max_bytes = jsonInt(truncation, "maxBytes") orelse 0;
                writer.print("{d} lines shown (", .{output_lines}) catch return null;
                writeByteSize(&writer, max_bytes) catch return null;
                writer.writeAll(" limit)") catch return null;
            }
            if (!wrote_chip) {
                if (next_offset) |offset| writer.print("; use offset={d} to continue", .{offset}) catch return null;
            }
        }
        wrote_chip = true;
    }

    if (!wrote_chip and remaining > 0) {
        writer.print("Limited: {d} more lines in file", .{remaining}) catch return null;
        if (next_offset) |offset| writer.print("; use offset={d} to continue", .{offset}) catch return null;
        wrote_chip = true;
    }

    return if (wrote_chip) writer.buffered() else null;
}

fn writeByteSize(writer: *std.Io.Writer, bytes: i64) !void {
    if (bytes > 0 and @mod(bytes, 1024) == 0) {
        try writer.print("{d}KB", .{@divTrunc(bytes, 1024)});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn shouldTrimResult(name: []const u8, is_error: bool) bool {
    if (is_error) return false;
    return switch (kind(name)) {
        .bash, .read, .write => true,
        .symbols, .edit, .custom => false,
    };
}

pub fn trimTrailingEmptyLines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] == '\n') {
        end -= 1;
        if (end > 0 and text[end - 1] == '\r') end -= 1;
    }
    return text[0..end];
}

fn utf8Prefix(text: []const u8, end: usize) []const u8 {
    var valid_end = end;
    while (valid_end > 0 and !std.unicode.utf8ValidateSlice(text[0..valid_end])) valid_end -= 1;
    return text[0..valid_end];
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn isPathTool(name: []const u8) bool {
    return switch (kind(name)) {
        .read, .symbols, .write, .edit => true,
        .bash, .custom => false,
    };
}

fn stringFromPartialJson(allocator: std.mem.Allocator, input: []const u8, keys: []const []const u8) !?[]const u8 {
    if (input.len == 0) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = partial_json.parse(arena.allocator(), input) catch return null;
    const value = parsed.value orelse return null;
    const found = stringFromValue(value, keys) orelse return null;
    return @as(?[]const u8, try allocator.dupe(u8, found));
}

fn stringFromValue(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    if (value != .object) return null;
    for (keys) |key| {
        const field = value.object.get(key) orelse continue;
        if (field == .string) return field.string;
    }
    return null;
}

const CompactReadKind = enum { skill, docs, resource };

const CompactReadClassification = struct {
    kind: CompactReadKind,
    label: []const u8,
};

fn compactReadClassification(args_value: std.json.Value) ?CompactReadClassification {
    const path = argString(args_value, "file_path") orelse argString(args_value, "path") orelse return null;
    const leaf = std.fs.path.basename(path);
    if (std.mem.eql(u8, leaf, "SKILL.md")) {
        const parent = if (std.fs.path.dirname(path)) |dirname| std.fs.path.basename(dirname) else leaf;
        return .{ .kind = .skill, .label = if (parent.len > 0) parent else leaf };
    }
    if (isCompactResourceLeaf(leaf)) return .{ .kind = .resource, .label = path };
    if (!std.fs.path.isAbsolute(path) and isCompactDocsPath(path)) return .{ .kind = .docs, .label = path };
    return null;
}

fn isCompactResourceLeaf(leaf: []const u8) bool {
    return std.mem.eql(u8, leaf, "AGENTS.md") or
        std.mem.eql(u8, leaf, "AGENTS.MD") or
        std.mem.eql(u8, leaf, "CLAUDE.md") or
        std.mem.eql(u8, leaf, "CLAUDE.MD");
}

fn isCompactDocsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "README.md") or
        std.mem.startsWith(u8, path, "docs/") or
        std.mem.startsWith(u8, path, "examples/");
}

fn addReadLineRange(title: *TitleBuilder, args_value: std.json.Value) void {
    addLineRange(title, argPositiveInt(args_value, "offset"), argPositiveInt(args_value, "limit"));
}

fn addLineRange(title: *TitleBuilder, offset: ?i64, limit: ?i64) void {
    if (offset == null and limit == null) return;
    const start = offset orelse 1;
    title.add(":");
    title.addInt(start);
    if (limit) |count| {
        title.add("-");
        title.addInt(start +| count -| 1);
    }
}

const TitleBuilder = struct {
    buffer: []u8,
    len: usize = 0,

    fn add(self: *TitleBuilder, text: []const u8) void {
        for (text) |byte| {
            if (self.len >= self.buffer.len) return;
            self.buffer[self.len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
            self.len += 1;
        }
    }

    fn addInt(self: *TitleBuilder, value: i64) void {
        var digits: [24]u8 = undefined;
        self.add(std.fmt.bufPrint(&digits, "{d}", .{value}) catch return);
    }

    fn slice(self: *const TitleBuilder) []const u8 {
        var end = self.len;
        while (end > 0 and !std.unicode.utf8ValidateSlice(self.buffer[0..end])) end -= 1;
        return self.buffer[0..end];
    }
};

fn argString(args_value: std.json.Value, key: []const u8) ?[]const u8 {
    if (args_value != .object) return null;
    const value = args_value.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn argStringOrEllipsis(args_value: std.json.Value, key: []const u8) []const u8 {
    return argString(args_value, key) orelse "...";
}

fn argPositiveInt(args_value: std.json.Value, key: []const u8) ?i64 {
    const value = argInt(args_value, key) orelse return null;
    return if (value > 0) value else null;
}

fn argInt(args_value: std.json.Value, key: []const u8) ?i64 {
    if (args_value != .object) return null;
    const value = args_value.object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn jsonObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

test "builtin display metadata covers tool chrome" {
    const bash = displayForTool("bash");
    try std.testing.expectEqual(Presentation.command, bash.presentation);
    try std.testing.expectEqual(CollapseMode.tail, bash.collapse.mode);
    try std.testing.expectEqual(@as(u8, 5), bash.collapse.lines_max);
    try std.testing.expect(bash.shows_duration);
    try std.testing.expectEqual(LiveUpdates.show_tail, bash.live_updates);

    const read = displayForTool("read");
    try std.testing.expectEqual(Presentation.file, read.presentation);
    try std.testing.expectEqual(BodyMode.hidden_on_success, read.body_mode);
    try std.testing.expectEqual(CollapseMode.head, read.collapse.mode);
    try std.testing.expectEqual(@as(u8, 10), read.collapse.lines_max);

    const symbols = displayForTool("symbols");
    try std.testing.expectEqual(Presentation.symbols, symbols.presentation);

    const edit = displayForTool("edit");
    try std.testing.expectEqual(Presentation.patch, edit.presentation);

    const write = displayForTool("write");
    try std.testing.expectEqual(BodyMode.summary_only, write.body_mode);
    try std.testing.expectEqual(CollapseMode.head, write.collapse.mode);
    try std.testing.expectEqual(@as(u8, 10), write.collapse.lines_max);
    try std.testing.expectEqual(LiveUpdates.suppress, write.live_updates);

    const unknown = displayForTool("custom");
    try std.testing.expectEqual(Presentation.generic, unknown.presentation);
}

test "tool titles use tolerant partial json" {
    const title = try titleFor(std.testing.allocator, "bash", "{\"command\":\"zig build\nnext");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("$ zig build next", title);

    const path_title = try titleFor(std.testing.allocator, "symbols", "{\"path\":\"src/main.zig\"}");
    defer std.testing.allocator.free(path_title);
    try std.testing.expectEqualStrings("symbols src/main.zig", path_title);
}

test "tool titles include ranges and compact read classes" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "docs/gen3-tui-plan.md" });
    try object.put(std.testing.allocator, "offset", .{ .integer = 5 });
    try object.put(std.testing.allocator, "limit", .{ .integer = 3 });
    const value = std.json.Value{ .object = object };

    const title = try titleForValue(std.testing.allocator, "read", value);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("read docs/gen3-tui-plan.md:5-7", title);

    const compact = (try compactTitleForValue(std.testing.allocator, "read", value)).?;
    defer std.testing.allocator.free(compact);
    try std.testing.expectEqualStrings("read docs docs/gen3-tui-plan.md:5-7 (ctrl+o to expand)", compact);
}

test "write call view seeds content preview body" {
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "src/file.zig" });
    try object.put(std.testing.allocator, "content", .{ .string = "one\ntwo\n" });
    const value = std.json.Value{ .object = object };

    const view = try callViewForValue(std.testing.allocator, "write", value);
    defer if (view.title) |title| std.testing.allocator.free(title);
    defer switch (view.body_update) {
        .replace => |replace| std.testing.allocator.free(replace.body),
        else => {},
    };
    try std.testing.expectEqualStrings("write src/file.zig", view.title.?);
    try std.testing.expectEqual(@as(std.meta.Tag(BodyUpdate), .replace), std.meta.activeTag(view.body_update));
    try std.testing.expectEqualStrings("one\ntwo", view.body_update.replace.body);
}

test "write partial call view streams content preview body" {
    const view = try partialCallView(std.testing.allocator, "write", "{\"path\":\"src/file.zig\",\"content\":\"one\\nt");
    defer if (view.title) |title| std.testing.allocator.free(title);
    defer switch (view.body_update) {
        .replace => |replace| std.testing.allocator.free(replace.body),
        else => {},
    };
    try std.testing.expectEqualStrings("write src/file.zig", view.title.?);
    try std.testing.expectEqual(@as(std.meta.Tag(BodyUpdate), .replace), std.meta.activeTag(view.body_update));
    try std.testing.expectEqualStrings("one\nt", view.body_update.replace.body);
}

test "tool result view uses edit diff details and write suppression" {
    var edit_details: std.json.ObjectMap = .empty;
    defer edit_details.deinit(std.testing.allocator);
    try edit_details.put(std.testing.allocator, "diff", .{ .string = "@@\n-old\n+new" });
    const edit_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "ok" } }};
    const edit_view = try resultView(std.testing.allocator, "edit", false, &edit_content, .{ .object = edit_details });
    defer if (edit_view.output) |output| std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("@@\n-old\n+new", edit_view.output.?);

    var write_details: std.json.ObjectMap = .empty;
    defer write_details.deinit(std.testing.allocator);
    try write_details.put(std.testing.allocator, "bytesWritten", .{ .integer = 10 });
    const write_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "PRIVATE" } }};
    const write_view = try resultView(std.testing.allocator, "write", false, &write_content, .{ .object = write_details });
    try std.testing.expect(write_view.output == null);
}

test "read truncation metadata becomes footer" {
    var truncation: std.json.ObjectMap = .empty;
    defer truncation.deinit(std.testing.allocator);
    try truncation.put(std.testing.allocator, "truncated", .{ .bool = true });
    try truncation.put(std.testing.allocator, "truncatedBy", .{ .string = "lines" });
    try truncation.put(std.testing.allocator, "outputLines", .{ .integer = 50 });
    try truncation.put(std.testing.allocator, "totalLines", .{ .integer = 200 });

    var details: std.json.ObjectMap = .empty;
    defer details.deinit(std.testing.allocator);
    try details.put(std.testing.allocator, "truncation", .{ .object = truncation });
    try details.put(std.testing.allocator, "nextOffset", .{ .integer = 51 });

    var buffer: [metadata_bytes_max]u8 = undefined;
    const metadata = metadataForDetails(&buffer, "read", .{ .object = details });
    try std.testing.expectEqualStrings("Truncated: showing 50 of 200 lines; use offset=51 to continue", metadata);
}
