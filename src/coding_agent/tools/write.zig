const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const file_writer = @import("file_writer.zig");
const path_utils = @import("path_utils.zig");
const test_support = @import("test_support.zig");

pub const max_write_bytes = 4 * 1024 * 1024;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to write (relative or absolute)" },
    \\    "content": { "type": "string", "description": "Content to write to the file" }
    \\  },
    \\  "required": ["path", "content"]
    \\}
;

pub const WriteTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_write_bytes: usize = max_write_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !WriteTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        var owned_config = config;
        owned_config.cwd = cwd;
        return .{
            .allocator = allocator,
            .config = owned_config,
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *WriteTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *WriteTool) agent.AgentTool {
        return .{
            .name = "write",
            .description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. " ++
                "Automatically creates parent directories.",
            .parameters = self.parsed_parameters.value,
            .label = "write",
            .execute = .{ .context = self, .call_fn = execute },
            // Sequential execution is the file-mutation serialization guarantee.
            .execution_mode = .sequential,
        };
    }
};

const WriteArgs = struct {
    path: []const u8,
    content: []const u8,
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *agent.ToolRuntime,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *WriteTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(params);
    if (args.content.len > self.config.max_write_bytes) {
        const message = try std.fmt.allocPrint(
            allocator,
            "[Write omitted: content is {d} bytes, exceeding the {d} byte limit.]",
            .{ args.content.len, self.config.max_write_bytes },
        );
        return path_utils.ownedTextResult(allocator, message, try path_utils.jsonDetails(allocator, .{
            .contentBytes = args.content.len,
            .maxBytes = self.config.max_write_bytes,
        }));
    }
    const resolved_path = try path_utils.resolveCreatablePath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    try token.throwIfRequested();
    if (std.fs.path.dirname(resolved_path)) |dir| try std.Io.Dir.createDirPath(.cwd(), io, dir);
    try file_writer.atomicWriteFileStreamingUpdates(allocator, io, resolved_path, args.content, on_update);
    try token.throwIfRequested();

    const message = try std.fmt.allocPrint(
        allocator,
        "Successfully wrote {d} bytes to {s}",
        .{ args.content.len, args.path },
    );
    return path_utils.ownedTextResult(allocator, message, try path_utils.jsonDetails(allocator, .{
        .bytesWritten = args.content.len,
        .path = args.path,
    }));
}

fn parseArgs(params: std.json.Value) !WriteArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    const content_value = params.object.get("content") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;
    if (content_value != .string) return error.InvalidToolArguments;
    return .{ .path = path_value.string, .content = content_value.string };
}

test "write tool creates parent directories and writes content" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer write_tool.deinit();

    var result = try test_support.execute(
        write_tool.tool(),
        "{\"path\":\"dir/file.txt\",\"content\":\"hello\"}",
    );
    defer result.deinit();

    const written = try fixture.read("repo/dir/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("hello", written);
    try std.testing.expectEqualStrings(
        "Successfully wrote 5 bytes to dir/file.txt",
        result.result.content[0].text.text,
    );
    const details = result.result.details.?.object;
    try std.testing.expectEqualStrings("dir/file.txt", details.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 5), details.get("bytesWritten").?.integer);
}

const WriteUpdateCapture = struct {
    writer: std.Io.Writer.Allocating,
    count: usize = 0,

    fn deinit(self: *WriteUpdateCapture) void {
        self.writer.deinit();
        self.* = undefined;
    }
};

fn captureWriteUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const capture: *WriteUpdateCapture = @ptrCast(@alignCast(context.?));
    capture.count += 1;
    for (partial_result.content) |content| switch (content) {
        .text => |text| try capture.writer.writer.writeAll(text.text),
        .image => {},
    };
}

test "write tool streams utf8 safe content chunks" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer write_tool.deinit();

    const content = "中" ** 6000;
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"streamed.txt\",\"content\":\"{s}\"}}",
        .{content},
    );
    defer std.testing.allocator.free(args);

    var capture: WriteUpdateCapture = .{ .writer = .init(std.testing.allocator) };
    defer capture.deinit();
    var result = try test_support.executeWithUpdate(
        write_tool.tool(),
        args,
        .{ .context = &capture, .call_fn = captureWriteUpdate },
    );
    defer result.deinit();

    try std.testing.expect(capture.count > 1);
    try std.testing.expectEqualStrings(content, capture.writer.written());
    const written = try fixture.read("repo/streamed.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(content, written);
}

test "write tool rejects oversized content" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_write_bytes = 3 });
    defer write_tool.deinit();

    var result = try test_support.execute(write_tool.tool(), "{\"path\":\"file.txt\",\"content\":\"hello\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "[Write omitted: content is 5 bytes, exceeding the 3 byte limit.]",
        result.result.content[0].text.text,
    );
    const details = result.result.details.?.object;
    try std.testing.expectEqual(@as(i64, 5), details.get("contentBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 3), details.get("maxBytes").?.integer);
}

test "write tool rejects paths outside cwd" {
    var fixture = try test_support.Fixture.init("repo/app");
    defer fixture.deinit();
    try fixture.dir("repo/other");

    try std.testing.expectError(error.PathOutsideCwd, path_utils.resolveCreatablePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = fixture.cwd() },
        "../other/file.txt",
    ));
}
