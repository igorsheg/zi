const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const mem = @import("../../mem/root.zig");
const runtime = @import("../../runtime/root.zig");
const mutation = @import("file_mutation_queue.zig");

pub const max_edit_read_bytes = 4 * 1024 * 1024;
pub const max_edit_output_bytes = 4 * 1024 * 1024;
pub const max_edits_per_call = 64;

var temp_file_counter: std.atomic.Value(u64) = .init(0);

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to edit" },
    \\    "edits": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "oldText": { "type": "string" },
    \\          "newText": { "type": "string" }
    \\        },
    \\        "required": ["oldText", "newText"]
    \\      }
    \\    },
    \\    "oldText": { "type": "string", "description": "Legacy single replacement old text" },
    \\    "newText": { "type": "string", "description": "Legacy single replacement new text" }
    \\  },
    \\  "required": ["path"]
    \\}
;

pub const EditTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: mem.Owned(std.json.Value),
    owned_queue: mutation.FileMutationQueue = .{},

    pub const Config = struct {
        cwd: []const u8,
        allow_paths_outside_cwd: bool = false,
        max_read_bytes: usize = max_edit_read_bytes,
        max_output_bytes: usize = max_edit_output_bytes,
        mutation_queue: ?*mutation.FileMutationQueue = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !EditTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const parsed_parameters = try mem.Owned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        return .{
            .allocator = allocator,
            .config = .{
                .cwd = cwd,
                .allow_paths_outside_cwd = config.allow_paths_outside_cwd,
                .max_read_bytes = config.max_read_bytes,
                .max_output_bytes = config.max_output_bytes,
                .mutation_queue = config.mutation_queue,
            },
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *EditTool) void {
        self.allocator.free(self.config.cwd);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *EditTool) agent.AgentTool {
        return .{
            .name = "edit",
            .description = "Edit a single file using exact, unique, non-overlapping text replacements.",
            .parameters = self.parsed_parameters.value,
            .label = "edit",
            .execute = .{ .context = self, .call_fn = execute },
            .execution_mode = .sequential,
        };
    }

    fn queue(self: *EditTool) *mutation.FileMutationQueue {
        return self.config.mutation_queue orelse &self.owned_queue;
    }
};

const Replacement = struct {
    old_text: []const u8,
    new_text: []const u8,
};

const EditArgs = struct {
    path: []const u8,
    edits: []const Replacement,
};

const Match = struct {
    start: usize,
    end: usize,
    edit_index: usize,
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.OwnedAgentToolResult {
    try token.throwIfRequested();
    const self: *EditTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(allocator, params);
    defer allocator.free(args.edits);
    const resolved_path = try resolvePath(allocator, io, self.config, args.path);
    defer allocator.free(resolved_path);

    var guard = self.queue().lock();
    defer guard.unlock();

    try token.throwIfRequested();
    const original = try std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(self.config.max_read_bytes),
    );
    defer allocator.free(original);
    const edited = try applyEdits(allocator, original, args.edits, self.config.max_output_bytes);
    defer allocator.free(edited);
    try token.throwIfRequested();
    try atomicWriteFile(allocator, io, resolved_path, edited);

    return textResult(allocator, "Successfully replaced {d} block(s) in {s}.", .{ args.edits.len, args.path });
}

fn parseArgs(allocator: std.mem.Allocator, params: std.json.Value) !EditArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;

    if (params.object.get("edits")) |edits_value| {
        if (edits_value != .array or edits_value.array.items.len == 0) return error.InvalidToolArguments;
        if (edits_value.array.items.len > max_edits_per_call) return error.TooManyEdits;
        const edits = try allocator.alloc(Replacement, edits_value.array.items.len);
        errdefer allocator.free(edits);
        for (edits_value.array.items, edits) |item, *edit| edit.* = try parseReplacement(item);
        return .{ .path = path_value.string, .edits = edits };
    }

    const old_value = params.object.get("oldText") orelse return error.InvalidToolArguments;
    const new_value = params.object.get("newText") orelse return error.InvalidToolArguments;
    if (old_value != .string or new_value != .string) return error.InvalidToolArguments;
    const edits = try allocator.alloc(Replacement, 1);
    edits[0] = .{ .old_text = old_value.string, .new_text = new_value.string };
    return .{ .path = path_value.string, .edits = edits };
}

fn parseReplacement(value: std.json.Value) !Replacement {
    if (value != .object) return error.InvalidToolArguments;
    const old_value = value.object.get("oldText") orelse return error.InvalidToolArguments;
    const new_value = value.object.get("newText") orelse return error.InvalidToolArguments;
    if (old_value != .string or new_value != .string) return error.InvalidToolArguments;
    if (old_value.string.len == 0) return error.InvalidToolArguments;
    return .{ .old_text = old_value.string, .new_text = new_value.string };
}

fn applyEdits(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const Replacement,
    max_output_bytes: usize,
) ![]const u8 {
    var matches = try allocator.alloc(Match, edits.len);
    defer allocator.free(matches);

    for (edits, matches, 0..) |edit, *match, index| {
        const start = findUnique(original, edit.old_text) orelse return error.EditTextNotFoundOrNotUnique;
        match.* = .{ .start = start, .end = start + edit.old_text.len, .edit_index = index };
    }

    std.mem.sort(Match, matches, {}, lessThanMatch);
    for (matches[1..], 1..) |current, index| {
        const previous = matches[index - 1];
        if (current.start < previous.end) return error.OverlappingEdits;
    }

    var total_len = original.len;
    for (edits) |edit| {
        total_len -= edit.old_text.len;
        total_len = std.math.add(usize, total_len, edit.new_text.len) catch return error.EditTooLarge;
        if (total_len > max_output_bytes) return error.EditTooLarge;
    }
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    var source_pos: usize = 0;
    var out_pos: usize = 0;
    for (matches) |match| {
        const prefix = original[source_pos..match.start];
        @memcpy(out[out_pos .. out_pos + prefix.len], prefix);
        out_pos += prefix.len;
        const replacement = edits[match.edit_index].new_text;
        @memcpy(out[out_pos .. out_pos + replacement.len], replacement);
        out_pos += replacement.len;
        source_pos = match.end;
    }
    const suffix = original[source_pos..];
    @memcpy(out[out_pos .. out_pos + suffix.len], suffix);
    return out;
}

fn findUnique(haystack: []const u8, needle: []const u8) ?usize {
    const first = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const rest_start = first + needle.len;
    if (std.mem.indexOf(u8, haystack[rest_start..], needle) != null) return null;
    return first;
}

fn lessThanMatch(_: void, a: Match, b: Match) bool {
    return a.start < b.start;
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, config: EditTool.Config, path: []const u8) ![]const u8 {
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &.{path})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, path });
    errdefer allocator.free(resolved);

    if (!config.allow_paths_outside_cwd) {
        const canonical_cwd = try std.Io.Dir.realPathFileAlloc(.cwd(), io, config.cwd, allocator);
        defer allocator.free(canonical_cwd);
        const canonical_path = try std.Io.Dir.realPathFileAlloc(.cwd(), io, resolved, allocator);
        defer allocator.free(canonical_path);
        if (!isPathInside(canonical_cwd, canonical_path)) return error.PathOutsideCwd;
    }
    return resolved;
}

fn atomicWriteFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const counter = temp_file_counter.fetchAdd(1, .monotonic);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.zi-tmp-{d}-{d}", .{ path, stamp, counter });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, temp_path) catch {};
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = temp_path, .data = content });
    try std.Io.Dir.rename(.cwd(), temp_path, .cwd(), path, io);
}

fn isPathInside(raw_cwd: []const u8, path: []const u8) bool {
    var cwd = raw_cwd;
    while (cwd.len > 1 and std.fs.path.isSep(cwd[cwd.len - 1])) cwd = cwd[0 .. cwd.len - 1];
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (cwd.len == 1 and std.fs.path.isSep(cwd[0])) return true;
    if (path.len == cwd.len) return true;
    return std.fs.path.isSep(path[cwd.len]);
}

fn textResult(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !agent.OwnedAgentToolResult {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(message);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = message } };
    return .{ .allocator = allocator, .result = .{ .content = content } };
}

test "edit tool applies multiple exact replacements against original content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = "one two three" });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer edit_tool.deinit();

    var first: std.json.ObjectMap = .empty;
    defer first.deinit(std.testing.allocator);
    try first.put(std.testing.allocator, "oldText", .{ .string = "one" });
    try first.put(std.testing.allocator, "newText", .{ .string = "1" });
    var second: std.json.ObjectMap = .empty;
    defer second.deinit(std.testing.allocator);
    try second.put(std.testing.allocator, "oldText", .{ .string = "three" });
    try second.put(std.testing.allocator, "newText", .{ .string = "3" });
    var edits: std.json.Array = .init(std.testing.allocator);
    defer edits.deinit();
    try edits.append(.{ .object = first });
    try edits.append(.{ .object = second });
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "edits", .{ .array = edits });

    var cancel_source: runtime.CancelSource = .{};
    var result = try execute(
        std.testing.allocator,
        std.testing.io,
        &edit_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    const written = try tmp.dir.readFileAlloc(std.testing.io, "repo/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("1 two 3", written);
    try std.testing.expectEqualStrings(
        "Successfully replaced 2 block(s) in file.txt.",
        result.result.content[0].text.text,
    );
}

test "edit tool rejects duplicate old text" {
    try std.testing.expectError(
        error.EditTextNotFoundOrNotUnique,
        applyEdits(std.testing.allocator, "x x", &.{.{ .old_text = "x", .new_text = "y" }}, max_edit_output_bytes),
    );
}

test "edit tool rejects output exceeding bound" {
    try std.testing.expectError(
        error.EditTooLarge,
        applyEdits(std.testing.allocator, "x", &.{.{ .old_text = "x", .new_text = "hello" }}, 3),
    );
}

test "edit tool rejects overlapping replacements" {
    try std.testing.expectError(
        error.OverlappingEdits,
        applyEdits(
            std.testing.allocator,
            "abcdef",
            &.{
                .{ .old_text = "abc", .new_text = "x" },
                .{ .old_text = "bcd", .new_text = "y" },
            },
            max_edit_output_bytes,
        ),
    );
}
