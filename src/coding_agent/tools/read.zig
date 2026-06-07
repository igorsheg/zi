const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_read_bytes = 1024 * 1024;
pub const max_output_bytes = tool_output_policy.default_max_bytes;
pub const max_output_lines = tool_output_policy.default_max_lines;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to read (relative or absolute)" },
    \\    "offset": { "type": "integer", "description": "Line number to start reading from (1-indexed)" },
    \\    "limit": { "type": "integer", "description": "Maximum number of lines to read" }
    \\  },
    \\  "required": ["path"]
    \\}
;

pub const ReadTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_read_bytes: usize = max_read_bytes,
        max_output_bytes: usize = max_output_bytes,
        max_output_lines: usize = max_output_lines,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !ReadTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
                .max_read_bytes = config.max_read_bytes,
                .max_output_bytes = config.max_output_bytes,
                .max_output_lines = config.max_output_lines,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *ReadTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *ReadTool) agent.AgentTool {
        return .{
            .name = "read",
            .description = "Read the contents of a file. Supports text files. " ++
                "Output is truncated to 2000 lines or 50KB (whichever is hit first). " ++
                "Use offset/limit for large files. When you need the full file, continue with offset until complete.",
            .parameters = self.parsed_parameters.value,
            .label = "read",
            .execute = .{ .context = self, .call_fn = execute },
        };
    }
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *agent.ToolRuntime,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *ReadTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(params);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    const content = try std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(self.config.max_read_bytes),
    );
    defer allocator.free(content);
    try token.throwIfRequested();

    if (detectImageMimeType(resolved_path, content)) |mime_type| {
        return imageReadResult(allocator, content, mime_type);
    }
    if (!std.unicode.utf8ValidateSlice(content)) {
        return invalidUtf8ReadResult(allocator);
    }

    const formatted = try formatReadOutput(allocator, self.config, args, content);
    errdefer formatted.deinit(allocator);
    const text = formatted.text;
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{
        .allocator = allocator,
        .result = .{ .content = result_content, .details = try formatted.details(allocator) },
    };
}

const ReadArgs = struct {
    path: []const u8,
    offset: ?usize,
    limit: ?usize,
};

fn invalidUtf8ReadResult(allocator: std.mem.Allocator) !agent.ToolExecutionResult {
    const text = try allocator.dupe(u8, "[File omitted: content is not valid UTF-8 text.]");
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{
        .allocator = allocator,
        .result = .{ .content = result_content, .details = null },
    };
}

fn imageReadResult(
    allocator: std.mem.Allocator,
    content: []const u8,
    mime_type: []const u8,
) !agent.ToolExecutionResult {
    const encoded_len = std.base64.standard.Encoder.calcSize(content.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, content);

    const note = try std.fmt.allocPrint(allocator, "Read image file [{s}]", .{mime_type});
    errdefer allocator.free(note);
    const mime = try allocator.dupe(u8, mime_type);
    errdefer allocator.free(mime);

    const result_content = try allocator.alloc(ai.ToolResultContent, 2);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = note } };
    result_content[1] = .{ .image = .{ .data = encoded, .mime_type = mime } };
    return .{
        .allocator = allocator,
        .result = .{ .content = result_content, .details = null },
    };
}

fn detectImageMimeType(path: []const u8, content: []const u8) ?[]const u8 {
    if (hasPrefix(content, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (hasPrefix(content, "GIF87a") or hasPrefix(content, "GIF89a")) return "image/gif";
    if (content.len >= 3 and content[0] == 0xff and content[1] == 0xd8 and content[2] == 0xff) return "image/jpeg";
    if (isWebp(content)) return "image/webp";

    if (std.ascii.endsWithIgnoreCase(path, ".png")) return "image/png";
    if (std.ascii.endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (std.ascii.endsWithIgnoreCase(path, ".jpg")) return "image/jpeg";
    if (std.ascii.endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (std.ascii.endsWithIgnoreCase(path, ".webp")) return "image/webp";
    return null;
}

fn hasPrefix(content: []const u8, prefix: []const u8) bool {
    return content.len >= prefix.len and std.mem.eql(u8, content[0..prefix.len], prefix);
}

fn isWebp(content: []const u8) bool {
    return content.len >= 12 and
        std.mem.eql(u8, content[0..4], "RIFF") and
        std.mem.eql(u8, content[8..12], "WEBP");
}

fn parseArgs(params: std.json.Value) !ReadArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;
    return .{
        .path = path_value.string,
        .offset = try optionalPositiveInteger(params.object.get("offset")),
        .limit = try optionalPositiveInteger(params.object.get("limit")),
    };
}

fn optionalPositiveInteger(value: ?std.json.Value) !?usize {
    const raw = value orelse return null;
    if (raw != .integer or raw.integer < 1) return error.InvalidToolArguments;
    return std.math.cast(usize, raw.integer) orelse error.InvalidToolArguments;
}

const ReadTruncatedBy = enum { lines, bytes };

const FormattedReadOutput = struct {
    text: []const u8,
    truncated: bool,
    user_limit: bool,
    truncated_by: ReadTruncatedBy,
    first_line_exceeds_limit: bool,
    output_lines: usize,
    remaining_lines: usize,
    total_lines: usize,
    total_bytes: usize,
    output_bytes: usize,
    max_bytes: usize,
    max_lines: usize,
    next_offset: ?usize,

    fn deinit(self: FormattedReadOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }

    fn details(self: FormattedReadOutput, allocator: std.mem.Allocator) !?std.json.Value {
        if (!self.truncated and !self.user_limit and self.next_offset == null) return null;
        var object: std.json.ObjectMap = .empty;
        errdefer object.deinit(allocator);
        var truncation: std.json.ObjectMap = .empty;
        errdefer truncation.deinit(allocator);
        try path_utils.putJsonField(allocator, &truncation, "truncated", .{ .bool = self.truncated });
        try path_utils.putJsonField(allocator, &truncation, "userLimit", .{ .bool = self.user_limit });
        try path_utils.putJsonStringField(allocator, &truncation, "truncatedBy", switch (self.truncated_by) {
            .lines => "lines",
            .bytes => "bytes",
        });
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "firstLineExceedsLimit",
            .{ .bool = self.first_line_exceeds_limit },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "outputLines",
            .{ .integer = @intCast(self.output_lines) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "remainingLines",
            .{ .integer = @intCast(self.remaining_lines) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "totalLines",
            .{ .integer = @intCast(self.total_lines) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "totalBytes",
            .{ .integer = @intCast(self.total_bytes) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "outputBytes",
            .{ .integer = @intCast(self.output_bytes) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "maxBytes",
            .{ .integer = @intCast(self.max_bytes) },
        );
        try path_utils.putJsonField(
            allocator,
            &truncation,
            "maxLines",
            .{ .integer = @intCast(self.max_lines) },
        );
        if (self.next_offset) |next_offset| {
            try path_utils.putJsonField(allocator, &object, "nextOffset", .{ .integer = @intCast(next_offset) });
        }
        try path_utils.putJsonField(allocator, &object, "truncation", .{ .object = truncation });
        return .{ .object = object };
    }
};

fn formatReadOutput(
    allocator: std.mem.Allocator,
    config: ReadTool.Config,
    args: ReadArgs,
    content: []const u8,
) !FormattedReadOutput {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    const start_line = args.offset orelse 1;
    var current_line: usize = 1;
    var emitted_lines: usize = 0;
    var last_emitted_line: ?usize = null;
    var bytes_written: usize = 0;
    var remaining_lines: usize = 0;
    var total_lines: usize = 0;
    var skipped_to_start = false;
    var first_line_exceeds_limit = false;
    var user_limit = false;
    var output_truncated = false;
    var truncated_by: ReadTruncatedBy = .lines;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (current_line += 1) {
        total_lines += 1;
        if (current_line < start_line) continue;
        skipped_to_start = true;
        if (args.limit) |limit| if (emitted_lines == limit) {
            user_limit = true;
            remaining_lines += 1;
            continue;
        };
        if (emitted_lines == config.max_output_lines) {
            output_truncated = true;
            truncated_by = .lines;
            remaining_lines += 1;
            continue;
        }
        if (bytes_written + line.len + 1 > config.max_output_bytes) {
            output_truncated = true;
            truncated_by = .bytes;
            if (emitted_lines == 0) first_line_exceeds_limit = true;
            remaining_lines += 1;
            continue;
        }
        if (emitted_lines > 0) {
            try writer.writer.writeByte('\n');
            bytes_written += 1;
        }
        try writer.writer.writeAll(line);
        bytes_written += line.len;
        emitted_lines += 1;
        last_emitted_line = current_line;
    }

    if (!skipped_to_start) return error.OffsetBeyondEndOfFile;
    const next_offset = if (remaining_lines > 0 and last_emitted_line != null) last_emitted_line.? + 1 else null;
    if (first_line_exceeds_limit) {
        var size_buffer: [32]u8 = undefined;
        try writer.writer.print(
            "[Line {d} exceeds {s} limit. Use bash: sed -n '{d}p' {s} | head -c {d}]",
            .{
                start_line,
                formatSize(&size_buffer, config.max_output_bytes),
                start_line,
                args.path,
                config.max_output_bytes,
            },
        );
    } else if (next_offset) |offset| {
        if (output_truncated) {
            const end_line = offset - 1;
            if (truncated_by == .bytes) {
                var size_buffer: [32]u8 = undefined;
                try writer.writer.print(
                    "\n\n[Showing lines {d}-{d} of {d} ({s} limit). Use offset={d} to continue.]",
                    .{
                        start_line,
                        end_line,
                        total_lines,
                        formatSize(&size_buffer, config.max_output_bytes),
                        offset,
                    },
                );
            } else {
                try writer.writer.print(
                    "\n\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
                    .{ start_line, end_line, total_lines, offset },
                );
            }
        } else {
            try writer.writer.print(
                "\n\n[{d} more lines in file. Use offset={d} to continue.]",
                .{ remaining_lines, offset },
            );
        }
    }
    return .{
        .text = try writer.toOwnedSlice(),
        .truncated = output_truncated,
        .user_limit = user_limit,
        .truncated_by = truncated_by,
        .first_line_exceeds_limit = first_line_exceeds_limit,
        .output_lines = emitted_lines,
        .remaining_lines = remaining_lines,
        .total_lines = total_lines,
        .total_bytes = content.len,
        .output_bytes = bytes_written,
        .max_bytes = config.max_output_bytes,
        .max_lines = config.max_output_lines,
        .next_offset = next_offset,
    };
}

fn formatSize(buffer: []u8, bytes: usize) []const u8 {
    if (bytes >= 1024 and bytes % 1024 == 0) {
        return std.fmt.bufPrint(buffer, "{d}KB", .{bytes / 1024}) catch "limit";
    }
    return std.fmt.bufPrint(buffer, "{d}B", .{bytes}) catch "limit";
}

test "read tool reads bounded text with offset and limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "one\ntwo\nthree\nfour" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer read_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "offset", .{ .integer = 2 });
    try object.put(std.testing.allocator, "limit", .{ .integer = 2 });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &read_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "two\nthree\n\n[1 more lines in file. Use offset=4 to continue.]",
        result.result.content[0].text.text,
    );
    const truncation = result.result.details.?.object.get("truncation").?.object;
    try std.testing.expect(!truncation.get("truncated").?.bool);
    try std.testing.expect(truncation.get("userLimit").?.bool);
    try std.testing.expectEqual(@as(i64, 4), truncation.get("totalLines").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_lines), truncation.get("maxLines").?.integer);
    try std.testing.expectEqual(@as(i64, 18), truncation.get("totalBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 9), truncation.get("outputBytes").?.integer);
    try std.testing.expectEqual(@as(i64, max_output_bytes), truncation.get("maxBytes").?.integer);
}

test "read tool omits invalid utf8 text operationally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/binary.dat", .data = "ok\xffbad" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer read_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "binary.dat" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &read_tool,
        cancel_source.token(),
        "call-invalid-utf8",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[File omitted: content is not valid UTF-8 text.]",
        result.result.content[0].text.text,
    );
}

test "read tool returns image attachment for supported image file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const png_header = "\x89PNG\r\n\x1a\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/image.png", .data = png_header });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer read_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "image.png" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &read_tool,
        cancel_source.token(),
        "call-image",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result.content.len);
    try std.testing.expectEqualStrings("Read image file [image/png]", result.result.content[0].text.text);
    try std.testing.expectEqualStrings("image/png", result.result.content[1].image.mime_type);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", result.result.content[1].image.data);
}

test "read tool reports pi-style automatic truncation ranges" {
    const formatted = try formatReadOutput(
        std.testing.allocator,
        .{ .cwd = "/repo", .max_output_lines = 2, .max_output_bytes = 100 },
        .{ .path = "file.txt", .offset = null, .limit = null },
        "one\ntwo\nthree\nfour",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "one\ntwo\n\n[Showing lines 1-2 of 4. Use offset=3 to continue.]",
        formatted.text,
    );
}

test "read tool reports pi-style byte truncation ranges" {
    const formatted = try formatReadOutput(
        std.testing.allocator,
        .{ .cwd = "/repo", .max_output_lines = 20, .max_output_bytes = 8 },
        .{ .path = "file.txt", .offset = 2, .limit = null },
        "skip\none\ntwo\nthree",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "one\ntwo\n\n[Showing lines 2-3 of 4 (8B limit). Use offset=4 to continue.]",
        formatted.text,
    );
}

test "read full untruncated file has no details" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "one\ntwo" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer read_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &read_tool,
        cancel_source.token(),
        "call-full",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("one\ntwo", result.result.content[0].text.text);
    try std.testing.expect(result.result.details == null);
}

test "read tool can reject paths outside cwd by config" {
    try std.testing.expect(path_utils.isPathInside("/repo/", "/repo/file.txt"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/app");
    try tmp.dir.createDirPath(std.testing.io, "repo/other");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/other/file.txt", .data = "x" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo/app", &cwd_buffer);
    try std.testing.expectError(error.PathOutsideCwd, path_utils.resolveExistingPath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd_buffer[0..cwd], .allow_paths_outside_cwd = false },
        "../other/file.txt",
    ));
}

test "read tool reports first line exceeding output limit" {
    const formatted = try formatReadOutput(
        std.testing.allocator,
        .{ .cwd = "/repo", .max_output_bytes = 3 },
        .{ .path = "file.txt", .offset = null, .limit = null },
        "abcdef\nsecond",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expect(formatted.first_line_exceeds_limit);
    try std.testing.expectEqual(@as(?usize, null), formatted.next_offset);
    try std.testing.expectEqualStrings(
        "[Line 1 exceeds 3B limit. Use bash: sed -n '1p' file.txt | head -c 3]",
        formatted.text,
    );
    const details = (try formatted.details(std.testing.allocator)).?;
    defer agent.deinitJsonValue(std.testing.allocator, details);
    const truncation = details.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", truncation.get("truncatedBy").?.string);
}

test "read tool rejects offset beyond end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "one" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer read_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "offset", .{ .integer = 3 });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    try std.testing.expectError(error.OffsetBeyondEndOfFile, execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &read_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    ));
}
