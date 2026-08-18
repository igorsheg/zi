const std = @import("std");
const ai_message = @import("../../ai/message.zig");
const ai_model = @import("../../ai/model.zig");
const tool_api = @import("../../agent/Tool.zig");

const EditTool = @This();

const max_arguments_bytes = 1024 * 1024;
const max_path_bytes = 4096;
const max_file_bytes = 8 * 1024 * 1024;
const max_edits = 64;
const invalid_arguments_message =
    "Edit arguments require a non-empty path and one to 64 oldText/newText replacements.";
const utf8_bom = "\xef\xbb\xbf";

cwd: std.Io.Dir,

pub const definition: ai_message.ToolDefinition = .{
    .name = "edit",
    .description = "Apply exact, unique text replacements to an existing UTF-8 file. " ++
        "All edits are matched against the original file and must not overlap.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to edit (relative or absolute)\"}," ++
        "\"edits\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":64," ++
        "\"description\":\"Exact disjoint replacements matched against the original file\",\"items\":{" ++
        "\"type\":\"object\",\"properties\":{" ++
        "\"oldText\":{\"type\":\"string\",\"description\":\"Exact unique text to replace\"}," ++
        "\"newText\":{\"type\":\"string\",\"description\":\"Replacement text\"}}," ++
        "\"required\":[\"oldText\",\"newText\"],\"additionalProperties\":false}}}," ++
        "\"required\":[\"path\",\"edits\"],\"additionalProperties\":false}",
};

const Edit = struct {
    oldText: []const u8,
    newText: []const u8,
};

const Arguments = struct {
    path: []const u8,
    edits: []const Edit,
};

const Replacement = struct {
    edit_index: usize,
    start: usize,
    end: usize,
    new_text: []const u8,
};

const LineEnding = enum { lf, crlf };

pub fn asTool(self: *EditTool) tool_api.Tool {
    return tool_api.Tool.from(self, definition);
}

pub fn execute(
    self: *EditTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    run_context: tool_api.Tool.RunContext,
    arguments_json: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    try checkCancellation(run_context);
    if (arguments_json.len > max_arguments_bytes) {
        return modelFailure(allocator, "Edit arguments exceed the 1.0MB input limit.", .{});
    }

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var parsed = std.json.parseFromSlice(Arguments, scratch, arguments_json, .{}) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => modelFailure(allocator, invalid_arguments_message, .{}),
        };
    };
    defer parsed.deinit();
    const arguments = parsed.value;
    if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
        !std.unicode.utf8ValidateSlice(arguments.path) or
        arguments.edits.len == 0 or arguments.edits.len > max_edits)
    {
        return modelFailure(allocator, invalid_arguments_message, .{});
    }

    const source = self.cwd.readFileAlloc(
        io,
        arguments.path,
        scratch,
        .limited(max_file_bytes + 1),
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Cancelled,
        error.StreamTooLong => return modelFailure(
            allocator,
            "Cannot edit {s}: file exceeds the 8.0MB input limit.",
            .{arguments.path},
        ),
        else => return modelFailure(
            allocator,
            "Cannot edit {s}: {s}.",
            .{ arguments.path, @errorName(failure) },
        ),
    };
    if (source.len > max_file_bytes) {
        return modelFailure(
            allocator,
            "Cannot edit {s}: file exceeds the 8.0MB input limit.",
            .{arguments.path},
        );
    }
    if (!std.unicode.utf8ValidateSlice(source)) {
        return modelFailure(allocator, "Cannot edit {s}: file is not valid UTF-8.", .{arguments.path});
    }
    try checkCancellation(run_context);

    const has_bom = std.mem.startsWith(u8, source, utf8_bom);
    const source_text = if (has_bom) source[utf8_bom.len..] else source;
    const line_ending = detectLineEnding(source_text);
    const base = normalizeToLf(scratch, source_text) catch return error.OutOfMemory;
    var replacements: [max_edits]Replacement = undefined;

    for (arguments.edits, 0..) |edit, edit_index| {
        if (!std.unicode.utf8ValidateSlice(edit.oldText) or !std.unicode.utf8ValidateSlice(edit.newText)) {
            return modelFailure(allocator, invalid_arguments_message, .{});
        }
        const old_text = normalizeToLf(scratch, edit.oldText) catch return error.OutOfMemory;
        const new_text = normalizeToLf(scratch, edit.newText) catch return error.OutOfMemory;
        if (old_text.len == 0) {
            return emptyOldTextFailure(allocator, arguments.path, edit_index, arguments.edits.len);
        }
        const match_index = std.mem.find(u8, base, old_text) orelse {
            return notFoundFailure(allocator, arguments.path, edit_index, arguments.edits.len);
        };
        const occurrences = countOccurrences(base, old_text);
        if (occurrences > 1) {
            return duplicateFailure(
                allocator,
                arguments.path,
                edit_index,
                arguments.edits.len,
                occurrences,
            );
        }
        replacements[edit_index] = .{
            .edit_index = edit_index,
            .start = match_index,
            .end = match_index + old_text.len,
            .new_text = new_text,
        };
    }

    sortReplacements(replacements[0..arguments.edits.len]);
    for (replacements[1..arguments.edits.len], replacements[0 .. arguments.edits.len - 1]) |current, previous| {
        if (previous.end > current.start) {
            return modelFailure(
                allocator,
                "edits[{d}] and edits[{d}] overlap in {s}. Merge them into one edit or target disjoint regions.",
                .{ previous.edit_index, current.edit_index, arguments.path },
            );
        }
    }

    var normalized_result: std.ArrayList(u8) = .empty;
    defer normalized_result.deinit(scratch);
    var cursor: usize = 0;
    for (replacements[0..arguments.edits.len]) |replacement| {
        normalized_result.appendSlice(scratch, base[cursor..replacement.start]) catch return error.OutOfMemory;
        normalized_result.appendSlice(scratch, replacement.new_text) catch return error.OutOfMemory;
        if (normalized_result.items.len > max_file_bytes) {
            return resultTooLargeFailure(allocator, arguments.path);
        }
        cursor = replacement.end;
    }
    normalized_result.appendSlice(scratch, base[cursor..]) catch return error.OutOfMemory;
    if (normalized_result.items.len > max_file_bytes) return resultTooLargeFailure(allocator, arguments.path);
    if (std.mem.eql(u8, base, normalized_result.items)) {
        return noChangeFailure(allocator, arguments.path, arguments.edits.len);
    }

    const final_content = restoreText(
        scratch,
        normalized_result.items,
        line_ending,
        has_bom,
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResultTooLarge => return resultTooLargeFailure(allocator, arguments.path),
    };
    const output = std.fmt.allocPrint(
        allocator,
        "Successfully replaced {d} block(s) in {s}.",
        .{ arguments.edits.len, arguments.path },
    ) catch return error.OutOfMemory;
    const content = allocator.alloc(ai_message.Content, 1) catch {
        allocator.free(output);
        return error.OutOfMemory;
    };
    content[0] = .{ .text = output };
    checkCancellation(run_context) catch |failure| {
        allocator.free(content);
        allocator.free(output);
        return failure;
    };
    self.cwd.writeFile(io, .{
        .sub_path = arguments.path,
        .data = final_content,
    }) catch |failure| {
        allocator.free(content);
        allocator.free(output);
        return switch (failure) {
            error.Canceled => error.Cancelled,
            else => modelFailure(
                allocator,
                "Cannot edit {s}: {s}.",
                .{ arguments.path, @errorName(failure) },
            ),
        };
    };
    return .{ .success = .{ .content = content } };
}

fn normalizeToLf(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.findScalar(u8, text, '\r') == null) return text;
    const normalized = allocator.alloc(u8, text.len) catch return error.OutOfMemory;
    var source_index: usize = 0;
    var output_index: usize = 0;
    while (source_index < text.len) {
        if (text[source_index] == '\r') {
            normalized[output_index] = '\n';
            output_index += 1;
            source_index += 1;
            if (source_index < text.len and text[source_index] == '\n') source_index += 1;
        } else {
            normalized[output_index] = text[source_index];
            output_index += 1;
            source_index += 1;
        }
    }
    return normalized[0..output_index];
}

fn detectLineEnding(text: []const u8) LineEnding {
    const newline = std.mem.findScalar(u8, text, '\n') orelse return .lf;
    return if (newline > 0 and text[newline - 1] == '\r') .crlf else .lf;
}

const RestoreError = error{ OutOfMemory, ResultTooLarge };

fn restoreText(
    allocator: std.mem.Allocator,
    normalized: []const u8,
    line_ending: LineEnding,
    has_bom: bool,
) RestoreError![]const u8 {
    const bom_bytes: usize = if (has_bom) utf8_bom.len else 0;
    if (normalized.len > max_file_bytes - bom_bytes) return error.ResultTooLarge;
    var output_len = normalized.len + bom_bytes;
    if (line_ending == .crlf) {
        const newline_count = std.mem.count(u8, normalized, "\n");
        if (newline_count > max_file_bytes - output_len) return error.ResultTooLarge;
        output_len += newline_count;
    }
    const output = allocator.alloc(u8, output_len) catch return error.OutOfMemory;
    var output_index: usize = 0;
    if (has_bom) {
        @memcpy(output[0..utf8_bom.len], utf8_bom);
        output_index = utf8_bom.len;
    }
    for (normalized) |byte| {
        if (line_ending == .crlf and byte == '\n') {
            output[output_index] = '\r';
            output_index += 1;
        }
        output[output_index] = byte;
        output_index += 1;
    }
    return output;
}

fn countOccurrences(content: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + needle.len <= content.len) {
        const relative = std.mem.find(u8, content[offset..], needle) orelse break;
        count += 1;
        offset += relative + 1;
    }
    return count;
}

fn sortReplacements(replacements: []Replacement) void {
    for (1..replacements.len) |index| {
        const current = replacements[index];
        var insertion = index;
        while (insertion > 0 and replacements[insertion - 1].start > current.start) : (insertion -= 1) {
            replacements[insertion] = replacements[insertion - 1];
        }
        replacements[insertion] = current;
    }
}

fn checkCancellation(run_context: tool_api.Tool.RunContext) tool_api.ToolFatalError!void {
    if (run_context.cancellation) |token| if (token.isCancelled()) return error.Cancelled;
}

fn modelFailure(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    arguments: anytype,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    const text = std.fmt.allocPrint(allocator, format, arguments) catch return error.OutOfMemory;
    return .{ .failure = text };
}

fn emptyOldTextFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    edit_index: usize,
    edit_count: usize,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    if (edit_count == 1) return modelFailure(allocator, "oldText must not be empty in {s}.", .{path});
    return modelFailure(allocator, "edits[{d}].oldText must not be empty in {s}.", .{ edit_index, path });
}

fn notFoundFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    edit_index: usize,
    edit_count: usize,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    if (edit_count == 1) return modelFailure(
        allocator,
        "Could not find the exact text in {s}. " ++
            "The old text must match exactly including all whitespace and newlines.",
        .{path},
    );
    return modelFailure(
        allocator,
        "Could not find edits[{d}] in {s}. The oldText must match exactly including all whitespace and newlines.",
        .{ edit_index, path },
    );
}

fn duplicateFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    edit_index: usize,
    edit_count: usize,
    occurrences: usize,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    if (edit_count == 1) return modelFailure(
        allocator,
        "Found {d} occurrences of the text in {s}. The text must be unique. " ++
            "Please provide more context to make it unique.",
        .{ occurrences, path },
    );
    return modelFailure(
        allocator,
        "Found {d} occurrences of edits[{d}] in {s}. Each oldText must be unique. " ++
            "Please provide more context to make it unique.",
        .{ occurrences, edit_index, path },
    );
}

fn noChangeFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    edit_count: usize,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    if (edit_count == 1) return modelFailure(
        allocator,
        "No changes made to {s}. The replacement produced identical content.",
        .{path},
    );
    return modelFailure(allocator, "No changes made to {s}. The replacements produced identical content.", .{path});
}

fn resultTooLargeFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
) tool_api.ToolFatalError!tool_api.ToolExecution {
    return modelFailure(allocator, "Cannot edit {s}: final file exceeds the 8.0MB limit.", .{path});
}

test "edit applies disjoint replacements and preserves BOM and CRLF" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "target",
        .data = utf8_bom ++ "alpha\r\nbeta\rgamma\r\n",
    });
    var implementation: EditTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"edits\":[" ++
            "{\"oldText\":\"gamma\\n\",\"newText\":\"GAMMA\\n\"}," ++
            "{\"oldText\":\"alpha\\n\",\"newText\":\"ALPHA\\n\"}]}",
    );
    try std.testing.expectEqualStrings(
        "Successfully replaced 2 block(s) in target.",
        execution.success.content[0].text,
    );
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(utf8_bom ++ "ALPHA\r\nbeta\r\nGAMMA\r\n", bytes);
}

test "edit matches every replacement against the original file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "foo\nbar\nbaz\n" });
    var implementation: EditTool = .{ .cwd = temporary.dir };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"edits\":[" ++
            "{\"oldText\":\"foo\\n\",\"newText\":\"foo bar\\n\"}," ++
            "{\"oldText\":\"bar\\n\",\"newText\":\"BAR\\n\"}," ++
            "{\"oldText\":\"baz\\n\",\"newText\":\"\"}]}",
    );
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("foo bar\nBAR\n", bytes);
}

test "edit rejects semantic failures without changing the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const original = "one\ntwo\none\n";
    const cases = [_]struct { arguments: []const u8, message: []const u8 }{
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[{\"oldText\":\"missing\",\"newText\":\"x\"}]}",
            .message = "Could not find the exact text",
        },
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[{\"oldText\":\"one\",\"newText\":\"x\"}]}",
            .message = "Found 2 occurrences",
        },
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[{\"oldText\":\"\",\"newText\":\"x\"}]}",
            .message = "oldText must not be empty",
        },
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[" ++
                "{\"oldText\":\"one\\ntwo\",\"newText\":\"x\"}," ++
                "{\"oldText\":\"two\\none\",\"newText\":\"y\"}]}",
            .message = "overlap",
        },
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[{\"oldText\":\"two\",\"newText\":\"two\"}]}",
            .message = "No changes made",
        },
        .{
            .arguments = "{\"path\":\"target\",\"edits\":[" ++
                "{\"oldText\":\"two\",\"newText\":\"TWO\"}," ++
                "{\"oldText\":\"missing\",\"newText\":\"x\"}]}",
            .message = "Could not find edits[1]",
        },
    };
    var implementation: EditTool = .{ .cwd = temporary.dir };
    for (cases) |case| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = original });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, case.arguments);
        try std.testing.expect(std.mem.find(u8, execution.failure, case.message) != null);
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "target",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(original, bytes);
    }

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "aaa" });
    var overlap_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer overlap_arena.deinit();
    const overlapping_occurrences = try implementation.execute(
        overlap_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"aa\",\"newText\":\"b\"}]}",
    );
    try std.testing.expect(std.mem.find(u8, overlapping_occurrences.failure, "Found 2 occurrences") != null);
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "target",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("aaa", bytes);
}

test "edit validates arguments and filesystem targets" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    var implementation: EditTool = .{ .cwd = temporary.dir };
    const cases = [_][]const u8{
        "{}",
        "{\"path\":\"\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
        "{\"path\":\"target\",\"edits\":[]}",
        "{\"path\":\"target\",\"edits\":\"[]\"}",
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"a\"}]}",
        "{\"path\":\"target\",\"edits\":[{\"oldText\":1,\"newText\":\"b\"}]}",
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\",\"extra\":1}]}",
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}],\"extra\":1}",
        "{\"path\":\"\\uD800\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"\\uD800\"}]}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try implementation.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_arguments_message, execution.failure);
    }

    const long_path = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(long_path);
    @memset(long_path, 'x');
    const long_path_arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = long_path,
        .edits = &.{.{ .oldText = "a", .newText = "b" }},
    }, .{});
    defer std.testing.allocator.free(long_path_arguments);
    var path_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer path_arena.deinit();
    const path_failure = try implementation.execute(
        path_arena.allocator(),
        std.testing.io,
        .{},
        long_path_arguments,
    );
    try std.testing.expectEqualStrings(invalid_arguments_message, path_failure.failure);

    var missing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer missing_arena.deinit();
    const missing = try implementation.execute(
        missing_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"missing\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
    );
    try std.testing.expect(std.mem.startsWith(u8, missing.failure, "Cannot edit missing:"));

    var directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer directory_arena.deinit();
    const directory = try implementation.execute(
        directory_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"directory\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
    );
    try std.testing.expect(std.mem.startsWith(u8, directory.failure, "Cannot edit directory:"));
}

test "edit enforces argument, edit-count, source, and result bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var implementation: EditTool = .{ .cwd = temporary.dir };

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "argument-limit", .data = "a" });
    const prefix = "{\"path\":\"argument-limit\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"";
    const suffix = "\"}]}";
    const exact_arguments = try std.testing.allocator.alloc(u8, max_arguments_bytes);
    defer std.testing.allocator.free(exact_arguments);
    @memcpy(exact_arguments[0..prefix.len], prefix);
    @memset(exact_arguments[prefix.len .. exact_arguments.len - suffix.len], 'x');
    @memcpy(exact_arguments[exact_arguments.len - suffix.len ..], suffix);
    var exact_arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arguments_arena.deinit();
    _ = try implementation.execute(
        exact_arguments_arena.allocator(),
        std.testing.io,
        .{},
        exact_arguments,
    );
    {
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "argument-limit",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(max_arguments_bytes - prefix.len - suffix.len, bytes.len);
    }

    const oversized_arguments = try std.testing.allocator.alloc(u8, max_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized_arguments);
    @memset(oversized_arguments, 'x');
    var arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arguments_arena.deinit();
    const arguments_failure = try implementation.execute(
        arguments_arena.allocator(),
        std.testing.io,
        .{},
        oversized_arguments,
    );
    try std.testing.expectEqualStrings("Edit arguments exceed the 1.0MB input limit.", arguments_failure.failure);

    const EditInput = struct { oldText: []const u8, newText: []const u8 };
    var edits: [max_edits + 1]EditInput = undefined;
    @memset(&edits, .{ .oldText = "a", .newText = "b" });
    const too_many = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = "target",
        .edits = &edits,
    }, .{});
    defer std.testing.allocator.free(too_many);
    var count_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer count_arena.deinit();
    const count_failure = try implementation.execute(count_arena.allocator(), std.testing.io, .{}, too_many);
    try std.testing.expectEqualStrings(invalid_arguments_message, count_failure.failure);

    var oversized = try temporary.dir.createFile(std.testing.io, "oversized", .{});
    try oversized.setLength(std.testing.io, max_file_bytes + 1);
    oversized.close(std.testing.io);
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source_failure = try implementation.execute(
        source_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"oversized\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
    );
    try std.testing.expect(std.mem.find(u8, source_failure.failure, "8.0MB input limit") != null);

    var exact = try temporary.dir.createFile(std.testing.io, "exact", .{});
    try exact.setLength(std.testing.io, max_file_bytes);
    try exact.writePositionalAll(std.testing.io, "x", 0);
    exact.close(std.testing.io);
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_failure = try implementation.execute(
        result_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"exact\",\"edits\":[{\"oldText\":\"x\",\"newText\":\"xx\"}]}",
    );
    try std.testing.expect(std.mem.find(u8, result_failure.failure, "final file exceeds") != null);
}

test "edit accepts absolute paths and parent traversal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "workspace", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "outside", .data = "before" });
    var workspace = try temporary.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    var implementation: EditTool = .{ .cwd = workspace };
    var traversal_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer traversal_arena.deinit();

    _ = try implementation.execute(
        traversal_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"../outside\",\"edits\":[{\"oldText\":\"before\",\"newText\":\"after\"}]}",
    );
    {
        const bytes = try temporary.dir.readFileAlloc(
            std.testing.io,
            "outside",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("after", bytes);
    }

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "absolute", .data = "old" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const absolute_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "absolute" });
    defer std.testing.allocator.free(absolute_path);
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &.{.{ .oldText = "old", .newText = "new" }},
    }, .{});
    defer std.testing.allocator.free(arguments);
    var absolute_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer absolute_arena.deinit();

    _ = try implementation.execute(absolute_arena.allocator(), std.testing.io, .{}, arguments);
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "absolute",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

test "edit honors pre-cancellation without filesystem mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const original = "before";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = original });
    var implementation: EditTool = .{ .cwd = temporary.dir };
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, implementation.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"before\",\"newText\":\"after\"}]}",
    ));
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);
}
