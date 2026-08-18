const std = @import("std");
const ai_message = @import("../../ai/message.zig");
const ai_model = @import("../../ai/model.zig");
const tool_api = @import("../../agent/Tool.zig");

const ReadTool = @This();

const max_path_bytes = 4096;
const max_file_bytes = 8 * 1024 * 1024;
const max_output_bytes = 50 * 1024;
const max_output_lines = 2000;
const invalid_arguments_message =
    "Read arguments require a path and optional positive integer offset and limit.";

cwd: std.Io.Dir,

pub const definition: ai_message.ToolDefinition = .{
    .name = "read",
    .description = "Read a UTF-8 text file. Paths may be relative to the session working directory or absolute. " ++
        "Output is limited to 2000 lines or 50KB, whichever is reached first. " ++
        "Use offset and limit to continue through large files.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"}," ++
        "\"offset\":{\"type\":\"integer\",\"minimum\":1," ++
        "\"description\":\"Line number to start reading from (1-indexed)\"}," ++
        "\"limit\":{\"type\":\"integer\",\"minimum\":1," ++
        "\"description\":\"Maximum number of lines to read\"}}," ++
        "\"required\":[\"path\"],\"additionalProperties\":false}",
};

const Arguments = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
};

pub fn asTool(self: *ReadTool) tool_api.Tool {
    return tool_api.Tool.from(self, definition);
}

pub fn execute(
    self: *ReadTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    run_context: tool_api.Tool.RunContext,
    arguments_json: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    try checkCancellation(run_context);

    var parsed = std.json.parseFromSlice(Arguments, allocator, arguments_json, .{}) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => modelFailure(allocator, invalid_arguments_message, .{}),
        };
    };
    defer parsed.deinit();
    const arguments = parsed.value;
    if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
        arguments.offset == 0 or arguments.limit == 0)
    {
        return modelFailure(
            allocator,
            invalid_arguments_message,
            .{},
        );
    }

    const bytes = self.cwd.readFileAlloc(
        io,
        arguments.path,
        allocator,
        .limited(max_file_bytes + 1),
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return modelFailure(
            allocator,
            "Cannot read {s}: file exceeds the 8.0MB input limit.",
            .{arguments.path},
        ),
        else => return modelFailure(
            allocator,
            "Cannot read {s}: {s}.",
            .{ arguments.path, @errorName(failure) },
        ),
    };
    if (bytes.len > max_file_bytes) {
        return modelFailure(
            allocator,
            "Cannot read {s}: file exceeds the 8.0MB input limit.",
            .{arguments.path},
        );
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return modelFailure(allocator, "Cannot read {s}: file is not valid UTF-8.", .{arguments.path});
    }

    const offset = arguments.offset orelse 1;
    const total_lines = lineCount(bytes);
    if (offset > total_lines) {
        return modelFailure(
            allocator,
            "Offset {d} is beyond end of file ({d} lines total)",
            .{ offset, total_lines },
        );
    }
    const output = try selectText(allocator, bytes, offset, arguments.limit);
    try checkCancellation(run_context);
    const content = try allocator.alloc(ai_message.Content, 1);
    content[0] = .{ .text = output };
    return .{ .success = .{ .content = content } };
}

fn checkCancellation(run_context: tool_api.Tool.RunContext) tool_api.ToolFatalError!void {
    if (run_context.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
}

fn modelFailure(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    arguments: anytype,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    const text = std.fmt.allocPrint(allocator, format, arguments) catch return error.OutOfMemory;
    return .{ .failure = text };
}

const Continuation = enum {
    none,
    line_limit,
    byte_limit,
    user_limit,
};

fn selectText(
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
    requested_limit: ?usize,
) tool_api.ToolFatalError![]const u8 {
    const total_lines = lineCount(source);
    const available_lines = total_lines - offset + 1;
    const selected_lines = if (requested_limit) |limit| @min(limit, available_lines) else available_lines;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var line_ends: [max_output_lines]usize = undefined;

    var cursor: usize = 0;
    var line_number: usize = 1;
    var written_lines: usize = 0;
    var continuation: Continuation = .none;

    while (line_number <= total_lines) : (line_number += 1) {
        const newline = std.mem.findScalarPos(u8, source, cursor, '\n');
        const end = newline orelse source.len;
        const line = source[cursor..end];
        cursor = if (newline) |index| index + 1 else source.len;

        if (line_number < offset) continue;
        if (written_lines >= selected_lines) break;
        if (written_lines >= max_output_lines) {
            continuation = .line_limit;
            break;
        }

        const separator_bytes: usize = if (written_lines == 0) 0 else 1;
        if (separator_bytes + line.len > max_output_bytes -| output.items.len) {
            continuation = .byte_limit;
            break;
        }
        if (separator_bytes == 1) output.append(allocator, '\n') catch return error.OutOfMemory;
        output.appendSlice(allocator, line) catch return error.OutOfMemory;
        line_ends[written_lines] = output.items.len;
        written_lines += 1;
    }

    if (written_lines == 0 and continuation == .byte_limit) {
        return oversizedLineDiagnostic(allocator, source, offset);
    }
    if (continuation == .none and written_lines < selected_lines) continuation = .line_limit;
    if (continuation == .none and requested_limit != null and written_lines < available_lines) {
        continuation = .user_limit;
    }

    if (continuation == .none) {
        if (offset + written_lines - 1 == total_lines and std.mem.endsWith(u8, source, "\n") and
            output.items.len < max_output_bytes)
        {
            output.append(allocator, '\n') catch return error.OutOfMemory;
        }
    } else {
        while (true) {
            const notice = try continuationNotice(
                allocator,
                continuation,
                offset,
                written_lines,
                total_lines,
                available_lines,
            );
            defer allocator.free(notice);
            if (output.items.len + 2 + notice.len <= max_output_bytes) {
                output.appendSlice(allocator, "\n\n") catch return error.OutOfMemory;
                output.appendSlice(allocator, notice) catch return error.OutOfMemory;
                break;
            }
            if (written_lines == 1) {
                const compact_notice = std.fmt.allocPrint(
                    allocator,
                    "[Use offset={d} to continue.]",
                    .{offset + written_lines},
                ) catch return error.OutOfMemory;
                defer allocator.free(compact_notice);
                if (output.items.len + 2 + compact_notice.len <= max_output_bytes) {
                    output.appendSlice(allocator, "\n\n") catch return error.OutOfMemory;
                    output.appendSlice(allocator, compact_notice) catch return error.OutOfMemory;
                    break;
                }
                return oversizedLineDiagnostic(allocator, source, offset);
            }
            written_lines -= 1;
            output.items.len = line_ends[written_lines - 1];
            continuation = .byte_limit;
        }
    }

    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn continuationNotice(
    allocator: std.mem.Allocator,
    continuation: Continuation,
    offset: usize,
    written_lines: usize,
    total_lines: usize,
    available_lines: usize,
) tool_api.ToolFatalError![]u8 {
    return switch (continuation) {
        .none => unreachable,
        .line_limit => std.fmt.allocPrint(
            allocator,
            "[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
            .{ offset, offset + written_lines - 1, total_lines, offset + written_lines },
        ),
        .byte_limit => std.fmt.allocPrint(
            allocator,
            "[Showing lines {d}-{d} of {d} (50.0KB limit). Use offset={d} to continue.]",
            .{ offset, offset + written_lines - 1, total_lines, offset + written_lines },
        ),
        .user_limit => std.fmt.allocPrint(
            allocator,
            "[{d} more lines in file. Use offset={d} to continue.]",
            .{ available_lines - written_lines, offset + written_lines },
        ),
    } catch return error.OutOfMemory;
}

fn oversizedLineDiagnostic(
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
) tool_api.ToolFatalError![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "[Line {d} is {d} bytes and cannot be returned with a bounded 50.0KB continuation notice.]",
        .{ offset, lineLength(source, offset) },
    ) catch return error.OutOfMemory;
}

fn lineCount(source: []const u8) usize {
    if (source.len == 0) return 1;
    const newlines = std.mem.count(u8, source, "\n");
    return newlines + @intFromBool(!std.mem.endsWith(u8, source, "\n"));
}

fn lineLength(source: []const u8, target: usize) usize {
    var cursor: usize = 0;
    var line_number: usize = 1;
    while (line_number < target) : (line_number += 1) {
        const newline = std.mem.findScalarPos(u8, source, cursor, '\n') orelse return 0;
        cursor = newline + 1;
    }
    const end = std.mem.findScalarPos(u8, source, cursor, '\n') orelse source.len;
    return end - cursor;
}

test "read returns exact text and preserves a terminal newline" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "one\ntwo\n" });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"plain.txt\"}",
    );
    try std.testing.expectEqualStrings("one\ntwo\n", execution.success.content[0].text);
}

test "read applies offset and limit with a continuation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "lines.txt", .data = "one\ntwo\nthree\nfour" });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"lines.txt\",\"offset\":2,\"limit\":2}",
    );
    try std.testing.expectEqualStrings(
        "two\nthree\n\n[1 more lines in file. Use offset=4 to continue.]",
        execution.success.content[0].text,
    );
}

test "read reports offsets beyond the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "short.txt", .data = "one\ntwo\nthree" });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"short.txt\",\"offset\":100}",
    );
    try std.testing.expectEqualStrings(
        "Offset 100 is beyond end of file (3 lines total)",
        execution.failure,
    );
}

test "read rejects invalid semantic arguments as model-visible failures" {
    var implementation: ReadTool = .{ .cwd = .cwd() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "{}",
        "{\"path\":\"\"}",
        "{\"path\":\"x\",\"offset\":0}",
        "{\"path\":\"x\",\"limit\":0}",
        "{\"path\":\"x\",\"extra\":true}",
    }) |arguments| {
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expect(execution == .failure);
    }
}

test "read enforces complete-line output bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "large.txt", .{});
    defer file.close(std.testing.io);
    var bytes: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &bytes);
    for (0..2001) |index| try writer.interface.print("line-{d}\n", .{index + 1});
    try writer.flush();

    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"large.txt\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(std.mem.find(u8, text, "line-2000") != null);
    try std.testing.expect(std.mem.find(u8, text, "line-2001") == null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        text,
        "[Showing lines 1-2000 of 2001. Use offset=2001 to continue.]",
    ));
}

test "read rejects invalid UTF-8 and observes pre-cancellation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = &.{0xff} });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const invalid = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"binary\"}",
    );
    try std.testing.expectEqualStrings("Cannot read binary: file is not valid UTF-8.", invalid.failure);

    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    try std.testing.expectError(error.Cancelled, implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"binary\"}",
    ));
}

test "read handles empty files and preserves CRLF" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "crlf", .data = "one\r\ntwo" });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"empty\"}",
    );
    try std.testing.expectEqualStrings("", empty.success.content[0].text);
    const crlf = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"crlf\"}",
    );
    try std.testing.expectEqualStrings("one\r\ntwo", crlf.success.content[0].text);
}

test "read accepts an absolute path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "absolute.txt", .data = "absolute" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const absolute_path = try std.fs.path.join(
        arena.allocator(),
        &.{ path_buffer[0..directory_length], "absolute.txt" },
    );
    const arguments = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        .{ .path = absolute_path },
        .{},
    );
    var implementation: ReadTool = .{ .cwd = .cwd() };

    const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings("absolute", execution.success.content[0].text);
}

test "read classifies filesystem failures and enforces the input boundary" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    var exact = try temporary.dir.createFile(std.testing.io, "exact", .{});
    try exact.setLength(std.testing.io, max_file_bytes);
    exact.close(std.testing.io);
    var oversized = try temporary.dir.createFile(std.testing.io, "oversized", .{});
    try oversized.setLength(std.testing.io, max_file_bytes + 1);
    oversized.close(std.testing.io);
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const missing = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"missing\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, missing.failure, "Cannot read missing:"));
    const directory = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"directory\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, directory.failure, "Cannot read directory:"));
    const exact_limit = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"exact\"}",
    );
    try std.testing.expect(exact_limit == .success);
    const over_limit = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"oversized\"}",
    );
    try std.testing.expectEqualStrings(
        "Cannot read oversized: file exceeds the 8.0MB input limit.",
        over_limit.failure,
    );
}

test "read enforces the byte bound without returning partial lines" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "bytes.txt", .{});
    defer file.close(std.testing.io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &file_buffer);
    const payload = "x" ** 200;
    for (0..500) |index| try writer.interface.print("line-{d}-{s}\n", .{ index + 1, payload });
    try writer.flush();

    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"bytes.txt\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, text, "(50.0KB limit)") != null);
    const notice = std.mem.find(u8, text, "\n\n[Showing lines");
    try std.testing.expect(notice != null);
    try std.testing.expect(text[notice.? - 1] == 'x');
}

test "read uses a compact continuation when a near-limit line leaves little notice space" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const first = try std.testing.allocator.alloc(u8, 51_133);
    defer std.testing.allocator.free(first);
    @memset(first, 'x');
    const second = "y" ** 100;
    var file = try temporary.dir.createFile(std.testing.io, "near-limit", .{});
    errdefer file.close(std.testing.io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &file_buffer);
    try writer.interface.writeAll(first);
    try writer.interface.writeByte('\n');
    try writer.interface.writeAll(second);
    try writer.flush();
    file.close(std.testing.io);
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"near-limit\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(text.len <= max_output_bytes);
    try std.testing.expect(std.mem.startsWith(u8, text, first));
    try std.testing.expect(std.mem.endsWith(u8, text, "[Use offset=2 to continue.]"));
}

test "read reports an oversized first selected line without partial content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const line = try std.testing.allocator.alloc(u8, max_output_bytes + 1);
    defer std.testing.allocator.free(line);
    @memset(line, 'x');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "long-line", .data = line });
    var implementation: ReadTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"long-line\"}",
    );
    try std.testing.expectEqualStrings(
        "[Line 1 is 51201 bytes and cannot be returned with a bounded 50.0KB continuation notice.]",
        execution.success.content[0].text,
    );
}
