const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent_api = @import("../../agent/root.zig");
const ai_message = ai.message;
const ai_model = ai.model;
const tool_api = agent_api.tool;

const WriteTool = @This();

const max_arguments_bytes = 1024 * 1024;
const max_path_bytes = 4096;
const invalid_arguments_message = "Write arguments require a non-empty path and a content string.";

cwd: std.Io.Dir,

pub const definition: ai_message.ToolDefinition = .{
    .name = "write",
    .description = "Write content to a file. Creates the file if it doesn't exist, overwrites it if it does, " ++
        "and creates parent directories automatically.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to write (relative or absolute)\"}," ++
        "\"content\":{\"type\":\"string\",\"description\":\"Complete content to write to the file\"}}," ++
        "\"required\":[\"path\",\"content\"],\"additionalProperties\":false}",
};

const Arguments = struct {
    path: []const u8,
    content: []const u8,
};

pub fn asTool(self: *WriteTool) tool_api.Tool {
    return tool_api.Tool.from(self, definition);
}

pub fn execute(
    self: *WriteTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    run_context: tool_api.Tool.RunContext,
    arguments_json: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    try checkCancellation(run_context);
    if (arguments_json.len > max_arguments_bytes) {
        return modelFailure(allocator, "Write arguments exceed the 1.0MB input limit.", .{});
    }

    var parsed = std.json.parseFromSlice(Arguments, allocator, arguments_json, .{}) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => modelFailure(allocator, invalid_arguments_message, .{}),
        };
    };
    defer parsed.deinit();
    const arguments = parsed.value;
    if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
        !std.unicode.utf8ValidateSlice(arguments.path) or
        !std.unicode.utf8ValidateSlice(arguments.content))
    {
        return modelFailure(allocator, invalid_arguments_message, .{});
    }
    if (std.fs.path.dirname(arguments.path)) |parent| {
        self.cwd.createDirPath(io, parent) catch |failure| switch (failure) {
            error.Canceled => return error.Cancelled,
            else => return modelFailure(
                allocator,
                "Cannot create parent directory for {s}: {s}.",
                .{ arguments.path, @errorName(failure) },
            ),
        };
    }
    try checkCancellation(run_context);

    const output = std.fmt.allocPrint(
        allocator,
        "Successfully wrote {d} bytes to {s}",
        .{ arguments.content.len, arguments.path },
    ) catch return error.OutOfMemory;
    const content = allocator.alloc(ai_message.Content, 1) catch {
        allocator.free(output);
        return error.OutOfMemory;
    };
    content[0] = .{ .text = output };
    checkCancellation(run_context) catch |failure| {
        allocator.free(content);
        allocator.free(output);
        return failure;
    };
    self.cwd.writeFile(io, .{
        .sub_path = arguments.path,
        .data = arguments.content,
    }) catch |failure| {
        allocator.free(content);
        allocator.free(output);
        return switch (failure) {
            error.Canceled => error.Cancelled,
            else => modelFailure(
                allocator,
                "Cannot write {s}: {s}.",
                .{ arguments.path, @errorName(failure) },
            ),
        };
    };
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

test "write creates parent directories and reports UTF-8 bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"nested/src/main.zig\",\"content\":\"const greeting = \\\"你好\\\";\\n\"}",
    );
    try std.testing.expectEqualStrings(
        "Successfully wrote 27 bytes to nested/src/main.zig",
        execution.success.content[0].text,
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "nested/src/main.zig",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("const greeting = \"你好\";\n", bytes);
}

test "write overwrites a file and accepts empty content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "old" });
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"content\":\"replacement\"}",
    );
    {
        const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("replacement", bytes);
    }

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"content\":\"\"}",
    );
    try std.testing.expectEqualStrings("Successfully wrote 0 bytes to target", execution.success.content[0].text);
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "write allows parent traversal from the borrowed session directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "workspace", .default_dir);
    var workspace = try temporary.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    var implementation: WriteTool = .{ .cwd = workspace };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"../outside\",\"content\":\"trusted\"}",
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "outside",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("trusted", bytes);
}

test "write accepts an absolute path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(absolute_path);
    const target = try std.fs.path.join(std.testing.allocator, &.{ absolute_path, "absolute.txt" });
    defer std.testing.allocator.free(target);
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = target,
        .content = "absolute",
    }, .{});
    defer std.testing.allocator.free(arguments);
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        target,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("absolute", bytes);
}

test "write rejects malformed arguments and enforces path bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    const cases = [_][]const u8{
        "{}",
        "{\"path\":\"file\"}",
        "{\"content\":\"text\"}",
        "{\"path\":\"\",\"content\":\"text\"}",
        "{\"path\":1,\"content\":\"text\"}",
        "{\"path\":\"file\",\"content\":1}",
        "{\"path\":\"file\",\"content\":\"text\",\"extra\":true}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_arguments_message, execution.failure);
    }

    const path = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(path);
    @memset(path, 'x');
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = path,
        .content = "text",
    }, .{});
    defer std.testing.allocator.free(arguments);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings(invalid_arguments_message, execution.failure);
}

test "write rejects non-UTF-8 JSON strings before filesystem output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    const cases = [_][]const u8{
        "{\"path\":\"\xff\",\"content\":\"text\"}",
        "{\"path\":\"invalid\",\"content\":\"\xff\"}",
        "{\"path\":\"\\uD800\",\"content\":\"text\"}",
        "{\"path\":\"invalid\",\"content\":\"\\uD800\"}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_arguments_message, execution.failure);
    }
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "invalid", .{}));
}

test "write admits exactly 1 MiB of arguments and rejects one byte more" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    const prefix = "{\"path\":\"limit\",\"content\":\"";
    const suffix = "\"}";
    const exact = try std.testing.allocator.alloc(u8, max_arguments_bytes);
    defer std.testing.allocator.free(exact);
    @memcpy(exact[0..prefix.len], prefix);
    @memset(exact[prefix.len .. exact.len - suffix.len], 'x');
    @memcpy(exact[exact.len - suffix.len ..], suffix);
    var exact_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arena.deinit();

    _ = try implementation.execute(exact_arena.allocator(), std.testing.io, .{}, exact);
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "limit",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(max_arguments_bytes - prefix.len - suffix.len, bytes.len);

    const oversized = try std.testing.allocator.alloc(u8, max_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    var oversized_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer oversized_arena.deinit();
    const execution = try implementation.execute(oversized_arena.allocator(), std.testing.io, .{}, oversized);
    try std.testing.expectEqualStrings("Write arguments exceed the 1.0MB input limit.", execution.failure);
}

test "write returns filesystem failures without partial success" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"directory\",\"content\":\"text\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, execution.failure, "Cannot write directory:"));
}

test "write honors pre-cancellation without filesystem mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: WriteTool = .{ .cwd = temporary.dir };
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"untouched\",\"content\":\"text\"}",
    ));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "untouched", .{}));
}
