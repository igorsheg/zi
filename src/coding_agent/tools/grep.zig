const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_files = 500;
pub const max_file_bytes = 256 * 1024;
pub const max_matches = 200;
pub const max_output_bytes = tool_output_policy.default_max_bytes;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "File or directory path to search (defaults to .)" },
    \\    "pattern": { "type": "string", "description": "Literal text to search for" },
    \\    "ignoreCase": { "type": "boolean", "description": "Use ASCII case-insensitive literal search" },
    \\    "limit": { "type": "integer", "description": "Maximum matches to return, capped by tool config" }
    \\  },
    \\  "required": ["pattern"]
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
    ignore_case: bool,
    max_matches: usize,
};

const SearchState = struct {
    files_seen: usize = 0,
    matches: usize = 0,
    truncated: bool = false,
    truncated_by: []const u8 = "matches",
    long_lines_truncated: usize = 0,
    writer: std.Io.Writer.Allocating,
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
    const self: *GrepTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    var args = try parseArgs(params);
    args.max_matches = try path_utils.parseOptionalLimit(params, self.config.max_matches);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
    defer allocator.free(resolved_path);

    var state: SearchState = .{ .writer = .init(allocator) };
    errdefer state.writer.deinit();
    try searchPath(allocator, io, self.config, args, resolved_path, token, &state);
    if (state.matches == 0 and !state.truncated and
        state.writer.written().len + no_matches_text.len <= self.config.max_output_bytes)
    {
        try state.writer.writer.writeAll(no_matches_text);
    }
    if (state.truncated and state.writer.written().len + 26 <= self.config.max_output_bytes) {
        try state.writer.writer.writeAll("\n[grep truncated]");
    }

    const text = try state.writer.toOwnedSlice();
    errdefer allocator.free(text);
    const result_content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(result_content);
    result_content[0] = .{ .text = .{ .text = text } };
    return .{ .allocator = allocator, .result = .{
        .content = result_content,
        .details = try grepDetails(
            allocator,
            state.files_seen,
            state.matches,
            state.truncated,
            state.truncated_by,
            state.long_lines_truncated,
            args.max_matches,
        ),
    } };
}

fn grepDetails(
    allocator: std.mem.Allocator,
    files_seen: usize,
    matches: usize,
    truncated: bool,
    truncated_by: []const u8,
    long_lines_truncated: usize,
    max_matches_value: usize,
) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try path_utils.putJsonField(allocator, &object, "filesSearched", .{ .integer = @intCast(files_seen) });
    try path_utils.putJsonField(allocator, &object, "matches", .{ .integer = @intCast(matches) });
    try path_utils.putJsonField(
        allocator,
        &object,
        "longLinesTruncated",
        .{ .integer = @intCast(long_lines_truncated) },
    );
    var truncation: std.json.ObjectMap = .empty;
    errdefer truncation.deinit(allocator);
    try path_utils.putJsonField(allocator, &truncation, "truncated", .{ .bool = truncated });
    try path_utils.putJsonStringField(allocator, &truncation, "truncatedBy", truncated_by);
    try path_utils.putJsonField(allocator, &truncation, "maxMatches", .{ .integer = @intCast(max_matches_value) });
    try path_utils.putJsonField(allocator, &object, "truncation", .{ .object = truncation });
    return .{ .object = object };
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
            var files = std.ArrayList([]u8).empty;
            defer {
                for (files.items) |file| allocator.free(file);
                files.deinit(allocator);
            }
            while (try walker.next(io)) |entry| {
                try token.throwIfRequested();
                if (path_utils.ignoredSearchPath(entry.path)) {
                    if (entry.kind == .directory) walker.leave(io);
                    continue;
                }
                if (entry.kind != .file) continue;
                if (files.items.len == config.max_files) {
                    state.truncated = true;
                    state.truncated_by = "files";
                    break;
                }
                const relative_path = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(relative_path);
                try files.append(allocator, relative_path);
            }
            std.mem.sort([]u8, files.items, {}, lessThanString);
            for (files.items) |file| {
                const full_path = try std.fs.path.join(allocator, &.{ resolved_path, file });
                defer allocator.free(full_path);
                try searchFile(allocator, io, config, args, full_path, file, token, state);
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
            state.truncated_by = "bytes";
            return;
        },
        else => |unexpected| return unexpected,
    };
    defer allocator.free(content);
    try token.throwIfRequested();

    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (!containsLiteral(line, args.pattern, args.ignore_case)) continue;
        if (state.matches == args.max_matches) {
            state.truncated = true;
            state.truncated_by = "matches";
            return;
        }
        const line_valid_utf8 = std.unicode.utf8ValidateSlice(line);
        const raw_display_line = if (line_valid_utf8) line else "[invalid utf-8 line omitted]";
        const display_line = if (raw_display_line.len > tool_output_policy.grep_max_line_bytes)
            utf8Prefix(raw_display_line, tool_output_policy.grep_max_line_bytes)
        else
            raw_display_line;
        const line_notice = if (raw_display_line.len > tool_output_policy.grep_max_line_bytes)
            " [line truncated]"
        else
            "";
        if (raw_display_line.len > tool_output_policy.grep_max_line_bytes or !line_valid_utf8) {
            state.long_lines_truncated += 1;
        }
        if (state.writer.written().len + display_path.len + display_line.len + line_notice.len + 32 >
            config.max_output_bytes)
        {
            state.truncated = true;
            state.truncated_by = "bytes";
            return;
        }
        if (state.matches > 0) try state.writer.writer.writeByte('\n');
        try state.writer.writer.print("{s}:{d}: {s}{s}", .{ display_path, line_number, display_line, line_notice });
        state.matches += 1;
    }
}

const no_matches_text = "[no matches]";

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn containsLiteral(line: []const u8, pattern: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, line, pattern) != null;
    if (pattern.len > line.len) return false;
    var index: usize = 0;
    while (index + pattern.len <= line.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(line[index .. index + pattern.len], pattern)) return true;
    }
    return false;
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

fn parseArgs(params: std.json.Value) !Args {
    if (params != .object) return error.InvalidToolArguments;
    const path_string = if (params.object.get("path")) |path| blk: {
        if (path != .string or path.string.len == 0) return error.InvalidToolArguments;
        break :blk path.string;
    } else ".";
    const pattern = params.object.get("pattern") orelse return error.InvalidToolArguments;
    const ignore_case_value = params.object.get("ignoreCase");
    if (pattern != .string or pattern.string.len == 0) return error.InvalidToolArguments;
    const ignore_case = if (ignore_case_value) |value| blk: {
        if (value != .bool) return error.InvalidToolArguments;
        break :blk value.bool;
    } else false;
    return .{ .path = path_string, .pattern = pattern.string, .ignore_case = ignore_case, .max_matches = max_matches };
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

    try std.testing.expectEqualStrings("a.txt:1: hello", result.result.content[0].text.text);
}

test "grep tool defaults path, sorts files, ignores dependency directories, and supports ignoreCase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/node_modules/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/b.txt", .data = "Needle" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/a.txt", .data = "needle" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/node_modules/pkg/c.txt", .data = "needle" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "pattern", .{ .string = "needle" });
    try object.put(std.testing.allocator, "ignoreCase", .{ .bool = true });
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

    try std.testing.expectEqualStrings("a.txt:1: needle\n[grep truncated]", result.result.content[0].text.text);
}

test "grep tool reports no matches and truncates long matching lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/a.txt", .data = "nope" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer tool.deinit();

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();

    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "." });
    try object.put(std.testing.allocator, "pattern", .{ .string = "missing" });
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

    var long = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer long.deinit();
    try long.writer.writeAll("needle ");
    try long.writer.splatByteAll('x', tool_output_policy.grep_max_line_bytes + 20);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/long.txt", .data = long.written() });

    var long_object: std.json.ObjectMap = .empty;
    defer long_object.deinit(std.testing.allocator);
    try long_object.put(std.testing.allocator, "path", .{ .string = "long.txt" });
    try long_object.put(std.testing.allocator, "pattern", .{ .string = "needle" });
    var long_result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &tool,
        cancel_source.token(),
        "call-long",
        .{ .object = long_object },
        null,
    );
    defer long_result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, long_result.result.content[0].text.text, "[line truncated]") != null);
}
