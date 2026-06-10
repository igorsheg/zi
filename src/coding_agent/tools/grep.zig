const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const test_support = @import("test_support.zig");
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
        var owned_config = config;
        owned_config.cwd = cwd;
        return .{
            .allocator = allocator,
            .config = owned_config,
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

    return path_utils.ownedTextResult(
        allocator,
        try state.writer.toOwnedSlice(),
        try path_utils.jsonDetails(allocator, .{
            .filesSearched = state.files_seen,
            .matches = state.matches,
            .longLinesTruncated = state.long_lines_truncated,
            .truncation = try path_utils.jsonDetails(allocator, .{
                .truncated = state.truncated,
                .truncatedBy = state.truncated_by,
                .maxMatches = args.max_matches,
            }),
        }),
    );
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
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/src");
    try fixture.write("repo/src/a.txt", "hello\nworld");
    try fixture.write("repo/src/b.txt", "nope");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\"src\",\"pattern\":\"hello\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("a.txt:1: hello", result.result.content[0].text.text);
}

test "grep tool defaults path, sorts files, ignores dependency directories, and supports ignoreCase" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/node_modules/pkg");
    try fixture.write("repo/b.txt", "Needle");
    try fixture.write("repo/a.txt", "needle");
    try fixture.write("repo/node_modules/pkg/c.txt", "needle");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(
        tool.tool(),
        "{\"pattern\":\"needle\",\"ignoreCase\":true,\"limit\":1}",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("a.txt:1: needle\n[grep truncated]", result.result.content[0].text.text);
}

test "grep tool reports no matches and truncates long matching lines" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/a.txt", "nope");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\".\",\"pattern\":\"missing\"}");
    defer result.deinit();
    try std.testing.expectEqualStrings("[no matches]", result.result.content[0].text.text);

    var long = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer long.deinit();
    try long.writer.writeAll("needle ");
    try long.writer.splatByteAll('x', tool_output_policy.grep_max_line_bytes + 20);
    try fixture.write("repo/long.txt", long.written());

    var long_result = try test_support.execute(tool.tool(), "{\"path\":\"long.txt\",\"pattern\":\"needle\"}");
    defer long_result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, long_result.result.content[0].text.text, "[line truncated]") != null);
}
