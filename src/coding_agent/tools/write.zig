const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const mutation = @import("file_mutation_queue.zig");
const path_utils = @import("path_utils.zig");

pub const max_write_bytes = 4 * 1024 * 1024;
pub const write_update_chunk_bytes = 16 * 1024;

var temp_file_counter: std.atomic.Value(u64) = .init(0);

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to write" },
    \\    "content": { "type": "string", "description": "Content to write to the file" }
    \\  },
    \\  "required": ["path", "content"]
    \\}
;

pub const WriteTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),
    owned_queue: mutation.FileMutationQueue = .{},

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_write_bytes: usize = max_write_bytes,
        mutation_queue: ?*mutation.FileMutationQueue = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !WriteTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
                .max_write_bytes = config.max_write_bytes,
                .mutation_queue = config.mutation_queue,
            },
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
            .description = "Create or overwrite a text file. Creates parent directories as needed.",
            .parameters = self.parsed_parameters.value,
            .label = "write",
            .execute = .{ .context = self, .call_fn = execute },
            .execution_mode = .sequential,
        };
    }

    fn queue(self: *WriteTool) *mutation.FileMutationQueue {
        return self.config.mutation_queue orelse &self.owned_queue;
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
    if (args.content.len > self.config.max_write_bytes) return error.WriteTooLarge;
    const resolved_path = try path_utils.resolveCreatablePath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    var guard = self.queue().lock();
    defer guard.unlock();

    try token.throwIfRequested();
    if (std.fs.path.dirname(resolved_path)) |dir| try std.Io.Dir.createDirPath(.cwd(), io, dir);
    try atomicWriteFileStreamingUpdates(allocator, io, resolved_path, args.content, on_update);
    try token.throwIfRequested();

    return writeResult(allocator, args.content.len, args.path);
}

fn parseArgs(params: std.json.Value) !WriteArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    const content_value = params.object.get("content") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;
    if (content_value != .string) return error.InvalidToolArguments;
    return .{ .path = path_value.string, .content = content_value.string };
}

fn atomicWriteFileStreamingUpdates(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    on_update: ?agent.AgentToolUpdateCallback,
) !void {
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const counter = temp_file_counter.fetchAdd(1, .monotonic);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.zi-tmp-{d}-{d}", .{ path, stamp, counter });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, temp_path) catch {};

    const file = try std.Io.Dir.createFile(.cwd(), io, temp_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var offset: usize = 0;
    while (offset < content.len) {
        const end = utf8ChunkEnd(content, offset, @min(content.len, offset + write_update_chunk_bytes));
        const chunk = content[offset..end];
        try writer.interface.writeAll(chunk);
        try emitWriteUpdate(allocator, on_update, chunk);
        offset = end;
    }
    try writer.flush();
    try std.Io.Dir.rename(.cwd(), temp_path, .cwd(), path, io);
}

fn emitWriteUpdate(
    allocator: std.mem.Allocator,
    on_update: ?agent.AgentToolUpdateCallback,
    chunk: []const u8,
) !void {
    const callback = on_update orelse return;
    const text = try allocator.dupe(u8, chunk);
    defer allocator.free(text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try callback.call(.{ .content = content });
}

fn utf8ChunkEnd(content: []const u8, start: usize, proposed_end: usize) usize {
    std.debug.assert(start < proposed_end);
    std.debug.assert(proposed_end <= content.len);
    if (proposed_end == content.len) return proposed_end;
    var end = proposed_end;
    while (end > start and (content[end] & 0xc0) == 0x80) : (end -= 1) {}
    if (end == start) return proposed_end;
    return end;
}

fn writeResult(allocator: std.mem.Allocator, bytes_written: usize, path: []const u8) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ bytes_written, path });
    errdefer allocator.free(message);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = message } };
    var details: std.json.ObjectMap = .empty;
    errdefer details.deinit(allocator);
    try path_utils.putJsonField(allocator, &details, "bytesWritten", .{ .integer = @intCast(bytes_written) });
    return .{ .allocator = allocator, .result = .{ .content = content, .details = .{ .object = details } } };
}

test "write tool creates parent directories and writes content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer write_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "dir/file.txt" });
    try object.put(std.testing.allocator, "content", .{ .string = "hello" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &write_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    const written = try tmp.dir.readFileAlloc(std.testing.io, "repo/dir/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("hello", written);
    try std.testing.expectEqualStrings(
        "Successfully wrote 5 bytes to dir/file.txt",
        result.result.content[0].text.text,
    );
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer write_tool.deinit();

    const content = "中" ** 6000;
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "streamed.txt" });
    try object.put(std.testing.allocator, "content", .{ .string = content });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var capture: WriteUpdateCapture = .{ .writer = .init(std.testing.allocator) };
    defer capture.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &write_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        .{ .context = &capture, .call_fn = captureWriteUpdate },
    );
    defer result.deinit();

    try std.testing.expect(capture.count > 1);
    try std.testing.expectEqualStrings(content, capture.writer.written());
    const written = try tmp.dir.readFileAlloc(std.testing.io, "repo/streamed.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(content, written);
}

test "write tool rejects oversized content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var write_tool = try WriteTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd], .max_write_bytes = 3 });
    defer write_tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "content", .{ .string = "hello" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    try std.testing.expectError(error.WriteTooLarge, execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &write_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    ));
}

test "write tool rejects paths outside cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/app");
    try tmp.dir.createDirPath(std.testing.io, "repo/other");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo/app", &cwd_buffer);
    try std.testing.expectError(error.PathOutsideCwd, path_utils.resolveCreatablePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd_buffer[0..cwd] },
        "../other/file.txt",
    ));
}
