const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const edit_diff = @import("edit_diff.zig");
const file_mutation_queue = @import("file_mutation_queue.zig");
const path_utils = @import("path_utils.zig");
const paths_mod = @import("../paths.zig");
const test_support = @import("test_support.zig");

pub const max_edit_read_bytes = 4 * 1024 * 1024;
pub const max_edit_output_bytes = 4 * 1024 * 1024;
pub const max_edits_per_call = 64;
const duplicate_line_hint_max = 8;

const utf8_bom = "\xef\xbb\xbf";

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to the file to edit (relative or absolute)" },
    \\    "edits": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "oldText": { "type": "string", "description": "Exact text to replace; must match uniquely" },
    \\          "newText": { "type": "string", "description": "Replacement text" }
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
    default_mutation_queue: file_mutation_queue.FileMutationQueue = .{},

    pub const Config = struct {
        cwd: []const u8,
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = true,
        max_read_bytes: usize = max_edit_read_bytes,
        max_output_bytes: usize = max_edit_output_bytes,
        mutation_queue: ?*file_mutation_queue.FileMutationQueue = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !EditTool {
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

    pub fn deinit(self: *EditTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *EditTool) agent.AgentTool {
        return .{
            .name = "edit",
            .description = "Edit a single file using exact text replacement. " ++
                "Every oldText must match a unique, non-overlapping region. " ++
                "If changes touch nearby lines, merge them into one edit.",
            .parameters = self.parsed_parameters.value,
            .label = "edit",
            .execute = .{ .context = self, .call_fn = execute },
            // Sequential execution is the file-mutation serialization guarantee:
            // edit and write never run concurrently with another tool call.
            .execution_mode = .sequential,
        };
    }
};

const Replacement = struct {
    old_text: []const u8,
    new_text: []const u8,
};

const EditArgs = struct {
    path: []const u8,
    edits: []const Replacement,

    fn deinit(self: *EditArgs, allocator: std.mem.Allocator) void {
        for (self.edits) |edit| {
            allocator.free(edit.old_text);
            allocator.free(edit.new_text);
        }
        allocator.free(self.edits);
        self.* = undefined;
    }
};

const Match = struct {
    start: usize,
    end: usize,
    edit_index: usize,
};

const EditFailureKind = enum {
    none,
    empty_old_text,
    old_text_not_found,
    old_text_not_unique,
    overlapping_edits,
    no_changes,
};

const EditFailure = struct {
    kind: EditFailureKind = .none,
    edit_index: usize = 0,
    other_edit_index: usize = 0,
    occurrences: usize = 0,
    total_edits: usize = 0,
    match_lines: [duplicate_line_hint_max]usize = @splat(0),
    match_line_count: usize = 0,
    match_lines_truncated: bool = false,
};

const MatchCount = struct {
    first: ?usize = null,
    occurrences: usize = 0,
    match_lines: [duplicate_line_hint_max]usize = @splat(0),
    match_line_count: usize = 0,
    match_lines_truncated: bool = false,
};

const LineEnding = enum { lf, crlf };

const TextShape = struct {
    has_bom: bool,
    line_ending: LineEnding,
};

const EditOutput = struct {
    original_normalized: []u8,
    normalized: []u8,
    restored: []u8,
    diff: []u8,
    first_changed_line: usize,

    fn deinit(self: *EditOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.original_normalized);
        allocator.free(self.normalized);
        allocator.free(self.restored);
        allocator.free(self.diff);
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
    var args = parseArgs(allocator, params) catch |err| switch (err) {
        error.InvalidToolArguments => return path_utils.errorResult(
            allocator,
            "invalid_arguments",
            "Invalid edit arguments: provide path and one or more edits with string oldText and string newText.",
        ),
        error.TooManyEdits => return path_utils.errorResult(
            allocator,
            "too_many_edits",
            "Edit failed: too many replacements in one call; split the edit into smaller batches.",
        ),
        else => return err,
    };
    defer args.deinit(allocator);
    const resolved_path = paths_mod.ToolPaths.resolveExisting(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
    }, args.path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidToolArguments, error.PathOutsideCwd => return path_utils.errorResultWithPathFmt(
            allocator,
            "Invalid edit path {s}: {s}",
            "invalid_path",
            args.path,
            err,
            .{ args.path, @errorName(err) },
        ),
        else => return path_utils.errorResultWithPathFmt(
            allocator,
            "Edit path resolution failed for {s}: {s}",
            "path_error",
            args.path,
            err,
            .{ args.path, @errorName(err) },
        ),
    };
    defer allocator.free(resolved_path);

    try token.throwIfRequested();
    const original = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(self.config.max_read_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return path_utils.errorResultWithPathFmt(
            allocator,
            "Edit failed to read {s}: {s}",
            "read_failed",
            args.path,
            err,
            .{ args.path, @errorName(err) },
        ),
    };
    defer allocator.free(original);
    if (!std.unicode.utf8ValidateSlice(original)) return nonUtf8FileResult(allocator, args.path);
    var failure: EditFailure = .{};
    var edited = applyEditsPreservingTextShape(
        allocator,
        original,
        args.edits,
        self.config.max_output_bytes,
        &failure,
    ) catch |err| switch (err) {
        error.EmptyOldText,
        error.EditTextNotFound,
        error.EditTextNotUnique,
        error.OverlappingEdits,
        error.NoChanges,
        => return editFailureResult(allocator, args.path, failure),
        error.EditTooLarge => return editTooLargeResult(allocator, self.config.max_output_bytes),
        else => return err,
    };
    defer edited.deinit(allocator);
    try token.throwIfRequested();
    _ = on_update;
    var result = try editResult(
        allocator,
        args.edits.len,
        args.path,
        edited.first_changed_line,
        edited.diff,
    );
    errdefer result.deinit();
    try token.throwIfRequested();
    const mutation_queue = self.config.mutation_queue orelse &self.default_mutation_queue;
    try mutation_queue.atomicWriteFileStreamingUpdates(allocator, io, resolved_path, edited.restored, null, .{});

    return result;
}

fn parseArgs(allocator: std.mem.Allocator, params: std.json.Value) !EditArgs {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse params.object.get("file_path") orelse
        return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;

    var parsed_edits: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_edits) |*parsed| parsed.deinit();
    const edits_value = try normalizedEditsValue(allocator, params.object.get("edits"), &parsed_edits);
    const legacy = legacyReplacement(params.object);
    const edit_count = replacementCount(edits_value) + if (legacy != null) @as(usize, 1) else 0;
    if (edit_count == 0) return error.InvalidToolArguments;
    if (edit_count > max_edits_per_call) return error.TooManyEdits;

    const edits = try allocator.alloc(Replacement, edit_count);
    var initialized: usize = 0;
    errdefer {
        for (edits[0..initialized]) |edit| {
            allocator.free(edit.old_text);
            allocator.free(edit.new_text);
        }
        allocator.free(edits);
    }
    if (edits_value) |value| {
        if (value != .array) return error.InvalidToolArguments;
        for (value.array.items) |item| {
            edits[initialized] = try parseReplacement(allocator, item);
            initialized += 1;
        }
    }
    if (legacy) |replacement| {
        edits[initialized] = try parseReplacementFields(allocator, replacement.old_value, replacement.new_value);
        initialized += 1;
    }
    std.debug.assert(initialized == edits.len);
    return .{ .path = path_value.string, .edits = edits };
}

fn normalizedEditsValue(
    allocator: std.mem.Allocator,
    raw_value: ?std.json.Value,
    parsed_edits: *?std.json.Parsed(std.json.Value),
) !?std.json.Value {
    const value = raw_value orelse return null;
    if (value == .string) {
        parsed_edits.* = std.json.parseFromSlice(std.json.Value, allocator, value.string, .{}) catch
            return error.InvalidToolArguments;
        return parsed_edits.*.?.value;
    }
    return value;
}

const LegacyReplacement = struct {
    old_value: std.json.Value,
    new_value: std.json.Value,
};

fn legacyReplacement(object: std.json.ObjectMap) ?LegacyReplacement {
    const old_value = object.get("oldText") orelse return null;
    const new_value = object.get("newText") orelse return null;
    return .{ .old_value = old_value, .new_value = new_value };
}

fn replacementCount(edits_value: ?std.json.Value) usize {
    const value = edits_value orelse return 0;
    if (value != .array) return 0;
    return value.array.items.len;
}

fn parseReplacement(allocator: std.mem.Allocator, value: std.json.Value) !Replacement {
    if (value != .object) return error.InvalidToolArguments;
    const old_value = value.object.get("oldText") orelse return error.InvalidToolArguments;
    const new_value = value.object.get("newText") orelse return error.InvalidToolArguments;
    return parseReplacementFields(allocator, old_value, new_value);
}

fn parseReplacementFields(
    allocator: std.mem.Allocator,
    old_value: std.json.Value,
    new_value: std.json.Value,
) !Replacement {
    if (old_value != .string or new_value != .string) return error.InvalidToolArguments;
    const old_text = try allocator.dupe(u8, old_value.string);
    errdefer allocator.free(old_text);
    const new_text = try allocator.dupe(u8, new_value.string);
    return .{ .old_text = old_text, .new_text = new_text };
}

fn applyEditsPreservingTextShape(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const Replacement,
    max_output_bytes: usize,
    failure: ?*EditFailure,
) !EditOutput {
    const shape = detectTextShape(original);
    const body = if (shape.has_bom) original[utf8_bom.len..] else original;
    const normalized_original = try normalizeLineEndings(allocator, body);
    errdefer allocator.free(normalized_original);

    const normalized_edits = try allocator.alloc(Replacement, edits.len);
    defer allocator.free(normalized_edits);
    var normalized_count: usize = 0;
    defer for (normalized_edits[0..normalized_count]) |normalized| {
        allocator.free(normalized.old_text);
        allocator.free(normalized.new_text);
    };
    for (edits, normalized_edits) |edit, *normalized| {
        const old_text = try normalizeLineEndings(allocator, edit.old_text);
        const new_text = normalizeLineEndings(allocator, edit.new_text) catch |err| {
            allocator.free(old_text);
            return err;
        };
        normalized.* = .{ .old_text = old_text, .new_text = new_text };
        normalized_count += 1;
    }

    var applied: [max_edits_per_call]edit_diff.AppliedEdit = undefined;
    const normalized = try applyEdits(
        allocator,
        normalized_original,
        normalized_edits,
        max_output_bytes,
        applied[0..edits.len],
        failure,
    );
    errdefer allocator.free(normalized);
    const diff = try edit_diff.render(allocator, normalized_original, applied[0..edits.len]);
    errdefer allocator.free(diff);
    const restored = try restoreTextShape(allocator, normalized, shape, max_output_bytes);
    errdefer allocator.free(restored);
    return .{
        .original_normalized = normalized_original,
        .normalized = normalized,
        .restored = restored,
        .diff = diff,
        .first_changed_line = firstChangedLine(normalized_original, normalized),
    };
}

fn applyEdits(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const Replacement,
    max_output_bytes: usize,
    applied_edits: []edit_diff.AppliedEdit,
    failure: ?*EditFailure,
) ![]u8 {
    std.debug.assert(applied_edits.len == edits.len);
    var matches = try allocator.alloc(Match, edits.len);
    defer allocator.free(matches);

    for (edits, matches, 0..) |edit, *match, index| {
        if (edit.old_text.len == 0) {
            setEditFailure(failure, .{
                .kind = .empty_old_text,
                .edit_index = index,
                .total_edits = edits.len,
            });
            return error.EmptyOldText;
        }
        const count = countMatches(original, edit.old_text);
        if (count.occurrences == 0) {
            setEditFailure(failure, .{
                .kind = .old_text_not_found,
                .edit_index = index,
                .total_edits = edits.len,
            });
            return error.EditTextNotFound;
        }
        if (count.occurrences > 1) {
            setEditFailure(failure, .{
                .kind = .old_text_not_unique,
                .edit_index = index,
                .occurrences = count.occurrences,
                .total_edits = edits.len,
                .match_lines = count.match_lines,
                .match_line_count = count.match_line_count,
                .match_lines_truncated = count.match_lines_truncated,
            });
            return error.EditTextNotUnique;
        }
        const start = count.first.?;
        match.* = .{ .start = start, .end = start + edit.old_text.len, .edit_index = index };
    }

    std.mem.sort(Match, matches, {}, lessThanMatch);
    for (matches[1..], 1..) |current, index| {
        const previous = matches[index - 1];
        if (current.start < previous.end) {
            setEditFailure(failure, .{
                .kind = .overlapping_edits,
                .edit_index = previous.edit_index,
                .other_edit_index = current.edit_index,
                .total_edits = edits.len,
            });
            return error.OverlappingEdits;
        }
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
    for (matches, 0..) |match, applied_index| {
        applied_edits[applied_index] = .{
            .base_offset = match.start,
            .old_text = edits[match.edit_index].old_text,
            .new_text = edits[match.edit_index].new_text,
        };
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
    if (std.mem.eql(u8, out, original)) {
        setEditFailure(failure, .{ .kind = .no_changes, .total_edits = edits.len });
        return error.NoChanges;
    }
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

fn countMatches(haystack: []const u8, needle: []const u8) MatchCount {
    std.debug.assert(needle.len > 0);
    var result: MatchCount = .{};
    var offset: usize = 0;
    var line_scan_offset: usize = 0;
    var line: usize = 1;
    while (offset <= haystack.len) {
        const found = std.mem.find(u8, haystack[offset..], needle) orelse break;
        const absolute = offset + found;
        if (result.first == null) result.first = absolute;
        if (result.match_line_count < duplicate_line_hint_max) {
            while (line_scan_offset < absolute) : (line_scan_offset += 1) {
                if (haystack[line_scan_offset] == '\n') line += 1;
            }
            result.match_lines[result.match_line_count] = line;
            result.match_line_count += 1;
        } else {
            result.match_lines_truncated = true;
        }
        result.occurrences += 1;
        offset = absolute + needle.len;
    }
    return result;
}

fn setEditFailure(failure: ?*EditFailure, value: EditFailure) void {
    if (failure) |out| out.* = value;
}

fn lessThanMatch(_: void, a: Match, b: Match) bool {
    return a.start < b.start;
}

fn editFailureResult(
    allocator: std.mem.Allocator,
    path: []const u8,
    failure: EditFailure,
) !agent.ToolExecutionResult {
    switch (failure.kind) {
        .empty_old_text => {
            if (failure.total_edits == 1) return editFailureResultFmt(
                allocator,
                "oldText must not be empty in {s}.",
                editFailureReason(failure.kind),
                .{path},
            );
            return editFailureResultFmt(
                allocator,
                "edits[{d}].oldText must not be empty in {s}.",
                editFailureReason(failure.kind),
                .{ failure.edit_index, path },
            );
        },
        .old_text_not_found => {
            if (failure.total_edits == 1) return editFailureResultFmt(
                allocator,
                "Could not find the exact text in {s}. " ++
                    "The old text must match exactly including all whitespace and newlines.",
                editFailureReason(failure.kind),
                .{path},
            );
            return editFailureResultFmt(
                allocator,
                "Could not find edits[{d}] in {s}. " ++
                    "The oldText must match exactly including all whitespace and newlines.",
                editFailureReason(failure.kind),
                .{ failure.edit_index, path },
            );
        },
        .old_text_not_unique => {
            var line_hint_buffer: [160]u8 = undefined;
            const line_hint = duplicateLineHint(&line_hint_buffer, failure);
            if (failure.total_edits == 1) return editFailureResultFmt(
                allocator,
                "Found {d} occurrences of the text in {s}{s}. " ++
                    "The text must be unique. Please provide more context to make it unique.",
                editFailureReason(failure.kind),
                .{ failure.occurrences, path, line_hint },
            );
            return editFailureResultFmt(
                allocator,
                "Found {d} occurrences of edits[{d}] in {s}{s}. " ++
                    "Each oldText must be unique. Please provide more context to make it unique.",
                editFailureReason(failure.kind),
                .{ failure.occurrences, failure.edit_index, path, line_hint },
            );
        },
        .overlapping_edits => return editFailureResultFmt(
            allocator,
            "edits[{d}] and edits[{d}] overlap in {s}. " ++
                "Merge them into one edit or target disjoint regions.",
            editFailureReason(failure.kind),
            .{ failure.edit_index, failure.other_edit_index, path },
        ),
        .no_changes => {
            if (failure.total_edits == 1) return editFailureResultFmt(
                allocator,
                "No changes made to {s}. The replacement produced identical content. " ++
                    "This might indicate an issue with special characters or the text not existing as expected.",
                editFailureReason(failure.kind),
                .{path},
            );
            return editFailureResultFmt(
                allocator,
                "No changes made to {s}. The replacements produced identical content.",
                editFailureReason(failure.kind),
                .{path},
            );
        },
        .none => return path_utils.errorResult(
            allocator,
            "edit_failed",
            "Edit failed.",
        ),
    }
}

fn editFailureReason(kind: EditFailureKind) []const u8 {
    return switch (kind) {
        .none => "edit_failed",
        .empty_old_text => "empty_old_text",
        .old_text_not_found => "old_text_not_found",
        .old_text_not_unique => "old_text_not_unique",
        .overlapping_edits => "overlapping_edits",
        .no_changes => "no_changes",
    };
}

fn editFailureResultFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    reason: []const u8,
    args: anytype,
) !agent.ToolExecutionResult {
    return path_utils.errorResultFmt(allocator, fmt, reason, args);
}

fn duplicateLineHint(buffer: []u8, failure: EditFailure) []const u8 {
    if (failure.match_line_count == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll(" at lines ") catch return "";
    for (failure.match_lines[0..failure.match_line_count], 0..) |line, index| {
        if (index > 0) writer.writeAll(", ") catch return writer.buffered();
        writer.print("{d}", .{line}) catch return writer.buffered();
    }
    if (failure.match_lines_truncated) writer.writeAll(" and more") catch return writer.buffered();
    return writer.buffered();
}

fn editTooLargeResult(allocator: std.mem.Allocator, max_output_bytes: usize) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "Edit failed: output would exceed the {d} byte limit.",
        .{max_output_bytes},
    );
    errdefer allocator.free(message);
    const details = try path_utils.jsonDetails(allocator, .{
        .isError = true,
        .reason = @as([]const u8, "output_too_large"),
        .maxBytes = max_output_bytes,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, message, details);
}

fn nonUtf8FileResult(allocator: std.mem.Allocator, path: []const u8) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(allocator, "Edit failed: {s} is not valid UTF-8 text.", .{path});
    errdefer allocator.free(message);
    const details = try path_utils.jsonDetails(allocator, .{
        .isError = true,
        .reason = @as([]const u8, "non_utf8_file"),
        .path = path,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, message, details);
}

fn editResult(
    allocator: std.mem.Allocator,
    replacements: usize,
    path: []const u8,
    first_changed_line: usize,
    diff: []const u8,
) !agent.ToolExecutionResult {
    const patch = try std.fmt.allocPrint(
        allocator,
        "--- {s}\n+++ {s}\n{s}",
        .{ path, path, diff },
    );
    defer allocator.free(patch);
    // The diff is already bounded and truncated by edit_diff.render (diff_bytes_max).
    // A large edit still lands; the confirmation diff is just summarized rather than
    // turning a valid replacement into a hard error (which previously forced callers
    // into bash string-surgery that corrupted files).
    const details = try path_utils.jsonDetails(allocator, .{
        .path = path,
        .replacements = replacements,
        .firstChangedLine = first_changed_line,
        .diff = diff,
        .patch = patch,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    const message = try std.fmt.allocPrint(
        allocator,
        "Successfully replaced {d} block(s) in {s}.",
        .{ replacements, path },
    );
    return path_utils.ownedTextResult(allocator, message, details);
}

test "edit tool applies multiple exact replacements against original content" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "one two three");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[
        \\  {"oldText":"one","newText":"1"},
        \\  {"oldText":"three","newText":"3"}]}
        ,
    );
    defer result.deinit();

    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("1 two 3", written);
    try std.testing.expectEqualStrings(
        "Successfully replaced 2 block(s) in file.txt.",
        result.result.content[0].text.text,
    );
    const details = result.result.details.?.object;
    try std.testing.expectEqualStrings("file.txt", details.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 2), details.get("replacements").?.integer);
    try std.testing.expectEqual(@as(i64, 1), details.get("firstChangedLine").?.integer);
    try std.testing.expect(details.get("diff").? == .string);
    try std.testing.expect(details.get("patch").? == .string);
}

test "edit tool accepts legacy top-level replacement and file_path" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "old");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        "{\"file_path\":\"file.txt\",\"oldText\":\"old\",\"newText\":\"new\"}",
    );
    defer result.deinit();

    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("new", written);
    try std.testing.expectEqual(@as(i64, 1), result.result.details.?.object.get("replacements").?.integer);
}

test "edit tool accepts edits encoded as json string" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "old");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        "{\"path\":\"file.txt\",\"edits\":\"[{\\\"oldText\\\":\\\"old\\\",\\\"newText\\\":\\\"new\\\"}]\"}",
    );
    defer result.deinit();

    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("new", written);
}

test "edit tool preserves BOM and CRLF while matching normalized text and tracks firstChangedLine" {
    var edited = try applyEditsPreservingTextShape(
        std.testing.allocator,
        utf8_bom ++ "one\r\ntwo\r\n",
        &.{.{ .old_text = "one\ntwo", .new_text = "1\n2" }},
        max_edit_output_bytes,
        null,
    );
    defer edited.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(utf8_bom ++ "1\r\n2\r\n", edited.restored);
    try std.testing.expectEqual(@as(usize, 1), edited.first_changed_line);
}

test "edit normalization frees initialized edits on allocation failure" {
    const edits = [_]Replacement{
        .{ .old_text = "one\ntwo", .new_text = "ONE\nTWO" },
        .{ .old_text = "three", .new_text = "THREE" },
    };

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = std.math.maxInt(usize),
        });
        var edited = applyEditsPreservingTextShape(
            failing.allocator(),
            "one\r\ntwo\r\nthree\r\nfour",
            &edits,
            max_edit_output_bytes,
            null,
        ) catch |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        edited.deinit(failing.allocator());
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "edit tool reports no-op replacement without writing" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "same");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"same","newText":"same"}]}
        ,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "No changes made to file.txt. The replacement produced identical content. " ++
            "This might indicate an issue with special characters or the text not existing as expected.",
        result.result.content[0].text.text,
    );
    try std.testing.expect(result.result.details.?.object.get("isError").?.bool);
    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("same", written);
}

test "edit tool reports duplicate oldText with occurrence count" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "1: line 1\n2: line 2\n10: line 10\n11: line 11\n");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var duplicate = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"line 1","newText":"changed"},{"oldText":"line 2","newText":"ok"}]}
        ,
    );
    defer duplicate.deinit();

    try std.testing.expectEqualStrings(
        "Found 3 occurrences of edits[0] in file.txt at lines 1, 3, 4. " ++
            "Each oldText must be unique. Please provide more context to make it unique.",
        duplicate.result.content[0].text.text,
    );
}

test "edit tool bounds duplicate line hints" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "hit\nhit\nhit\nhit\nhit\nhit\nhit\nhit\nhit\nhit\n");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"hit","newText":"miss"}]}
        ,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "Found 10 occurrences of the text in file.txt at lines 1, 2, 3, 4, 5, 6, 7, 8 and more. " ++
            "The text must be unique. Please provide more context to make it unique.",
        result.result.content[0].text.text,
    );
}

test "edit tool returns actionable operational errors" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "abc abc");

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd(), .max_output_bytes = 5 });
    defer edit_tool.deinit();

    var empty = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"","newText":"x"}]}
        ,
    );
    defer empty.deinit();
    try std.testing.expectEqualStrings(
        "oldText must not be empty in file.txt.",
        empty.result.content[0].text.text,
    );

    var duplicate = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"abc","newText":"x"}]}
        ,
    );
    defer duplicate.deinit();
    try std.testing.expectEqualStrings(
        "Found 2 occurrences of the text in file.txt at lines 1, 1. " ++
            "The text must be unique. Please provide more context to make it unique.",
        duplicate.result.content[0].text.text,
    );

    var overlap = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"abc ","newText":"x"},{"oldText":"bc a","newText":"y"}]}
        ,
    );
    defer overlap.deinit();
    try std.testing.expectEqualStrings(
        "edits[0] and edits[1] overlap in file.txt. " ++
            "Merge them into one edit or target disjoint regions.",
        overlap.result.content[0].text.text,
    );

    var too_large = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.txt","edits":[{"oldText":"abc abc","newText":"abcdef"}]}
        ,
    );
    defer too_large.deinit();
    try std.testing.expectEqualStrings(
        "Edit failed: output would exceed the 5 byte limit.",
        too_large.result.content[0].text.text,
    );

    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("abc abc", written);
}

test "edit tool reports path and read failures operationally" {
    var fixture = try test_support.Fixture.init("repo/app");
    defer fixture.deinit();
    try fixture.dir("repo/other");
    try fixture.write("repo/other/file.txt", "outside");
    try fixture.write("repo/app/blocker", "x");

    var edit_tool = try EditTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .allow_paths_outside_cwd = false,
    });
    defer edit_tool.deinit();

    var missing = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"missing.txt","edits":[{"oldText":"x","newText":"y"}]}
        ,
    );
    defer missing.deinit();
    try std.testing.expect(missing.result.details.?.object.get("isError").?.bool);
    try std.testing.expectEqualStrings("path_error", missing.result.details.?.object.get("reason").?.string);
    try std.testing.expectEqualStrings("missing.txt", missing.result.details.?.object.get("path").?.string);
    try std.testing.expectEqualStrings("FileNotFound", missing.result.details.?.object.get("errorName").?.string);

    var outside = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"../other/file.txt","edits":[{"oldText":"outside","newText":"inside"}]}
        ,
    );
    defer outside.deinit();
    try std.testing.expect(outside.result.details.?.object.get("isError").?.bool);
    try std.testing.expectEqualStrings("invalid_path", outside.result.details.?.object.get("reason").?.string);
    try std.testing.expectEqualStrings("../other/file.txt", outside.result.details.?.object.get("path").?.string);
    try std.testing.expectEqualStrings("PathOutsideCwd", outside.result.details.?.object.get("errorName").?.string);

    var edit_read_tool = try EditTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .allow_paths_outside_cwd = true,
    });
    defer edit_read_tool.deinit();
    var read_failed = try test_support.execute(
        edit_read_tool.tool(),
        \\{"path":"missing-open.txt","edits":[{"oldText":"x","newText":"y"}]}
        ,
    );
    defer read_failed.deinit();
    try std.testing.expect(read_failed.result.details.?.object.get("isError").?.bool);
    try std.testing.expectEqualStrings("read_failed", read_failed.result.details.?.object.get("reason").?.string);
    try std.testing.expectEqualStrings("missing-open.txt", read_failed.result.details.?.object.get("path").?.string);
    try std.testing.expectEqualStrings("FileNotFound", read_failed.result.details.?.object.get("errorName").?.string);
    var unreadable = try test_support.execute(
        edit_read_tool.tool(),
        \\{"path":"blocker/file.txt","edits":[{"oldText":"x","newText":"y"}]}
        ,
    );
    defer unreadable.deinit();
    try std.testing.expect(unreadable.result.details.?.object.get("isError").?.bool);
    try std.testing.expectEqualStrings("path_error", unreadable.result.details.?.object.get("reason").?.string);
    try std.testing.expectEqualStrings("blocker/file.txt", unreadable.result.details.?.object.get("path").?.string);
    try std.testing.expect(unreadable.result.details.?.object.get("errorName").?.string.len > 0);
}

test "edit tool rejects non utf8 target without mutation" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    const original = "ok\xffbad";
    try fixture.write("repo/file.bin", original);

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var result = try test_support.execute(
        edit_tool.tool(),
        \\{"path":"file.bin","edits":[{"oldText":"ok","newText":"changed"}]}
        ,
    );
    defer result.deinit();

    const details = result.result.details.?.object;
    try std.testing.expect(details.get("isError").?.bool);
    try std.testing.expectEqualStrings("non_utf8_file", details.get("reason").?.string);
    try std.testing.expectEqualStrings("file.bin", details.get("path").?.string);
    const written = try fixture.read("repo/file.bin");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, original, written);
}

test "edit tool does not stream full edited file on success" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    const original = "old\n" ++ ("\xe4\xb8\xad" ** 6000);
    const replacement = "new\n" ++ ("\xe4\xb8\xad" ** 6000);
    try fixture.write("repo/file.txt", original);

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var edit_object: std.json.ObjectMap = .empty;
    defer edit_object.deinit(std.testing.allocator);
    try edit_object.put(std.testing.allocator, "oldText", .{ .string = original });
    try edit_object.put(std.testing.allocator, "newText", .{ .string = replacement });
    var edits: std.json.Array = .init(std.testing.allocator);
    defer edits.deinit();
    try edits.append(.{ .object = edit_object });
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "edits", .{ .array = edits });

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var capture: test_support.UpdateCapture = .{ .writer = .init(std.testing.allocator) };
    defer capture.deinit();
    var result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &edit_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        .{ .context = &capture, .call_fn = test_support.captureUpdate },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqualStrings("", capture.writer.written());
    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(replacement, written);
}

fn largeEditBlock(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var line: usize = 0;
    while (line < 300) : (line += 1) {
        try writer.writer.print("{s}-{d}-abcdefghijklmnopqrstuvwx\n", .{ prefix, line });
    }
    return writer.toOwnedSlice();
}

test "edit tool returns operational error when success result is too large" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    const original = try largeEditBlock(std.testing.allocator, "old");
    defer std.testing.allocator.free(original);
    const replacement = try largeEditBlock(std.testing.allocator, "new");
    defer std.testing.allocator.free(replacement);
    try fixture.write("repo/file.txt", original);

    var edit_tool = try EditTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer edit_tool.deinit();

    var edit_object: std.json.ObjectMap = .empty;
    defer edit_object.deinit(std.testing.allocator);
    try edit_object.put(std.testing.allocator, "oldText", .{ .string = original });
    try edit_object.put(std.testing.allocator, "newText", .{ .string = replacement });
    var edits: std.json.Array = .init(std.testing.allocator);
    defer edits.deinit();
    try edits.append(.{ .object = edit_object });
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(std.testing.allocator);
    try object.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    try object.put(std.testing.allocator, "edits", .{ .array = edits });

    var task_runtime = try agent.ToolRuntime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var result = try execute(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        &edit_tool,
        cancel_source.token(),
        "call-1",
        .{ .object = object },
        null,
    );
    defer result.deinit();

    // Large edits now succeed; the confirmation diff is truncated by edit_diff.render
    // instead of refusing the edit. The file is written and the diff carries a marker.
    try std.testing.expectEqualStrings(
        "Successfully replaced 1 block(s) in file.txt.",
        result.result.content[0].text.text,
    );
    const details = result.result.details.?.object;
    try std.testing.expectEqualStrings("file.txt", details.get("path").?.string);
    try std.testing.expect(std.mem.indexOf(u8, details.get("diff").?.string, "truncated") != null);
    const written = try fixture.read("repo/file.txt");
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(replacement, written);
}

test "edit tool rejects bad replacements before mutation" {
    var applied_one: [1]edit_diff.AppliedEdit = undefined;
    try std.testing.expectError(error.NoChanges, applyEdits(
        std.testing.allocator,
        "same",
        &.{.{ .old_text = "same", .new_text = "same" }},
        max_edit_output_bytes,
        &applied_one,
        null,
    ));
    try std.testing.expectError(error.EditTextNotUnique, applyEdits(
        std.testing.allocator,
        "x x",
        &.{.{ .old_text = "x", .new_text = "y" }},
        max_edit_output_bytes,
        &applied_one,
        null,
    ));
    try std.testing.expectError(error.EditTooLarge, applyEdits(
        std.testing.allocator,
        "x",
        &.{.{ .old_text = "x", .new_text = "hello" }},
        3,
        &applied_one,
        null,
    ));
    var applied_two: [2]edit_diff.AppliedEdit = undefined;
    try std.testing.expectError(error.OverlappingEdits, applyEdits(
        std.testing.allocator,
        "abcdef",
        &.{
            .{ .old_text = "abc", .new_text = "x" },
            .{ .old_text = "bcd", .new_text = "y" },
        },
        max_edit_output_bytes,
        &applied_two,
        null,
    ));
}
