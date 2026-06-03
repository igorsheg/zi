const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_entries = 500;
pub const max_output_bytes = tool_output_policy.default_max_bytes;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Directory path to search" },
    \\    "name": { "type": "string", "description": "Optional substring that path must contain" }
    \\  },
    \\  "required": ["path"]
    \\}
;

pub const FindTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_entries: usize = max_entries,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !FindTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
                .max_entries = config.max_entries,
                .max_output_bytes = config.max_output_bytes,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *FindTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *FindTool) agent.AgentTool {
        return .{
            .name = "find",
            .description = "Recursively find paths under a directory with bounded output.",
            .parameters = self.parsed_parameters.value,
            .label = "find",
            .execute = .{ .context = self, .call_fn = execute },
        };
    }
};

const Args = struct {
    path: []const u8,
    name: ?[]const u8,
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
    const self: *FindTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(params);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    var dir = try std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var emitted: usize = 0;
    var truncated = false;
    while (try walker.next(io)) |entry| {
        try token.throwIfRequested();
        if (args.name) |needle| {
            if (std.mem.indexOf(u8, entry.path, needle) == null) continue;
        }
        if (emitted == self.config.max_entries or
            writer.written().len + entry.path.len + 8 > self.config.max_output_bytes)
        {
            truncated = true;
            break;
        }
        if (emitted > 0) try writer.writer.writeByte('\n');
        try writer.writer.print("{s}{s}", .{ entry.path, kindSuffix(entry.kind) });
        emitted += 1;
    }
    if (truncated and writer.written().len + 26 <= self.config.max_output_bytes) {
        try writer.writer.writeAll("\n[find truncated]");
    }

    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{ .content = result_content } };
}

fn parseArgs(params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const path = params.object.get("path") orelse return error.InvalidToolArguments;
    if (path != .string or path.string.len == 0) return error.InvalidToolArguments;
    const name_value = params.object.get("name");
    const name = if (name_value) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk if (value.string.len == 0) null else value.string;
    } else null;
    return .{ .path = path.string, .name = name };
}

fn kindSuffix(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "/",
        .sym_link => "@",
        else => "",
    };
}

test "find tool recursively filters paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/main.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/README.md", .data = "" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "." });
    try object.put(std.testing.allocator, "name", .{ .string = ".zig" });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &tool,
        cancel_source.token(),
        "call",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("src/main.zig", result.result.content[0].text.text);
}
