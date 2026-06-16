const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const test_support = @import("test_support.zig");
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
    \\    "pattern": { "type": "string", "description": "Optional glob-like pattern (* and ?) that path must match" },
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
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = false,
        max_entries: usize = max_entries,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !FindTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const home_dir = if (config.home_dir) |path| try allocator.dupe(u8, path) else null;
        errdefer if (home_dir) |path| allocator.free(path);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        var owned_config = config;
        owned_config.cwd = cwd;
        owned_config.home_dir = home_dir;
        return .{
            .allocator = allocator,
            .config = owned_config,
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *FindTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
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
    pattern: ?[]const u8,
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
    const args = parseArgs(params) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_arguments",
            "Invalid find arguments: path/name/pattern must be strings and limit must be a positive integer.",
        ),
    };
    const max_entries_value = path_utils.parseOptionalLimit(params, self.config.max_entries) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_limit",
            "Invalid find limit: provide a positive integer.",
        ),
    };
    const resolved_path = path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
    }, args.path) catch |err| return path_utils.pathErrorResult(allocator, "find", args.path, err);
    defer allocator.free(resolved_path);

    var dir = std.Io.Dir.openDir(.cwd(), io, resolved_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return path_utils.pathErrorResult(allocator, "find", args.path, err),
        error.NotDir => return path_utils.pathErrorResult(allocator, "find", args.path, err),
        error.AccessDenied => return path_utils.pathErrorResult(allocator, "find", args.path, err),
        else => return err,
    };
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
        if (args.pattern) |pattern| {
            if (!path_utils.simpleGlobMatch(pattern, entry.path)) continue;
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
    if (emitted == 0 and !truncated and writer.written().len + no_matches_text.len <= self.config.max_output_bytes) {
        try writer.writer.writeAll(no_matches_text);
    }
    if (truncated) try appendTruncationSentinel(&writer, self.config.max_output_bytes);

    return path_utils.ownedTextResult(allocator, try writer.toOwnedSlice(), try path_utils.jsonDetails(allocator, .{
        .entries = emitted,
        .truncation = try path_utils.jsonDetails(allocator, .{
            .truncated = truncated,
            .truncatedBy = truncated_by,
            .maxEntries = max_entries_value,
            .maxFiles = max_visited,
            .maxOutputBytes = self.config.max_output_bytes,
        }),
    }));
}

const find_truncated_sentinel = "[find truncated]";
const no_matches_text = "No files found matching pattern";

fn appendTruncationSentinel(writer: *std.Io.Writer.Allocating, max_bytes: usize) !void {
    const separator: usize = if (writer.written().len == 0) 0 else 1;
    if (writer.written().len + separator + find_truncated_sentinel.len > max_bytes) return;
    if (separator > 0) try writer.writer.writeByte('\n');
    try writer.writer.writeAll(find_truncated_sentinel);
}

fn parseArgs(params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const path_string = if (params.object.get("path")) |path| blk: {
        if (path != .string or path.string.len == 0) return error.InvalidToolArguments;
        break :blk path.string;
    } else ".";
    const name = try optionalString(params.object.get("name"));
    const pattern = try optionalString(params.object.get("pattern"));
    return .{ .path = path_string, .name = name, .pattern = pattern };
}

fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const raw = value orelse return null;
    if (raw != .string) return error.InvalidToolArguments;
    return if (raw.string.len == 0) null else raw.string;
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
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/src");
    try fixture.write("repo/src/main.zig", "");
    try fixture.write("repo/README.md", "");

    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\".\",\"name\":\".zig\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("src/main.zig", result.result.content[0].text.text);
}

test "find tool defaults path, sorts results, applies limit, and ignores dependency directories" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/node_modules/pkg");
    try fixture.write("repo/b.zig", "");
    try fixture.write("repo/a.zig", "");
    try fixture.write("repo/node_modules/pkg/c.zig", "");

    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"name\":\".zig\",\"limit\":1}");
    defer result.deinit();

    try std.testing.expectEqualStrings("a.zig\n[find truncated]", result.result.content[0].text.text);
}

test "find tool accepts pi-style pattern" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/src");
    try fixture.write("repo/src/main.zig", "");
    try fixture.write("repo/src/main.ts", "");

    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\".\",\"pattern\":\"*.zig\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("src/main.zig", result.result.content[0].text.text);
}

test "find tool reports byte and visited truncation details" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/long-name.zig", "");

    var bytes_tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_output_bytes = 4 });
    defer bytes_tool.deinit();
    var bytes_result = try test_support.execute(bytes_tool.tool(), "{\"path\":\".\",\"pattern\":\"*.zig\"}");
    defer bytes_result.deinit();
    try std.testing.expectEqualStrings("", bytes_result.result.content[0].text.text);
    var truncation = bytes_result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 4), truncation.get("maxOutputBytes").?.integer);

    var files_tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_entries = 1 });
    defer files_tool.deinit();
    try fixture.dir("repo/d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/d12/d13/d14/d15/d16");
    var files_result = try test_support.execute(files_tool.tool(), "{\"path\":\".\",\"name\":\"missing\"}");
    defer files_result.deinit();
    truncation = files_result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("files", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, max_visited_multiplier), truncation.get("maxFiles").?.integer);
}

test "find tool reports invalid arguments operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "not a dir");

    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":42}");
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid find arguments: path/name/pattern must be strings and limit must be a positive integer.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);

    var limit_result = try test_support.execute(tool.tool(), "{\"limit\":0}");
    defer limit_result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid find limit: provide a positive integer.",
        limit_result.result.content[0].text.text,
    );
    try std.testing.expectEqualStrings("invalid_limit", limit_result.result.details.?.object.get("reason").?.string);

    var missing_result = try test_support.execute(tool.tool(), "{\"path\":\"missing\"}");
    defer missing_result.deinit();
    try std.testing.expectEqualStrings("Path not found: missing", missing_result.result.content[0].text.text);
    try std.testing.expectEqualStrings("path_not_found", missing_result.result.details.?.object.get("reason").?.string);

    var file_result = try test_support.execute(tool.tool(), "{\"path\":\"file.txt\"}");
    defer file_result.deinit();
    try std.testing.expectEqualStrings("Not a directory: file.txt", file_result.result.content[0].text.text);
    try std.testing.expectEqualStrings("not_directory", file_result.result.details.?.object.get("reason").?.string);
}

test "find tool reports no matches" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/src");
    try fixture.write("repo/src/main.zig", "");

    var tool = try FindTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\".\",\"name\":\"missing\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("No files found matching pattern", result.result.content[0].text.text);
}
