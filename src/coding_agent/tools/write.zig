const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const mutation = @import("file_mutation_queue.zig");

pub const max_write_bytes = 4 * 1024 * 1024;

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
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.OwnedAgentToolResult {
    try token.throwIfRequested();
    const self: *WriteTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(params);
    if (args.content.len > self.config.max_write_bytes) return error.WriteTooLarge;
    const resolved_path = try resolvePath(allocator, io, self.config, args.path, true);
    defer allocator.free(resolved_path);

    var guard = self.queue().lock();
    defer guard.unlock();

    try token.throwIfRequested();
    if (std.fs.path.dirname(resolved_path)) |dir| try std.Io.Dir.createDirPath(.cwd(), io, dir);
    try atomicWriteFile(allocator, io, resolved_path, args.content);
    try token.throwIfRequested();

    return textResult(allocator, "Successfully wrote {d} bytes to {s}", .{ args.content.len, args.path });
}

fn parseArgs(params: std.json.Value) !WriteArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    const content_value = params.object.get("content") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;
    if (content_value != .string) return error.InvalidToolArguments;
    return .{ .path = path_value.string, .content = content_value.string };
}

fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: WriteTool.Config,
    path: []const u8,
    allow_missing_leaf: bool,
) ![]const u8 {
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, path });
    errdefer allocator.free(resolved);

    if (!config.allow_paths_outside_cwd) {
        const canonical_cwd = try std.Io.Dir.realPathFileAlloc(.cwd(), io, config.cwd, allocator);
        defer allocator.free(canonical_cwd);
        const canonical_path = if (allow_missing_leaf)
            try canonicalExistingParent(allocator, io, resolved)
        else
            try std.Io.Dir.realPathFileAlloc(.cwd(), io, resolved, allocator);
        defer allocator.free(canonical_path);
        if (!isPathInside(canonical_cwd, canonical_path)) return error.PathOutsideCwd;
    }
    return resolved;
}

fn canonicalExistingParent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var candidate = path;
    while (true) {
        return std.Io.Dir.realPathFileAlloc(.cwd(), io, candidate, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                candidate = std.fs.path.dirname(candidate) orelse return err;
                continue;
            },
            else => return err,
        };
    }
}

fn atomicWriteFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const counter = temp_file_counter.fetchAdd(1, .monotonic);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.zi-tmp-{d}-{d}", .{ path, stamp, counter });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, temp_path) catch {};
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = temp_path, .data = content });
    try std.Io.Dir.rename(.cwd(), temp_path, .cwd(), path, io);
}

fn isPathInside(raw_cwd: []const u8, path: []const u8) bool {
    var cwd = raw_cwd;
    while (cwd.len > 1 and std.fs.path.isSep(cwd[cwd.len - 1])) cwd = cwd[0 .. cwd.len - 1];
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (cwd.len == 1 and std.fs.path.isSep(cwd[0])) return true;
    if (path.len == cwd.len) return true;
    return std.fs.path.isSep(path[cwd.len]);
}

fn textResult(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !agent.OwnedAgentToolResult {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(message);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = message } };
    return .{ .allocator = allocator, .result = .{ .content = content } };
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

    var cancel_source: runtime.CancelSource = .{};
    var result = try execute(
        std.testing.allocator,
        std.testing.io,
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

    var cancel_source: runtime.CancelSource = .{};
    try std.testing.expectError(error.WriteTooLarge, execute(
        std.testing.allocator,
        std.testing.io,
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
    try std.testing.expectError(error.PathOutsideCwd, resolvePath(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd_buffer[0..cwd] },
        "../other/file.txt",
        true,
    ));
}
