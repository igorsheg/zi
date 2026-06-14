const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const test_support = @import("test_support.zig");
const tool_output_policy = @import("../tool_output_policy.zig");

pub const max_files = 500;
pub const max_file_bytes = 256 * 1024;
pub const max_matches = 200;
pub const max_context_lines = 5;
pub const max_output_bytes = tool_output_policy.default_max_bytes;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "File or directory path to search (defaults to .)" },
    \\    "pattern": { "type": "string", "description": "Literal text to search for" },
    \\    "glob": { "type": "string", "description": "Optional glob-like file filter (* and ?)" },
    \\    "ignoreCase": { "type": "boolean", "description": "Use ASCII case-insensitive literal search" },
    \\    "literal": { "type": "boolean", "description": "Must be true when provided; regex mode is unsupported" },
    \\    "context": { "type": "integer", "description": "Context lines around each match" },
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
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = false,
        max_files: usize = max_files,
        max_file_bytes: usize = max_file_bytes,
        max_matches: usize = max_matches,
        max_output_bytes: usize = max_output_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !GrepTool {
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

    pub fn deinit(self: *GrepTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
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
    glob: ?[]const u8,
    ignore_case: bool,
    literal: bool,
    context: usize,
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
    var args = parseArgs(params) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_arguments",
            "Invalid grep arguments: provide a non-empty pattern; path/glob must be strings; " ++
                "ignoreCase/literal booleans; context/limit positive integers.",
        ),
    };
    if (!args.literal) {
        return path_utils.textResult(
            allocator,
            "Regex grep is not supported; Zi grep is literal-only. Omit literal or set literal=true.",
            try path_utils.jsonDetails(allocator, .{
                .isError = true,
                .unsupportedMode = @as([]const u8, "regex"),
            }),
        );
    }
    args.max_matches = path_utils.parseOptionalLimit(params, self.config.max_matches) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorTextResult(
            allocator,
            "invalid_limit",
            "Invalid grep limit: provide a positive integer.",
        ),
    };
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
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
    if (state.truncated) try appendTruncationSentinel(&state, self.config.max_output_bytes);

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
                .maxFiles = self.config.max_files,
                .maxOutputBytes = self.config.max_output_bytes,
                .maxFileBytes = self.config.max_file_bytes,
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
        .file => if (fileMatchesGlob(args, args.path))
            try searchFile(allocator, io, config, args, resolved_path, args.path, token, state),
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
                if (!fileMatchesGlob(args, entry.path)) continue;
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
        error.FileTooBig, error.StreamTooLong => {
            state.truncated = true;
            state.truncated_by = "file_size";
            return;
        },
        else => |unexpected| return unexpected,
    };
    defer allocator.free(content);
    try token.throwIfRequested();

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, content, '\n');
    while (split.next()) |line| try lines.append(allocator, line);

    for (lines.items, 0..) |line, index| {
        if (!containsLiteral(line, args.pattern, args.ignore_case)) continue;
        if (state.matches == args.max_matches) {
            state.truncated = true;
            state.truncated_by = "matches";
            return;
        }
        state.matches += 1;
        const line_number = index + 1;
        const start_line = if (args.context == 0 or line_number <= args.context)
            line_number
        else
            line_number - args.context;
        const end_line = if (args.context == 0)
            line_number
        else
            @min(lines.items.len, line_number + args.context);
        var current = start_line;
        while (current <= end_line) : (current += 1) {
            const is_match_line = current == line_number;
            try appendGrepLine(config, display_path, current, lines.items[current - 1], is_match_line, state);
            if (state.truncated) return;
        }
    }
}

fn appendGrepLine(
    config: GrepTool.Config,
    display_path: []const u8,
    line_number: usize,
    line: []const u8,
    is_match_line: bool,
    state: *SearchState,
) !void {
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
    if (state.writer.written().len > 0) try state.writer.writer.writeByte('\n');
    if (is_match_line) {
        try state.writer.writer.print("{s}:{d}: {s}{s}", .{ display_path, line_number, display_line, line_notice });
    } else {
        try state.writer.writer.print("{s}-{d}- {s}{s}", .{ display_path, line_number, display_line, line_notice });
    }
}

const grep_truncated_sentinel = "[grep truncated]";
const no_matches_text = "No matches found";

fn appendTruncationSentinel(state: *SearchState, max_bytes: usize) !void {
    const separator: usize = if (state.writer.written().len == 0) 0 else 1;
    if (state.writer.written().len + separator + grep_truncated_sentinel.len > max_bytes) return;
    if (separator > 0) try state.writer.writer.writeByte('\n');
    try state.writer.writer.writeAll(grep_truncated_sentinel);
}

fn fileMatchesGlob(args: Args, path: []const u8) bool {
    const glob = args.glob orelse return true;
    return path_utils.simpleGlobMatch(glob, path);
}

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
    const glob = try optionalString(params.object.get("glob"));
    const ignore_case_value = params.object.get("ignoreCase");
    const literal = try parseLiteral(params.object.get("literal"));
    const context = try parseContext(params.object.get("context"));
    if (pattern != .string or pattern.string.len == 0) return error.InvalidToolArguments;
    const ignore_case = if (ignore_case_value) |value| blk: {
        if (value != .bool) return error.InvalidToolArguments;
        break :blk value.bool;
    } else false;
    return .{
        .path = path_string,
        .pattern = pattern.string,
        .glob = glob,
        .ignore_case = ignore_case,
        .literal = literal,
        .context = context,
        .max_matches = max_matches,
    };
}

fn parseLiteral(value: ?std.json.Value) !bool {
    const raw = value orelse return true;
    if (raw != .bool) return error.InvalidToolArguments;
    return raw.bool;
}

fn parseContext(value: ?std.json.Value) !usize {
    const raw = value orelse return 0;
    if (raw != .integer or raw.integer < 0) return error.InvalidToolArguments;
    const requested = std.math.cast(usize, raw.integer) orelse return max_context_lines;
    return @min(requested, max_context_lines);
}

fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const raw = value orelse return null;
    if (raw != .string) return error.InvalidToolArguments;
    return if (raw.string.len == 0) null else raw.string;
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

test "grep tool reports invalid arguments operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"pattern\":\"\"}");
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid grep arguments: provide a non-empty pattern; path/glob must be strings; " ++
            "ignoreCase/literal booleans; context/limit positive integers.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);

    var limit_result = try test_support.execute(tool.tool(), "{\"pattern\":\"needle\",\"limit\":0}");
    defer limit_result.deinit();
    try std.testing.expectEqualStrings(
        "Invalid grep limit: provide a positive integer.",
        limit_result.result.content[0].text.text,
    );
    try std.testing.expectEqualStrings("invalid_limit", limit_result.result.details.?.object.get("reason").?.string);
}

test "grep tool reports unsupported regex mode without silently searching literally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "abc");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(
        tool.tool(),
        "{\"path\":\"file.txt\",\"pattern\":\"a.*\",\"literal\":false}",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Regex grep is not supported; Zi grep is literal-only. Omit literal or set literal=true.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);
}

test "grep tool accepts context lines" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "before\nneedle\nafter");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(
        tool.tool(),
        "{\"path\":\"file.txt\",\"pattern\":\"needle\",\"context\":1}",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "file.txt-1- before\nfile.txt:2: needle\nfile.txt-3- after",
        result.result.content[0].text.text,
    );
}

test "grep tool distinguishes file-size truncation from output truncation" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "needle");

    var file_tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_file_bytes = 3 });
    defer file_tool.deinit();
    var file_result = try test_support.execute(file_tool.tool(), "{\"path\":\"file.txt\",\"pattern\":\"needle\"}");
    defer file_result.deinit();
    try std.testing.expectEqualStrings("[grep truncated]", file_result.result.content[0].text.text);
    var truncation = file_result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("file_size", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 3), truncation.get("maxFileBytes").?.integer);

    var output_tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_output_bytes = 12 });
    defer output_tool.deinit();
    var output_result = try test_support.execute(output_tool.tool(), "{\"path\":\"file.txt\",\"pattern\":\"needle\"}");
    defer output_result.deinit();
    truncation = output_result.result.details.?.object.get("truncation").?.object;
    try std.testing.expectEqualStrings("bytes", truncation.get("truncatedBy").?.string);
    try std.testing.expectEqual(@as(i64, 12), truncation.get("maxOutputBytes").?.integer);
}

test "grep tool accepts pi-style glob filter" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.dir("repo/src");
    try fixture.write("repo/a.zig", "needle");
    try fixture.write("repo/b.txt", "needle");
    try fixture.write("repo/src/c.zig", "needle");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(
        tool.tool(),
        "{\"path\":\".\",\"pattern\":\"needle\",\"glob\":\"*.zig\"}",
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "a.zig:1: needle\nsrc/c.zig:1: needle",
        result.result.content[0].text.text,
    );
}

test "grep tool reports no matches and truncates long matching lines" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/a.txt", "nope");

    var tool = try GrepTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer tool.deinit();

    var result = try test_support.execute(tool.tool(), "{\"path\":\".\",\"pattern\":\"missing\"}");
    defer result.deinit();
    try std.testing.expectEqualStrings("No matches found", result.result.content[0].text.text);

    var long = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer long.deinit();
    try long.writer.writeAll("needle ");
    try long.writer.splatByteAll('x', tool_output_policy.grep_max_line_bytes + 20);
    try fixture.write("repo/long.txt", long.written());

    var long_result = try test_support.execute(tool.tool(), "{\"path\":\"long.txt\",\"pattern\":\"needle\"}");
    defer long_result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, long_result.result.content[0].text.text, "[line truncated]") != null);
}
