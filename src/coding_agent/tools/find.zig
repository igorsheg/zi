const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_entries = 500;
pub const max_output_bytes = tool_output_policy.default_max_bytes;
pub const max_visited_multiplier = 16;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Directory path to search (defaults to .)" },
    \\    "name": { "type": "string", "description": "Optional substring that path must contain" },
    \\    "limit": { "type": "integer", "description": "Maximum entries to return, capped by tool config" }
    \\  }
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
    const max_entries_value = try path_utils.parseOptionalLimit(params, self.config.max_entries);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    var dir = try std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var entries = std.ArrayList([]u8).empty;
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var visited: usize = 0;
    var truncated = false;
    var truncated_by: []const u8 = "entries";
    const max_visited = self.config.max_entries * max_visited_multiplier;
    while (try walker.next(io)) |entry| {
        try token.throwIfRequested();
        if (visited == max_visited) {
            truncated = true;
            truncated_by = "files";
            break;
        }
        visited += 1;
        if (path_utils.ignoredSearchPath(entry.path)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (args.name) |needle| {
            if (std.mem.indexOf(u8, entry.path, needle) == null) continue;
        }
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.path, kindSuffix(entry.kind) });
        errdefer allocator.free(name);
        try entries.append(allocator, name);
    }
    std.mem.sort([]u8, entries.items, {}, lessThanString);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var emitted: usize = 0;
    for (entries.items) |entry| {
        if (emitted == max_entries_value) {
            truncated = true;
            truncated_by = "entries";
            break;
        }
        if (writer.written().len + entry.len + 8 > self.config.max_output_bytes) {
            truncated = true;
            truncated_by = "bytes";
            break;
        }
        if (emitted > 0) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(entry);
        emitted += 1;
    }
    if (emitted == 0 and !truncated and writer.written().len + no_matches_text.len <= self.config.max_output_bytes) {
        try writer.writer.writeAll(no_matches_text);
    }
    if (truncated and writer.written().len + 26 <= self.config.max_output_bytes) {
        try writer.writer.writeAll("\n[find truncated]");
    }

    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{
        .content = result_content,
        .details = try findDetails(allocator, emitted, truncated, truncated_by, max_entries_value),
    } };
}

const no_matches_text = "[no matches]";

fn findDetails(
    allocator: std.mem.Allocator,
    entries: usize,
    truncated: bool,
    truncated_by: []const u8,
    max_entries_value: usize,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try path_utils.putJsonField(allocator, &object, "entries", .{ .integer = @intCast(entries) });
    var truncation: std.json.ObjectMap = .empty;
    errdefer truncation.deinit(allocator);
    try path_utils.putJsonField(allocator, &truncation, "truncated", .{ .bool = truncated });
    try path_utils.putJsonStringField(allocator, &truncation, "truncatedBy", truncated_by);
    try path_utils.putJsonField(allocator, &truncation, "maxEntries", .{ .integer = @intCast(max_entries_value) });
    try path_utils.putJsonField(allocator, &object, "truncation", .{ .object = truncation });
    return .{ .object = object };
}

fn parseArgs(params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const path_string = if (params.object.get("path")) |path| blk: {
        if (path != .string or path.string.len == 0) return error.InvalidToolArguments;
        break :blk path.string;
    } else ".";
    const name_value = params.object.get("name");
    const name = if (name_value) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk if (value.string.len == 0) null else value.string;
    } else null;
    return .{ .path = path_string, .name = name };
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
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

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &tool,
        cancel_source.token(),
        "call",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("src/main.zig", result.result.content[0].text.text);
}

test "find tool defaults path, sorts results, applies limit, and ignores dependency directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/node_modules/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/b.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/node_modules/pkg/c.zig", .data = "" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "name", .{ .string = ".zig" });
    try object.put(std.testing.allocator, "limit", .{ .integer = 1 });

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &tool,
        cancel_source.token(),
        "call-default",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("a.zig\n[find truncated]", result.result.content[0].text.text);
}

test "find tool reports no matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/main.zig", .data = "" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "." });
    try object.put(std.testing.allocator, "name", .{ .string = "missing" });

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &tool,
        cancel_source.token(),
        "call",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("[no matches]", result.result.content[0].text.text);
}
