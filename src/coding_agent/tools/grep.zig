const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");

pub const max_files = 500;
pub const max_file_bytes = 256 * 1024;
pub const max_matches = 200;
pub const max_output_bytes = 48 * 1024;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "File or directory path to search" },
    \\    "pattern": { "type": "string", "description": "Literal text to search for" }
    \\  },
    \\  "required": ["path", "pattern"]
    \\}
;

pub const GrepTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_files: usize = max_files,
        max_file_bytes: usize = max_file_bytes,
        max_matches: usize = max_matches,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !GrepTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
                .max_files = config.max_files,
                .max_file_bytes = config.max_file_bytes,
                .max_matches = config.max_matches,
                .max_output_bytes = config.max_output_bytes,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *GrepTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *GrepTool) agent.AgentTool {
        return .{
            .name = "grep",
            .description = "Search files for a literal text pattern with bounded output.",
            .parameters = self.parsed_parameters.value,
            .label = "grep",
            .execute = .{ .context = self, .call_fn = execute },
        };
    }
};

const Args = struct {
    path: []const u8,
    pattern: []const u8,
};

const SearchState = struct {
    files_seen: usize = 0,
    matches: usize = 0,
    truncated: bool = false,
    writer: std.Io.Writer.Allocating,
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *GrepTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(params);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    var state: SearchState = .{ .writer = .init(allocator) };
    errdefer state.writer.deinit();
    try searchPath(allocator, io, self.config, args, resolved_path, token, &state);
    if (state.truncated and state.writer.written().len + 26 <= self.config.max_output_bytes) {
        try state.writer.writer.writeAll("\n[grep truncated]");
    }

    const text = try state.writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{ .content = result_content } };
}

fn searchPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: GrepTool.Config,
    args: Args,
    resolved_path: []const u8,
    token: runtime.CancelToken,
    state: *SearchState,
) !void {
    const stat = try std.Io.Dir.statFile(.cwd(), io, resolved_path, .{});
    switch (stat.kind) {
        .file => try searchFile(allocator, io, config, args, resolved_path, args.path, token, state),
        .directory => {
            var dir = try std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                try token.throwIfRequested();
                if (entry.kind != .file) continue;
                if (state.files_seen == config.max_files) {
                    state.truncated = true;
                    return;
                }
                const full_path = try std.fs.path.join(allocator, &.{ resolved_path, entry.path });
                defer allocator.free(full_path);
                try searchFile(allocator, io, config, args, full_path, entry.path, token, state);
                if (state.truncated) return;
            }
        },
        else => return error.InvalidToolArguments,
    }
}

fn searchFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: GrepTool.Config,
    args: Args,
    resolved_path: []const u8,
    display_path: []const u8,
    token: runtime.CancelToken,
    state: *SearchState,
) !void {
    state.files_seen += 1;
    const content = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(config.max_file_bytes),
    ) catch |err| switch (err) {
        error.FileTooBig => {
            state.truncated = true;
            return;
        },
        else => |unexpected| return unexpected,
    };
    defer allocator.free(content);
    try token.throwIfRequested();

    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (std.mem.indexOf(u8, line, args.pattern) == null) continue;
        if (state.matches == config.max_matches or
            state.writer.written().len + display_path.len + line.len + 32 > config.max_output_bytes)
        {
            state.truncated = true;
            return;
        }
        if (state.matches > 0) try state.writer.writer.writeByte('\n');
        try state.writer.writer.print("{s}:{d}: {s}", .{ display_path, line_number, line });
        state.matches += 1;
    }
}

fn parseArgs(params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const path = params.object.get("path") orelse return error.InvalidToolArguments;
    const pattern = params.object.get("pattern") orelse return error.InvalidToolArguments;
    if (path != .string or path.string.len == 0) return error.InvalidToolArguments;
    if (pattern != .string or pattern.string.len == 0) return error.InvalidToolArguments;
    return .{ .path = path.string, .pattern = pattern.string };
}

test "grep tool searches directory files with literal pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/a.txt", .data = "hello\nworld" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/b.txt", .data = "nope" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "src" });
    try object.put(std.testing.allocator, "pattern", .{ .string = "hello" });

    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(std.testing.allocator, std.testing.io, &tool, cancel_source.token(), "call", .{
        .object = object,
    }, null);
    defer result.deinit();

    try std.testing.expectEqualStrings("a.txt:1: hello", result.result.content[0].text.text);
}
