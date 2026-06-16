//! Tool-call/result projection for the concrete TUI frontend.
//!
//! This is the only place where coding-agent tool names become transcript
//! presentation facts. The agent-agnostic TUI still receives dumb bounded
//! Transcript.Tool rows: title, body mode, collapse policy, output, footer.
const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");

const tool_metadata = coding_agent.tool_metadata;

pub const title_bytes_max = 160;
pub const metadata_bytes_max = 192;
pub const footer_bytes_max = 256;

const ToolKind = enum { bash, read, edit, write, grep, find, ls, custom };

fn kind(name: []const u8) ToolKind {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "edit")) return .edit;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "grep")) return .grep;
    if (std.mem.eql(u8, name, "find")) return .find;
    if (std.mem.eql(u8, name, "ls")) return .ls;
    return .custom;
}

pub const TitleBuffers = struct {
    title: [title_bytes_max]u8 = undefined,
    compact_title: [title_bytes_max]u8 = undefined,
};

pub const FinishView = struct {
    output: ?[]u8 = null,
    metadata: []const u8 = "",

    pub fn deinit(self: *FinishView, allocator: std.mem.Allocator) void {
        if (self.output) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub fn callAppend(
    buffers: *TitleBuffers,
    tool_call: ai.ToolCall,
    home_dir: ?[]const u8,
) tui.Transcript.Append.ToolAppend {
    return append(
        tool_call.id,
        tool_call.name,
        .pending,
        formatCallTitleWithHome(&buffers.title, tool_call.name, tool_call.arguments, home_dir),
        formatCompactCallTitle(&buffers.compact_title, tool_call.name, tool_call.arguments),
        false,
    );
}

pub fn startAppend(
    buffers: *TitleBuffers,
    payload: agent_mod.AgentEvent.ToolExecutionStart,
    home_dir: ?[]const u8,
) tui.Transcript.Append.ToolAppend {
    return append(
        payload.tool_call_id,
        payload.tool_name,
        .pending,
        formatCallTitleWithHome(&buffers.title, payload.tool_name, payload.args, home_dir),
        formatCompactCallTitle(&buffers.compact_title, payload.tool_name, payload.args),
        false,
    );
}

pub fn endAppend(payload: agent_mod.AgentEvent.ToolExecutionEnd) tui.Transcript.Append.ToolAppend {
    return append(
        payload.tool_call_id,
        payload.tool_name,
        if (payload.is_error) .err else .success,
        "",
        "",
        payload.is_error,
    );
}

pub fn finish(
    allocator: std.mem.Allocator,
    metadata_buffer: []u8,
    payload: agent_mod.AgentEvent.ToolExecutionEnd,
) !FinishView {
    return .{
        .output = try resultOutput(allocator, payload),
        .metadata = metadataForDetails(metadata_buffer, payload.tool_name, payload.result.details),
    };
}

pub fn append(
    tool_call_id: []const u8,
    name: []const u8,
    status: tui.Transcript.ToolStatus,
    title: []const u8,
    compact_title: []const u8,
    is_error: bool,
) tui.Transcript.Append.ToolAppend {
    return .{
        .tool_call_id = tool_call_id,
        .name = name,
        .presentation = presentation(name),
        .status = if (is_error) .err else status,
        .body_mode = bodyMode(name),
        .collapse = collapse(name),
        .title = title,
        .compact_title = compact_title,
    };
}

pub fn presentation(name: []const u8) tui.Transcript.ToolPresentation {
    return switch (tool_metadata.displayForTool(name).presentation) {
        .generic => .generic,
        .command => .command,
        .file => .file,
        .patch => .patch,
        .search => .search,
        .directory => .directory,
    };
}

pub fn bodyMode(name: []const u8) tui.Transcript.ToolBodyMode {
    return switch (tool_metadata.displayForTool(name).body_mode) {
        .visible => .visible,
        .hidden_on_success => .hidden_on_success,
    };
}

pub fn showsDuration(name: []const u8) bool {
    return tool_metadata.displayForTool(name).shows_duration;
}

pub fn callPreviewText(name: []const u8, args_value: std.json.Value) ?[]const u8 {
    if (kind(name) != .write) return null;
    const content = argString(args_value, "content") orelse return null;
    const preview = trimTrailingEmptyLines(content);
    return if (preview.len > 0) preview else null;
}

pub fn clearsCallPreviewOnStart(name: []const u8) bool {
    return kind(name) == .write;
}

pub fn firstResultText(content: []const ai.ToolResultContent) ?[]const u8 {
    for (content) |item| if (item == .text) return item.text.text;
    return null;
}

pub const NormalizedChunk = struct {
    text: []const u8,
    consumed: usize,
};

/// Presentation-only tool-output cleanup borrowed from pi-mono: CR is not a
/// printable row fact, and tabs become stable spaces before wrapping.
pub fn normalizedOutputChunk(buffer: []u8, text: []const u8) NormalizedChunk {
    var out: usize = 0;
    var consumed: usize = 0;
    for (text) |byte| {
        if (byte == '\r') {
            consumed += 1;
            continue;
        }
        const replacement = if (byte == '\t') "   " else text[consumed .. consumed + 1];
        if (out + replacement.len > buffer.len) break;
        @memcpy(buffer[out..][0..replacement.len], replacement);
        out += replacement.len;
        consumed += 1;
    }
    return .{ .text = buffer[0..out], .consumed = consumed };
}

pub fn durationChip(buffer: []u8, label: []const u8, elapsed_ms: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {d}.{d}s", .{
        label,
        elapsed_ms / std.time.ms_per_s,
        (elapsed_ms % std.time.ms_per_s) / 100,
    }) catch "";
}

pub fn joinMetadata(buffer: []u8, first: []const u8, second: []const u8) []const u8 {
    if (first.len == 0) return second;
    if (second.len == 0) return first;
    return std.fmt.bufPrint(buffer, "{s} • {s}", .{ first, second }) catch first;
}

pub fn resultOutput(
    allocator: std.mem.Allocator,
    payload: agent_mod.AgentEvent.ToolExecutionEnd,
) !?[]u8 {
    if (shouldHideSuccessfulToolResult(payload.tool_name, payload.is_error, payload.result.details)) return null;
    if (kind(payload.tool_name) == .edit and !payload.is_error) {
        if (payload.result.details) |details| {
            if (details == .object) {
                if (details.object.get("diff")) |diff| {
                    if (diff == .string) {
                        const copy = try allocator.dupe(u8, diff.string);
                        return copy;
                    }
                }
            }
        }
    }
    const text = try formatResultContent(allocator, payload.result.content, .{
        .trim_trailing_empty_lines = shouldTrimResult(payload.tool_name, payload.is_error),
    }) orelse return null;
    const normalized = try normalizeResultOutput(allocator, payload.tool_name, payload.result.details, text);
    return normalized;
}

pub fn metadataForDetails(
    buffer: []u8,
    tool_name: []const u8,
    details: ?std.json.Value,
) []const u8 {
    const value = details orelse return "";
    if (value != .object) return "";
    return switch (kind(tool_name)) {
        .bash => bashMetadata(buffer, value.object) orelse "",
        .read => readMetadata(buffer, value.object) orelse "",
        .grep => grepMetadata(buffer, value.object) orelse "",
        .find => entriesMetadata(buffer, value.object, "results") orelse "",
        .ls => entriesMetadata(buffer, value.object, "entries") orelse "",
        .edit, .write, .custom => "",
    };
}

pub fn formatCallTitle(buffer: []u8, tool_name: []const u8, args_value: std.json.Value) []const u8 {
    return formatCallTitleWithHome(buffer, tool_name, args_value, null);
}

pub fn formatCallTitleWithHome(
    buffer: []u8,
    tool_name: []const u8,
    args_value: std.json.Value,
    home_dir: ?[]const u8,
) []const u8 {
    var title: TitleBuilder = .{ .buffer = buffer, .home_dir = home_dir };
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
            title.addPath(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
            addReadLineRange(&title, args_value);
        },
        .edit, .write => {
            title.add(tool_name);
            title.add(" ");
            title.addPath(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
        },
        .ls => {
            title.add(tool_name);
            title.add(" ");
            title.addPath(argStringOrDefault(args_value, "path", "."));
            if (argPositiveInt(args_value, "limit")) |limit| {
                title.add(" (limit ");
                title.addInt(limit);
                title.add(")");
            }
        },
        .grep => {
            title.add("grep /");
            title.add(argStringOrEllipsis(args_value, "pattern"));
            title.add("/ in ");
            title.addPath(argStringOrDefault(args_value, "path", "."));
            if (argString(args_value, "glob")) |glob| {
                title.add(" (");
                title.add(glob);
                title.add(")");
            }
            if (argPositiveInt(args_value, "limit")) |limit| {
                title.add(" limit ");
                title.addInt(limit);
            }
        },
        .find => {
            title.add("find ");
            title.add(argString(args_value, "pattern") orelse argStringOrEllipsis(args_value, "name"));
            title.add(" in ");
            title.addPath(argStringOrDefault(args_value, "path", "."));
            if (argPositiveInt(args_value, "limit")) |limit| {
                title.add(" (limit ");
                title.addInt(limit);
                title.add(")");
            }
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

pub fn shouldHideSuccessfulToolResult(
    tool_name: []const u8,
    is_error: bool,
    details: ?std.json.Value,
) bool {
    if (is_error) return false;
    if (kind(tool_name) != .write) return false;
    const value = details orelse return false;
    if (value != .object) return false;
    return jsonInt(value.object, "bytesWritten") != null;
}

const ResultFormatOptions = struct {
    trim_trailing_empty_lines: bool = false,
};

fn formatResultContent(
    allocator: std.mem.Allocator,
    content: []const ai.ToolResultContent,
    options: ResultFormatOptions,
) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |text_content| if (options.trim_trailing_empty_lines)
                trimTrailingEmptyLines(text_content.text)
            else
                text_content.text,
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
    const text = try writer.toOwnedSlice();
    return text;
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn normalizeResultOutput(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    details: ?std.json.Value,
    owned_text: []u8,
) ![]u8 {
    errdefer allocator.free(owned_text);
    const body = stripToolSentinel(tool_name, details, owned_text);
    if (!body.changed) return owned_text;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    if (body.first.len > 0) {
        try writer.writer.writeAll(body.first);
        wrote_any = true;
    }
    if (body.second.len > 0) {
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(body.second);
    }
    allocator.free(owned_text);
    return writer.toOwnedSlice();
}

const ToolBody = struct {
    first: []const u8,
    second: []const u8 = "",
    changed: bool = false,
};

fn stripToolSentinel(tool_name: []const u8, details: ?std.json.Value, text: []const u8) ToolBody {
    const tool_kind = kind(tool_name);
    var metadata_buffer: [metadata_bytes_max]u8 = undefined;
    const has_metadata = metadataForDetails(&metadata_buffer, tool_name, details).len > 0;
    if (tool_kind == .bash and has_metadata) {
        if (stripBashTruncationFooter(text)) |body| return body;
    }
    if (tool_kind == .read and has_metadata) {
        if (stripReadFooter(text)) |body| return body;
    }
    const sentinel = switch (tool_kind) {
        .grep => "[grep truncated]",
        .find => "[find truncated]",
        .ls => "[listing truncated]",
        .bash, .read, .edit, .write, .custom => return .{ .first = text },
    };
    if (std.mem.endsWith(u8, text, sentinel) and has_metadata) {
        var end = text.len - sentinel.len;
        if (end > 0 and text[end - 1] == '\n') end -= 1;
        return .{ .first = trimTrailingEmptyLines(text[0..end]), .changed = true };
    }
    return .{ .first = text };
}

fn stripBashTruncationFooter(text: []const u8) ?ToolBody {
    const marker = "\n\n[Showing ";
    const start = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    const close_rel = std.mem.indexOfScalar(u8, text[start + marker.len ..], ']') orelse return null;
    const close = start + marker.len + close_rel + 1;
    var tail_start = close;
    while (tail_start < text.len and (text[tail_start] == '\n' or text[tail_start] == '\r')) tail_start += 1;
    return .{
        .first = trimTrailingEmptyLines(text[0..start]),
        .second = trimTrailingEmptyLines(text[tail_start..]),
        .changed = true,
    };
}

fn stripReadFooter(text: []const u8) ?ToolBody {
    if (std.mem.startsWith(u8, text, "[Line ")) return .{ .first = "", .changed = true };
    const marker = "\n\n[";
    const start = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    if (std.mem.indexOf(u8, text[start..], "Use offset=") == null and
        std.mem.indexOf(u8, text[start..], "more lines in file") == null)
    {
        return null;
    }
    return .{ .first = trimTrailingEmptyLines(text[0..start]), .changed = true };
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
    var writer = std.Io.Writer.fixed(buffer);
    if (first_line_exceeds) {
        const max_bytes = jsonInt(truncation, "maxBytes") orelse 0;
        writer.writeAll("First line exceeds ") catch return null;
        writeByteSize(&writer, max_bytes) catch return null;
        writer.writeAll(" limit") catch return null;
    } else if (jsonBool(truncation, "truncated") orelse false) {
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
    } else {
        const remaining = jsonInt(truncation, "remainingLines") orelse return null;
        if (remaining <= 0) return null;
        writer.print("{d} more lines in file", .{remaining}) catch return null;
    }
    if (next_offset) |offset| writer.print("; use offset={d} to continue", .{offset}) catch return null;
    return writer.buffered();
}

fn grepMetadata(buffer: []u8, object: std.json.ObjectMap) ?[]const u8 {
    const long_lines = jsonInt(object, "longLinesTruncated") orelse 0;
    const truncation = jsonObject(object, "truncation");
    const truncated = if (truncation) |trunc| jsonBool(trunc, "truncated") orelse false else false;
    if (!truncated and long_lines == 0) return null;

    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("Truncated: ") catch return null;
    var wrote_any = false;
    if (truncated) {
        writeTruncationReason(&writer, truncation.?, "matches", "matches") catch return null;
        wrote_any = true;
    }
    if (long_lines > 0) {
        if (wrote_any) writer.writeAll(", ") catch return null;
        writer.writeAll("some lines truncated") catch return null;
    }
    return writer.buffered();
}

fn entriesMetadata(
    buffer: []u8,
    object: std.json.ObjectMap,
    noun: []const u8,
) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    if (!(jsonBool(truncation, "truncated") orelse false)) return null;
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("Truncated: ") catch return null;
    writeTruncationReason(&writer, truncation, "entries", noun) catch return null;
    return writer.buffered();
}

fn writeTruncationReason(
    writer: *std.Io.Writer,
    truncation: std.json.ObjectMap,
    limit_key: []const u8,
    noun: []const u8,
) !void {
    const by = jsonString(truncation, "truncatedBy") orelse "";
    if (std.mem.eql(u8, by, limit_key)) {
        if (jsonInt(truncation, "maxEntries")) |limit| {
            try writer.print("{d} {s} limit", .{ limit, noun });
            return;
        }
        if (jsonInt(truncation, "maxMatches")) |limit| {
            try writer.print("{d} {s} limit", .{ limit, noun });
            return;
        }
    }
    if (std.mem.eql(u8, by, "bytes")) {
        if (jsonInt(truncation, "maxOutputBytes")) |max_bytes| {
            try writeByteSize(writer, max_bytes);
            try writer.writeAll(" output limit");
        } else {
            try writer.writeAll("output size limit");
        }
    } else if (std.mem.eql(u8, by, "file_size")) {
        if (jsonInt(truncation, "maxFileBytes")) |max_bytes| {
            try writeByteSize(writer, max_bytes);
            try writer.writeAll(" file size limit");
        } else {
            try writer.writeAll("file size limit");
        }
    } else if (std.mem.eql(u8, by, "files")) {
        try writer.writeAll("file scan limit");
    } else {
        try writer.writeAll("output limit");
    }
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
        .bash, .read, .grep, .find, .ls, .write => true,
        .edit, .custom => false,
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

fn collapse(name: []const u8) tui.Transcript.ToolCollapse {
    const metadata = tool_metadata.displayForTool(name).collapse;
    return .{
        .mode = switch (metadata.mode) {
            .head => .head,
            .tail => .tail,
        },
        .rows_max = metadata.rows_max,
    };
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
    const offset = argPositiveInt(args_value, "offset");
    const limit = argPositiveInt(args_value, "limit");
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
    home_dir: ?[]const u8 = null,
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

    fn addPath(self: *TitleBuilder, path: []const u8) void {
        const suffix = homePathSuffix(path, self.home_dir) orelse {
            self.add(path);
            return;
        };
        self.add("~");
        self.add(suffix);
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

fn argStringOrDefault(args_value: std.json.Value, key: []const u8, default: []const u8) []const u8 {
    return argString(args_value, key) orelse default;
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

fn homePathSuffix(path: []const u8, home_dir_raw: ?[]const u8) ?[]const u8 {
    const home_raw = home_dir_raw orelse return null;
    const home = trimTrailingPathSeparators(home_raw);
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return null;
    if (path.len == home.len) return "";
    if (!isPathSeparator(path[home.len])) return null;
    return path[home.len..];
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) end -= 1;
    return path[0..end];
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn testArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "tool output normalization removes carriage returns and expands tabs" {
    var buffer: [16]u8 = undefined;

    const chunk = normalizedOutputChunk(&buffer, "a\tb\rc");
    try std.testing.expectEqualStrings("a   bc", chunk.text);
    try std.testing.expectEqual(@as(usize, 5), chunk.consumed);

    const bounded = normalizedOutputChunk(buffer[0..5], "a\tb\tc");
    try std.testing.expectEqualStrings("a   b", bounded.text);
    try std.testing.expectEqual(@as(usize, 3), bounded.consumed);
}

test "formatCallTitle mirrors pi-mono call headers" {
    const allocator = std.testing.allocator;
    var buffer: [title_bytes_max]u8 = undefined;

    var bash_args = try testArgs(allocator, "{\"command\":\"ls -la\",\"timeout\":5}");
    defer bash_args.deinit();
    try std.testing.expectEqualStrings("$ ls -la (timeout 5s)", formatCallTitle(&buffer, "bash", bash_args.value));

    var read_args = try testArgs(allocator, "{\"path\":\"src/main.zig\",\"offset\":10,\"limit\":20}");
    defer read_args.deinit();
    try std.testing.expectEqualStrings("read src/main.zig:10-29", formatCallTitle(&buffer, "read", read_args.value));

    var read_file_path_args = try testArgs(
        allocator,
        "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\",\"offset\":-1,\"limit\":0}",
    );
    defer read_file_path_args.deinit();
    try std.testing.expectEqualStrings(
        "read src/file.zig",
        formatCallTitle(&buffer, "read", read_file_path_args.value),
    );

    var home_path_args = try testArgs(allocator, "{\"path\":\"/Users/me/repo/src/main.zig\"}");
    defer home_path_args.deinit();
    try std.testing.expectEqualStrings(
        "read ~/repo/src/main.zig",
        formatCallTitleWithHome(&buffer, "read", home_path_args.value, "/Users/me"),
    );

    var grep_args = try testArgs(allocator, "{\"pattern\":\"foo\",\"glob\":\"*.zig\",\"limit\":50}");
    defer grep_args.deinit();
    try std.testing.expectEqualStrings(
        "grep /foo/ in . (*.zig) limit 50",
        formatCallTitle(&buffer, "grep", grep_args.value),
    );

    var find_args = try testArgs(allocator, "{\"name\":\".zig\",\"path\":\"src\",\"limit\":25}");
    defer find_args.deinit();
    try std.testing.expectEqualStrings(
        "find .zig in src (limit 25)",
        formatCallTitle(&buffer, "find", find_args.value),
    );

    var ls_args = try testArgs(allocator, "{}");
    defer ls_args.deinit();
    try std.testing.expectEqualStrings("ls .", formatCallTitle(&buffer, "ls", ls_args.value));

    var write_args = try testArgs(allocator, "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\"}");
    defer write_args.deinit();
    try std.testing.expectEqualStrings(
        "write src/file.zig",
        formatCallTitle(&buffer, "write", write_args.value),
    );

    var edit_args = try testArgs(allocator, "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\"}");
    defer edit_args.deinit();
    try std.testing.expectEqualStrings(
        "edit src/file.zig",
        formatCallTitle(&buffer, "edit", edit_args.value),
    );
}

test "write call previews content until execution stream starts" {
    const allocator = std.testing.allocator;

    var write_args = try testArgs(allocator, "{\"path\":\"file.txt\",\"content\":\"one\\ntwo\\n\"}");
    defer write_args.deinit();
    try std.testing.expectEqualStrings("one\ntwo", callPreviewText("write", write_args.value).?);
    try std.testing.expect(clearsCallPreviewOnStart("write"));
    try std.testing.expect(callPreviewText("read", write_args.value) == null);
}

test "successful write result is hidden so streamed content remains visible" {
    const allocator = std.testing.allocator;
    var details = try testArgs(allocator, "{\"bytesWritten\":5,\"path\":\"file.txt\"}");
    defer details.deinit();
    try std.testing.expect(shouldHideSuccessfulToolResult("write", false, details.value));
    try std.testing.expect(!shouldHideSuccessfulToolResult("write", true, details.value));
    try std.testing.expect(!shouldHideSuccessfulToolResult("read", false, details.value));
}

test "tool result display joins text and image fallback" {
    const content = [_]ai.ToolResultContent{
        .{ .text = .{ .text = "Read image file [image/png]\n" } },
        .{ .image = .{ .data = "base64", .mime_type = "image/png" } },
    };
    const text = try formatResultContent(std.testing.allocator, &content, .{
        .trim_trailing_empty_lines = true,
    }) orelse return error.ExpectedText;
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Read image file [image/png]\n[Image: image/png]", text);
}

test "tool display moves truncation sentinels into metadata" {
    const allocator = std.testing.allocator;
    var grep_details = try testArgs(
        allocator,
        "{\"longLinesTruncated\":1,\"truncation\":{\"truncated\":true,\"truncatedBy\":\"matches\",\"maxMatches\":2}}",
    );
    defer grep_details.deinit();

    var metadata_buffer: [metadata_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Truncated: 2 matches limit, some lines truncated",
        metadataForDetails(&metadata_buffer, "grep", grep_details.value),
    );

    const raw = try allocator.dupe(u8, "a.zig:1: foo\n[grep truncated]");
    const text = try normalizeResultOutput(allocator, "grep", grep_details.value, raw);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("a.zig:1: foo", text);
}

test "tool metadata formats grep byte and file-size truncation warnings" {
    const allocator = std.testing.allocator;
    var metadata_buffer: [metadata_bytes_max]u8 = undefined;

    var bytes_details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"bytes\",\"maxOutputBytes\":51200}}",
    );
    defer bytes_details.deinit();
    try std.testing.expectEqualStrings(
        "Truncated: 50KB output limit",
        metadataForDetails(&metadata_buffer, "grep", bytes_details.value),
    );

    var file_details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"file_size\",\"maxFileBytes\":262144}}",
    );
    defer file_details.deinit();
    try std.testing.expectEqualStrings(
        "Truncated: 256KB file size limit",
        metadataForDetails(&metadata_buffer, "grep", file_details.value),
    );
}

test "bash display strips core truncation footer and reports metadata" {
    const allocator = std.testing.allocator;
    var metadata_buffer: [metadata_bytes_max]u8 = undefined;
    var details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"lines\"," ++
            "\"outputLines\":5,\"totalLines\":100,\"maxBytes\":51200}}",
    );
    defer details.deinit();

    const raw = try allocator.dupe(
        u8,
        "line 96\nline 100\n\n[Showing lines 96-100 of 100 (50KB limit)]\n\nCommand exited with code 1",
    );
    const text = try normalizeResultOutput(allocator, "bash", details.value, raw);
    defer allocator.free(text);

    try std.testing.expectEqualStrings("line 96\nline 100\nCommand exited with code 1", text);
    try std.testing.expectEqualStrings(
        "Truncated: showing 5 of 100 lines",
        metadataForDetails(&metadata_buffer, "bash", details.value),
    );
}

test "read display trims trailing empty lines" {
    try std.testing.expectEqualStrings("one", trimTrailingEmptyLines("one\n"));
    try std.testing.expectEqualStrings("one", trimTrailingEmptyLines("one\n\n"));
    try std.testing.expectEqualStrings("one\ntwo", trimTrailingEmptyLines("one\ntwo"));
}

test "formatCompactCallTitle mirrors pi-mono read resource headers" {
    const allocator = std.testing.allocator;
    var buffer: [title_bytes_max]u8 = undefined;

    var skill_args = try testArgs(allocator, "{\"path\":\".zi/skills/review/SKILL.md\",\"limit\":10}");
    defer skill_args.deinit();
    try std.testing.expectEqualStrings(
        "[skill] review:1-10 (ctrl+o to expand)",
        formatCompactCallTitle(&buffer, "read", skill_args.value),
    );

    var resource_args = try testArgs(allocator, "{\"path\":\"AGENTS.md\"}");
    defer resource_args.deinit();
    try std.testing.expectEqualStrings(
        "read resource AGENTS.md (ctrl+o to expand)",
        formatCompactCallTitle(&buffer, "read", resource_args.value),
    );

    var regular_args = try testArgs(allocator, "{\"path\":\"src/main.zig\"}");
    defer regular_args.deinit();
    try std.testing.expectEqualStrings("", formatCompactCallTitle(&buffer, "read", regular_args.value));
}

test "only process tools show duration footer" {
    try std.testing.expect(showsDuration("bash"));
    try std.testing.expect(!showsDuration("read"));
    try std.testing.expect(!showsDuration("grep"));
}

test "formatCallTitle shows ellipsis while args stream and sanitizes newlines" {
    const allocator = std.testing.allocator;
    var buffer: [title_bytes_max]u8 = undefined;

    var empty_args = try testArgs(allocator, "{}");
    defer empty_args.deinit();
    try std.testing.expectEqualStrings("$ ...", formatCallTitle(&buffer, "bash", empty_args.value));
    try std.testing.expectEqualStrings("", formatCallTitle(&buffer, "mystery", empty_args.value));

    var multiline_args = try testArgs(allocator, "{\"command\":\"echo a\\necho b\"}");
    defer multiline_args.deinit();
    try std.testing.expectEqualStrings("$ echo a echo b", formatCallTitle(&buffer, "bash", multiline_args.value));
}

test "metadata chips join with bullets" {
    var buffer: [footer_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("Took 0.1s", joinMetadata(&buffer, "", "Took 0.1s"));
    try std.testing.expectEqualStrings("Truncated: x", joinMetadata(&buffer, "Truncated: x", ""));
    try std.testing.expectEqualStrings(
        "Truncated: x • Took 0.1s",
        joinMetadata(&buffer, "Truncated: x", "Took 0.1s"),
    );
}
