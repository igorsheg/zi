const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const paths_mod = @import("../paths.zig");
const test_support = @import("test_support.zig");
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
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = false,
        max_read_bytes: usize = max_read_bytes,
        max_output_bytes: usize = max_output_bytes,
        max_output_lines: usize = max_output_lines,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !ReadTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const home_dir = if (config.home_dir) |path| try allocator.dupe(u8, path) else null;
        errdefer if (home_dir) |path| allocator.free(path);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        var owned_config = config;
        owned_config.cwd = cwd;
        owned_config.home_dir = home_dir;
        return .{
            .allocator = allocator,
            .config = owned_config,
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *ReadTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *ReadTool) agent.AgentTool {
        return .{
            .name = "read",
            .description = "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). " ++
                "Images are sent as attachments. For text files, output is truncated to 2000 lines " ++
                "or 50KB (whichever is hit first). Use offset/limit for large files. " ++
                "When you need the full file, continue with offset until complete.",
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
    const args = parseArgs(params) catch |err| switch (err) {
        error.InvalidToolArguments => return readErrorResult(
            allocator,
            "invalid_arguments",
            "Invalid read arguments: provide path/file_path and positive offset/limit integers.",
        ),
    };
    const resolved_path = try paths_mod.ToolPaths.resolveExisting(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
    }, args.path);
    defer allocator.free(resolved_path);

    const content = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(self.config.max_read_bytes),
    ) catch |err| switch (err) {
        error.FileTooBig, error.StreamTooLong => return readTooLargeResult(allocator, self.config.max_read_bytes),
        else => return err,
    };
    defer allocator.free(content);
    try token.throwIfRequested();

    if (detectImageMimeType(resolved_path, content)) |mime_type| {
        return imageReadResult(allocator, content, mime_type);
    }
    if (!std.unicode.utf8ValidateSlice(content)) {
        return path_utils.textResult(allocator, "[File omitted: content is not valid UTF-8 text.]", null);
    }

    const formatted = try formatReadOutput(allocator, self.config, args, content);
    errdefer formatted.deinit(allocator);
    const details = try formatted.details(allocator);
    return path_utils.ownedTextResult(allocator, formatted.text, details);
}

const ReadArgs = struct {
    path: []const u8,
    offset: ?usize,
    limit: ?usize,
};

fn readErrorResult(
    allocator: std.mem.Allocator,
    reason: []const u8,
    message: []const u8,
) !agent.ToolExecutionResult {
    const details = try path_utils.jsonDetails(allocator, .{
        .isError = true,
        .reason = reason,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.textResult(allocator, message, details);
}

fn readTooLargeResult(allocator: std.mem.Allocator, max_bytes: usize) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "Read failed: file exceeds the {d} byte read limit.",
        .{max_bytes},
    );
    errdefer allocator.free(message);
    const details = try path_utils.jsonDetails(allocator, .{
        .isError = true,
        .reason = @as([]const u8, "file_too_large"),
        .maxBytes = max_bytes,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, message, details);
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
    _ = path;
    if (isJpeg(content)) return "image/jpeg";
    if (isPng(content)) return "image/png";
    if (hasPrefix(content, "GIF")) return "image/gif";
    if (isWebp(content)) return "image/webp";
    return null;
}

fn hasPrefix(content: []const u8, prefix: []const u8) bool {
    return content.len >= prefix.len and std.mem.eql(u8, content[0..prefix.len], prefix);
}

fn isJpeg(content: []const u8) bool {
    return content.len >= 4 and
        content[0] == 0xff and
        content[1] == 0xd8 and
        content[2] == 0xff and
        content[3] != 0xf7;
}

fn isPng(content: []const u8) bool {
    return content.len >= 16 and
        hasPrefix(content, "\x89PNG\r\n\x1a\n") and
        readU32Be(content, 8) == 13 and
        std.mem.eql(u8, content[12..16], "IHDR") and
        !isAnimatedPng(content);
}

fn isAnimatedPng(content: []const u8) bool {
    var offset: usize = 8;
    while (offset + 8 <= content.len) {
        const chunk_len = readU32Be(content, offset);
        const chunk_type = content[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, chunk_type, "acTL")) return true;
        if (std.mem.eql(u8, chunk_type, "IDAT")) return false;

        const next = offset + 8 + @as(usize, chunk_len) + 4;
        if (next <= offset or next > content.len) return false;
        offset = next;
    }
    return false;
}

fn readU32Be(content: []const u8, offset: usize) u32 {
    return (@as(u32, content[offset]) << 24) |
        (@as(u32, content[offset + 1]) << 16) |
        (@as(u32, content[offset + 2]) << 8) |
        @as(u32, content[offset + 3]);
}

fn isWebp(content: []const u8) bool {
    return content.len >= 12 and
        std.mem.eql(u8, content[0..4], "RIFF") and
        std.mem.eql(u8, content[8..12], "WEBP");
}

fn parseArgs(params: std.json.Value) !ReadArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse params.object.get("file_path") orelse
        return error.InvalidToolArguments;
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
    offset_beyond_eof: bool,
    requested_offset: usize,
    first_line_exceeds_limit: bool,
    first_line_bytes: usize,
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
        if (self.offset_beyond_eof) {
            const value = try path_utils.jsonDetails(allocator, .{
                .isError = true,
                .reason = @as([]const u8, "offset_beyond_eof"),
                .offset = self.requested_offset,
                .totalLines = self.total_lines,
            });
            return value;
        }
        if (!self.truncated and !self.user_limit and self.next_offset == null) return null;
        const value = try path_utils.jsonDetails(allocator, .{
            .nextOffset = self.next_offset,
            .truncation = try path_utils.jsonDetails(allocator, .{
                .truncated = self.truncated,
                .userLimit = self.user_limit,
                .truncatedBy = @as([]const u8, switch (self.truncated_by) {
                    .lines => "lines",
                    .bytes => "bytes",
                }),
                .firstLineExceedsLimit = self.first_line_exceeds_limit,
                .firstLineBytes = if (self.first_line_bytes > 0) self.first_line_bytes else null,
                .outputLines = self.output_lines,
                .remainingLines = self.remaining_lines,
                .totalLines = self.total_lines,
                .totalBytes = self.total_bytes,
                .outputBytes = self.output_bytes,
                .maxBytes = self.max_bytes,
                .maxLines = self.max_lines,
            }),
        });
        return value;
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
    var offset_beyond_eof = false;
    var first_line_exceeds_limit = false;
    var first_line_bytes: usize = 0;
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
        const separator_bytes: usize = if (emitted_lines == 0) 0 else 1;
        if (bytes_written + separator_bytes + line.len > config.max_output_bytes) {
            output_truncated = true;
            truncated_by = .bytes;
            if (emitted_lines == 0) {
                first_line_exceeds_limit = true;
                first_line_bytes = line.len;
            }
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

    if (!skipped_to_start) {
        offset_beyond_eof = true;
        try writer.writer.print(
            "[Offset {d} is beyond end of file ({d} lines total).]",
            .{ start_line, total_lines },
        );
    }
    const next_offset = if (remaining_lines > 0 and last_emitted_line != null) last_emitted_line.? + 1 else null;
    if (first_line_exceeds_limit) {
        var line_size_buffer: [32]u8 = undefined;
        var limit_size_buffer: [32]u8 = undefined;
        try writer.writer.print(
            "[Line {d} is {s}, exceeds {s} limit. Use bash: sed -n '{d}p' {s} | head -c {d}]",
            .{
                start_line,
                formatSize(&line_size_buffer, first_line_bytes),
                formatSize(&limit_size_buffer, config.max_output_bytes),
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
        .offset_beyond_eof = offset_beyond_eof,
        .requested_offset = start_line,
        .first_line_exceeds_limit = first_line_exceeds_limit,
        .first_line_bytes = first_line_bytes,
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
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "one\ntwo\nthree\nfour");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"file.txt\",\"offset\":2,\"limit\":2}");
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

test "read tool expands configured home directory" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("home/project");
    try fixture.write("home/project/file.txt", "home ok");

    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_len = try fixture.tmp.dir.realPathFile(std.testing.io, "home", &home_buffer);
    var read_tool = try ReadTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .home_dir = home_buffer[0..home_len],
        .allow_paths_outside_cwd = true,
    });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"~/project/file.txt\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("home ok", result.result.content[0].text.text);
}

test "read tool reports invalid arguments operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"file.txt\",\"offset\":0}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Invalid read arguments: provide path/file_path and positive offset/limit integers.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);
}

test "read tool reports oversized file operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "hello");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_read_bytes = 3 });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"file.txt\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Read failed: file exceeds the 3 byte read limit.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);
    try std.testing.expectEqualStrings("file_too_large", result.result.details.?.object.get("reason").?.string);
}

test "read tool accepts file_path compatibility argument" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "ok");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"file_path\":\"file.txt\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("ok", result.result.content[0].text.text);
}

test "read tool omits invalid utf8 text operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/binary.dat", "ok\xffbad");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"binary.dat\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[File omitted: content is not valid UTF-8 text.]",
        result.result.content[0].text.text,
    );
}

test "read tool returns image attachment for supported image file" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    const png_header = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0d" ++ "IHDR";
    try fixture.write("repo/image.png", png_header);

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"image.png\"}");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.result.content.len);
    try std.testing.expectEqualStrings("Read image file [image/png]", result.result.content[0].text.text);
    try std.testing.expectEqualStrings("image/png", result.result.content[1].image.mime_type);
    try std.testing.expectEqualStrings("iVBORw0KGgoAAAANSUhEUg==", result.result.content[1].image.data);
}

test "read tool does not classify animated png as supported image" {
    const animated_png = "\x89PNG\r\n\x1a\n" ++
        "\x00\x00\x00\x0d" ++ "IHDR" ++ "1234567890123" ++ "\x00\x00\x00\x00" ++
        "\x00\x00\x00\x08" ++ "acTL" ++ "12345678" ++ "\x00\x00\x00\x00";
    try std.testing.expectEqual(@as(?[]const u8, null), detectImageMimeType("animated.png", animated_png));
    try std.testing.expectEqual(@as(?[]const u8, null), detectImageMimeType("fake.png", "not an image"));
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
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "one\ntwo");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"file.txt\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("one\ntwo", result.result.content[0].text.text);
    try std.testing.expect(result.result.details == null);
}

test "read tool can reject paths outside cwd by config" {
    var fixture = try test_support.Fixture.init("repo/app");
    defer fixture.deinit();
    try fixture.dir("repo/other");
    try fixture.write("repo/other/file.txt", "x");

    try std.testing.expectError(error.PathOutsideCwd, paths_mod.ToolPaths.resolveExisting(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = fixture.cwd(), .allow_paths_outside_cwd = false },
        "../other/file.txt",
    ));
}

test "read tool allows first line exactly at byte limit" {
    const formatted = try formatReadOutput(
        std.testing.allocator,
        .{ .cwd = "/repo", .max_output_bytes = 3 },
        .{ .path = "file.txt", .offset = null, .limit = null },
        "abc\nsecond",
    );
    defer formatted.deinit(std.testing.allocator);

    try std.testing.expect(!formatted.first_line_exceeds_limit);
    try std.testing.expectEqualStrings(
        "abc\n\n[Showing lines 1-1 of 2 (3B limit). Use offset=2 to continue.]",
        formatted.text,
    );
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
        "[Line 1 is 6B, exceeds 3B limit. Use bash: sed -n '1p' file.txt | head -c 3]",
        formatted.text,
    );
    const details = (try formatted.details(std.testing.allocator)).?;
    defer runtime.freeJsonValue(std.testing.allocator, details);
    const truncation = details.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 6), truncation.get("firstLineBytes").?.integer);
}

test "read tool reports offset beyond end operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "one");

    var read_tool = try ReadTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer read_tool.deinit();

    var result = try test_support.execute(read_tool.tool(), "{\"path\":\"file.txt\",\"offset\":3}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[Offset 3 is beyond end of file (1 lines total).]",
        result.result.content[0].text.text,
    );
    const details = result.result.details.?.object;
    try std.testing.expect(details.get("isError").?.bool);
    try std.testing.expectEqualStrings("offset_beyond_eof", details.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 3), details.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 1), details.get("totalLines").?.integer);
}
