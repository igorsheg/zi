const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_entries = 200;
pub const max_scan_multiplier = 16;
pub const max_output_bytes = tool_output_policy.default_max_bytes;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Directory path to list (defaults to .)" },
    \\    "limit": { "type": "integer", "description": "Maximum entries to return, capped by tool config" }
    \\  }
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
    const max_entries_value = try path_utils.parseOptionalLimit(params, self.config.max_entries);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, path);
    defer allocator.free(resolved_path);

    var dir = try std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var entries = std.ArrayList([]u8).empty;
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var truncated = false;
    var truncated_by: []const u8 = "entries";
    const max_scan_entries = self.config.max_entries * max_scan_multiplier;
    while (try iter.next(io)) |entry| {
        try token.throwIfRequested();
        if (entries.items.len == max_scan_entries) {
            truncated = true;
            truncated_by = "entries";
            break;
        }
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.name, kindSuffix(entry.kind) });
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
        const separator: usize = if (emitted == 0) 0 else 1;
        if (writer.written().len + separator + entry.len > self.config.max_output_bytes) {
            truncated = true;
            truncated_by = "bytes";
            break;
        }
        if (emitted > 0) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(entry);
        emitted += 1;
    }
    if (emitted == 0 and !truncated and
        writer.written().len + empty_directory_text.len <= self.config.max_output_bytes)
    {
        try writer.writer.writeAll(empty_directory_text);
    }
    if (truncated and writer.written().len + 28 <= self.config.max_output_bytes) {
        try writer.writer.writeAll("\n[listing truncated]");
    }

    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{
        .content = result_content,
        .details = try listingDetails(allocator, emitted, truncated, truncated_by, max_entries_value),
    } };
}

const empty_directory_text = "[directory is empty]";

fn listingDetails(
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

fn parsePath(params: std.json.Value) ![]const u8 {
    if (params != .object) return error.InvalidToolArguments;
    const value = params.object.get("path") orelse return ".";
    if (value != .string or value.string.len == 0) return error.InvalidToolArguments;
    return value.string;
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    const limit = @min(lhs.len, rhs.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const left = std.ascii.toLower(lhs[index]);
        const right = std.ascii.toLower(rhs[index]);
        if (left != right) return left < right;
        if (lhs[index] != rhs[index]) return lhs[index] < rhs[index];
    }
    return lhs.len < rhs.len;
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

test "ls tool defaults to cwd, sorts entries, and reports empty directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/empty");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/B.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/a.txt", .data = "" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);

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

    try std.testing.expect(std.mem.indexOf(u8, result.result.content[0].text.text, "a.txt\nB.txt") != null);

    var empty_object: std.json.ObjectMap = .empty;
    defer empty_object.deinit(std.testing.allocator);
    try empty_object.put(std.testing.allocator, "path", .{ .string = "empty" });
    var empty_result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &tool,
        cancel_source.token(),
        "call-empty",
        .{ .object = empty_object },
        null,
    );
    defer empty_result.deinit();
    try std.testing.expectEqualStrings("[directory is empty]", empty_result.result.content[0].text.text);
}
