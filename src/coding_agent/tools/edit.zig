const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");
const mutation = @import("file_mutation_queue.zig");
const path_utils = @import("path_utils.zig");

pub const max_edit_read_bytes = 4 * 1024 * 1024;
pub const max_edit_output_bytes = 4 * 1024 * 1024;
pub const max_edits_per_call = 64;
pub const edit_update_chunk_bytes = 16 * 1024;
pub const max_diff_bytes = 16 * 1024;

const utf8_bom = "\xef\xbb\xbf";

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
    \\    }
    \\  },
    \\  "required": ["path", "edits"]
    \\}
;

pub const EditTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),
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
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
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

const LineEnding = enum { lf, crlf };

const TextShape = struct {
    has_bom: bool,
    line_ending: LineEnding,
};

const AppliedEdit = struct {
    original_normalized: []u8,
    normalized: []u8,
    restored: []u8,
    first_changed_line: usize,

    fn deinit(self: *AppliedEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.original_normalized);
        allocator.free(self.normalized);
        allocator.free(self.restored);
        self.* = undefined;
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
    on_update: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *EditTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const args = try parseArgs(allocator, params);
    defer allocator.free(args.edits);
    const resolved_path = try path_utils.resolveExistingPath(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
    }, args.path);
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
    var edited = try applyEditsPreservingTextShape(allocator, original, args.edits, self.config.max_output_bytes);
    defer edited.deinit(allocator);
    try token.throwIfRequested();
    try atomicWriteFileStreamingUpdates(allocator, io, resolved_path, edited.restored, on_update);

    return editResult(
        allocator,
        args.edits.len,
        args.path,
        edited.first_changed_line,
        edited.original_normalized,
        edited.normalized,
    );
}

fn parseArgs(allocator: std.mem.Allocator, params: std.json.Value) !EditArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;

    const edits_value = params.object.get("edits") orelse return error.InvalidToolArguments;
    if (edits_value != .array or edits_value.array.items.len == 0) return error.InvalidToolArguments;
    if (edits_value.array.items.len > max_edits_per_call) return error.TooManyEdits;
    const edits = try allocator.alloc(Replacement, edits_value.array.items.len);
    errdefer allocator.free(edits);
    for (edits_value.array.items, edits) |item, *edit| edit.* = try parseReplacement(item);
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

fn applyEditsPreservingTextShape(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const Replacement,
    max_output_bytes: usize,
) !AppliedEdit {
    const shape = detectTextShape(original);
    const body = if (shape.has_bom) original[utf8_bom.len..] else original;
    const normalized_original = try normalizeLineEndings(allocator, body);
    errdefer allocator.free(normalized_original);

    const normalized_edits = try allocator.alloc(Replacement, edits.len);
    defer allocator.free(normalized_edits);
    for (edits, normalized_edits) |edit, *normalized| {
        normalized.old_text = try normalizeLineEndings(allocator, edit.old_text);
        errdefer allocator.free(normalized.old_text);
        normalized.new_text = try normalizeLineEndings(allocator, edit.new_text);
        errdefer allocator.free(normalized.new_text);
    }
    defer for (normalized_edits) |normalized| {
        allocator.free(normalized.old_text);
        allocator.free(normalized.new_text);
    };

    const normalized = try applyEdits(allocator, normalized_original, normalized_edits, max_output_bytes);
    errdefer allocator.free(normalized);
    const restored = try restoreTextShape(allocator, normalized, shape, max_output_bytes);
    errdefer allocator.free(restored);
    return .{
        .original_normalized = normalized_original,
        .normalized = normalized,
        .restored = restored,
        .first_changed_line = firstChangedLine(normalized_original, normalized),
    };
}

fn applyEdits(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const Replacement,
    max_output_bytes: usize,
) ![]u8 {
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
    if (std.mem.eql(u8, out, original)) return error.NoChanges;
    return out;
}

fn detectTextShape(original: []const u8) TextShape {
    const has_bom = std.mem.startsWith(u8, original, utf8_bom);
    const body = if (has_bom) original[utf8_bom.len..] else original;
    return .{
        .has_bom = has_bom,
        .line_ending = if (std.mem.indexOf(u8, body, "\r\n") != null) .crlf else .lf,
    };
}

fn normalizeLineEndings(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\r') {
            try writer.writer.writeByte('\n');
            index += if (index + 1 < text.len and text[index + 1] == '\n') 2 else 1;
        } else {
            try writer.writer.writeByte(text[index]);
            index += 1;
        }
    }
    return writer.toOwnedSlice();
}

fn restoreTextShape(
    allocator: std.mem.Allocator,
    normalized: []const u8,
    shape: TextShape,
    max_output_bytes: usize,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    if (shape.has_bom) try writer.writer.writeAll(utf8_bom);
    for (normalized) |byte| {
        if (byte == '\n' and shape.line_ending == .crlf) {
            try writer.writer.writeAll("\r\n");
        } else {
            try writer.writer.writeByte(byte);
        }
        if (writer.written().len > max_output_bytes) return error.EditTooLarge;
    }
    return writer.toOwnedSlice();
}

fn firstChangedLine(before: []const u8, after: []const u8) usize {
    var line: usize = 1;
    var index: usize = 0;
    const limit = @min(before.len, after.len);
    while (index < limit and before[index] == after[index]) : (index += 1) {
        if (before[index] == '\n') line += 1;
    }
    return line;
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

fn atomicWriteFileStreamingUpdates(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    on_update: ?agent.AgentToolUpdateCallback,
) !void {
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const counter = temp_file_counter.fetchAdd(1, .monotonic);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.zi-tmp-{d}-{d}", .{ path, stamp, counter });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, temp_path) catch {};

    const file = try std.Io.Dir.createFile(.cwd(), io, temp_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var offset: usize = 0;
    while (offset < content.len) {
        const end = utf8ChunkEnd(content, offset, @min(content.len, offset + edit_update_chunk_bytes));
        const chunk = content[offset..end];
        try writer.interface.writeAll(chunk);
        try emitEditUpdate(allocator, on_update, chunk);
        offset = end;
    }
    try writer.flush();
    try std.Io.Dir.rename(.cwd(), temp_path, .cwd(), path, io);
}

fn emitEditUpdate(
    allocator: std.mem.Allocator,
    on_update: ?agent.AgentToolUpdateCallback,
    chunk: []const u8,
) !void {
    const callback = on_update orelse return;
    const text = try allocator.dupe(u8, chunk);
    defer allocator.free(text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try callback.call(.{ .content = content });
}

fn utf8ChunkEnd(content: []const u8, start: usize, proposed_end: usize) usize {
    std.debug.assert(start < proposed_end);
    std.debug.assert(proposed_end <= content.len);
    if (proposed_end == content.len) return proposed_end;
    var end = proposed_end;
    while (end > start and (content[end] & 0xc0) == 0x80) : (end -= 1) {}
    if (end == start) return proposed_end;
    return end;
}

fn lineAt(text: []const u8, wanted_line: usize) []const u8 {
    var line: usize = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index == text.len or text[index] == '\n') {
            if (line == wanted_line) return text[start..index];
            line += 1;
            start = index + 1;
        }
    }
    return "";
}

fn editResult(
    allocator: std.mem.Allocator,
    replacements: usize,
    path: []const u8,
    first_changed_line: usize,
    before: []const u8,
    after: []const u8,
) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "Successfully replaced {d} block(s) in {s}.",
        .{ replacements, path },
    );
    errdefer allocator.free(message);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = message } };
    var details: std.json.ObjectMap = .empty;
    errdefer details.deinit(allocator);
    try path_utils.putJsonField(allocator, &details, "replacements", .{ .integer = @intCast(replacements) });
    try path_utils.putJsonField(
        allocator,
        &details,
        "firstChangedLine",
        .{ .integer = @intCast(first_changed_line) },
    );
    const before_line = lineAt(before, first_changed_line);
    const after_line = lineAt(after, first_changed_line);
    const diff = try std.fmt.allocPrint(
        allocator,
        "@@ line {d} @@\n- {s}\n+ {s}",
        .{ first_changed_line, before_line, after_line },
    );
    errdefer allocator.free(diff);
    try path_utils.putJsonField(allocator, &details, "diff", .{ .string = diff });
    const patch = try std.fmt.allocPrint(
        allocator,
        "--- {s}\n+++ {s}\n@@ line {d} @@\n- {s}\n+ {s}",
        .{ path, path, first_changed_line, before_line, after_line },
    );
    errdefer allocator.free(patch);
    try path_utils.putJsonField(allocator, &details, "patch", .{ .string = patch });
    return .{ .allocator = allocator, .result = .{ .content = content, .details = .{ .object = details } } };
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

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
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
    const details = result.result.details.?.object;
    try std.testing.expectEqual(@as(i64, 1), details.get("firstChangedLine").?.integer);
    try std.testing.expect(details.get("diff").? == .string);
    try std.testing.expect(details.get("patch").? == .string);
}

const EditUpdateCapture = struct {
    writer: std.Io.Writer.Allocating,
    count: usize = 0,

    fn deinit(self: *EditUpdateCapture) void {
        self.writer.deinit();
        self.* = undefined;
    }
};

fn captureEditUpdate(context: ?*anyopaque, partial_result: agent.AgentToolResult) anyerror!void {
    const capture: *EditUpdateCapture = @ptrCast(@alignCast(context.?));
    capture.count += 1;
    for (partial_result.content) |content| switch (content) {
        .text => |text| try capture.writer.writer.writeAll(text.text),
        .image => {},
    };
}

test "edit tool preserves BOM and CRLF while matching normalized text and tracks firstChangedLine" {
    var edited = try applyEditsPreservingTextShape(
        std.testing.allocator,
        utf8_bom ++ "one\r\ntwo\r\n",
        &.{.{ .old_text = "one\ntwo", .new_text = "1\n2" }},
        max_edit_output_bytes,
    );
    defer edited.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(utf8_bom ++ "1\r\n2\r\n", edited.restored);
    try std.testing.expectEqual(@as(usize, 1), edited.first_changed_line);
}

test "edit tool rejects no-op replacement" {
    try std.testing.expectError(error.NoChanges, applyEdits(
        std.testing.allocator,
        "same",
        &.{.{ .old_text = "same", .new_text = "same" }},
        max_edit_output_bytes,
    ));
}

test "edit tool streams utf8 safe edited content chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");
    const original = "old\n" ++ ("中" ** 6000);
    const replacement = "new\n" ++ ("中" ** 6000);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/file.txt", .data = original });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd] });
    defer edit_tool.deinit();

    var edit: std.json.ObjectMap = .empty;
    defer edit.deinit(std.testing.allocator);
    try edit.put(std.testing.allocator, "oldText", .{ .string = original });
    try edit.put(std.testing.allocator, "newText", .{ .string = replacement });
    var edits: std.json.Array = .init(std.testing.allocator);
    defer edits.deinit();
    try edits.append(.{ .object = edit });
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "edits", .{ .array = edits });

    var zio_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var capture: EditUpdateCapture = .{ .writer = .init(std.testing.allocator) };
    defer capture.deinit();
    var result = try execute(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        &edit_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        .{ .context = &capture, .call_fn = captureEditUpdate },
    );
    defer result.deinit();

    try std.testing.expect(capture.count > 1);
    try std.testing.expectEqualStrings(replacement, capture.writer.written());
    const written = try tmp.dir.readFileAlloc(std.testing.io, "repo/file.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(replacement, written);
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
