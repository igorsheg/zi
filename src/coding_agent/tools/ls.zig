const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const test_support = @import("test_support.zig");
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
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = false,
        max_entries: usize = max_entries,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !LsTool {
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

    pub fn deinit(self: *LsTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
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
    const path = parsePath(params) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_arguments",
            "Invalid ls arguments: path must be a string and limit must be a positive integer.",
        ),
    };
    const max_entries_value = path_utils.parseOptionalLimit(params, self.config.max_entries) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_limit",
            "Invalid ls limit: provide a positive integer.",
        ),
    };
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
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
    if (truncated) try appendTruncationSentinel(&writer, self.config.max_output_bytes);

    return path_utils.ownedTextResult(allocator, try writer.toOwnedSlice(), try path_utils.jsonDetails(allocator, .{
        .entries = emitted,
        .truncation = try path_utils.jsonDetails(allocator, .{
            .truncated = truncated,
            .truncatedBy = truncated_by,
            .maxEntries = max_entries_value,
            .maxScannedEntries = max_scan_entries,
            .maxOutputBytes = self.config.max_output_bytes,
        }),
    }));
}

const listing_truncated_sentinel = "[listing truncated]";
const empty_directory_text = "(empty directory)";

fn appendTruncationSentinel(writer: *std.Io.Writer.Allocating, max_bytes: usize) !void {
    const separator: usize = if (writer.written().len == 0) 0 else 1;
    if (writer.written().len + separator + listing_truncated_sentinel.len > max_bytes) return;
    if (separator > 0) try writer.writer.writeByte('\n');
    try writer.writer.writeAll(listing_truncated_sentinel);
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
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/dir/nested");
    try fixture.write("repo/dir/a.txt", "a");

    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\"dir\"}");
    defer result.deinit();

    const text = result.result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nested/") != null);
}

test "ls tool reports invalid arguments operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":42}");
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid ls arguments: path must be a string and limit must be a positive integer.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);

    var limit_result = try test_support.execute(tool.tool(), "{\"limit\":0}");
    defer limit_result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid ls limit: provide a positive integer.",
        limit_result.result.content[0].text.text,
    );
    try std.testing.expectEqualStrings("invalid_limit", limit_result.result.details.?.object.get("reason").?.string);
}

test "ls tool reports byte truncation details and bounds sentinel" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/long-name.txt", "");

    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_output_bytes = 4 });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{}");
    defer result.deinit();

    try std.testing.expectEqualStrings("", result.result.content[0].text.text);
    const truncation = result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 4), truncation.get("maxOutputBytes").?.integer);
}

test "ls tool defaults to cwd, sorts entries, and reports empty directories" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/empty");
    try fixture.write("repo/B.txt", "");
    try fixture.write("repo/a.txt", "");

    var tool = try LsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{}");
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.result.content[0].text.text, "a.txt\nB.txt") != null);

    var empty_result = try test_support.execute(tool.tool(), "{\"path\":\"empty\"}");
    defer empty_result.deinit();
    try std.testing.expectEqualStrings("(empty directory)", empty_result.result.content[0].text.text);
}
