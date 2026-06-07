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
    \\    "path": { "type": "string", "description": "The file path to read" },
    \\    "offset": { "type": "integer", "description": "Optional 1-indexed start line" },
    \\    "limit": { "type": "integer", "description": "Optional maximum number of lines" }
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
            .description = "Read a text file with bounded output. Supports optional 1-indexed offset and line limit.",
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
        try writer.writer.print(
            "[Line {d} exceeds {d} byte read limit. read returns complete lines only.]",
            .{ start_line, config.max_output_bytes },
        );
    } else if (next_offset) |offset| {
        try writer.writer.print(
            "\n\n[{d} more lines in file. Use offset={d} to continue.]",
            .{ remaining_lines, offset },
        );
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
        "[Line 1 exceeds 3 byte read limit. read returns complete lines only.]",
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
