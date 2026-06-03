const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_entries = 200;
pub const max_output_bytes = tool_output_policy.default_max_bytes;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Directory path to list" }
    \\  },
    \\  "required": ["path"]
    \\}
;

pub const LsTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_entries: usize = max_entries,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !LsTool {
        var path_config = try path_utils.copyConfig(allocator, .{
            .cwd = config.cwd,
            .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
        });
        errdefer path_utils.deinitConfig(allocator, &path_config);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = path_config.cwd,
                .allow_paths_outside_cwd = path_config.allow_paths_outside_cwd,
                .max_entries = config.max_entries,
                .max_output_bytes = config.max_output_bytes,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *LsTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *LsTool) agent.AgentTool {
        return .{
            .name = "ls",
            .description = "List one directory with bounded output.",
            .parameters = self.parsed_parameters.value,
            .label = "ls",
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
    const self: *LsTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const path = try parsePath(params);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, path);
    defer allocator.free(resolved_path);

    var dir = try std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    var emitted: usize = 0;
    var truncated = false;
    while (try iter.next(io)) |entry| {
        try token.throwIfRequested();
        if (emitted == self.config.max_entries) {
            truncated = true;
            break;
        }
        if (writer.written().len + entry.name.len + 8 > self.config.max_output_bytes) {
            truncated = true;
            break;
        }
        if (emitted > 0) try writer.writer.writeByte('\n');
        try writer.writer.print("{s}{s}", .{ entry.name, kindSuffix(entry.kind) });
        emitted += 1;
    }
    if (truncated and writer.written().len + 28 <= self.config.max_output_bytes) {
        try writer.writer.writeAll("\n[listing truncated]");
    }

    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{ .content = result_content } };
}

fn parsePath(params: std.json.Value) ![]const u8 {
    if (params != .object) return error.InvalidToolArguments;
    const value = params.object.get("path") orelse return error.InvalidToolArguments;
    if (value != .string or value.string.len == 0) return error.InvalidToolArguments;
    return value.string;
}

fn kindSuffix(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "/",
        .sym_link => "@",
        else => "",
    };
}

test "ls tool lists one directory with bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/dir");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/dir/a.txt", .data = "a" });
    try tmp.dir.createDirPath(std.testing.io, "repo/dir/nested");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "dir" });

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

    const text = result.result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nested/") != null);
}
