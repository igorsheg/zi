const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_api = @import("../agent/root.zig");
const BoundedJson = @import("../BoundedJson.zig");

const ai_message = ai.message;
const ai_model = ai.model;
const tool_api = agent_api.tool;

// Shared cwd authority ---------------------------------------------------

/// Owns the admitted cwd directory handle and the session io for one agent
/// session. Tools borrow this value and use its io for every filesystem and
/// process operation, so the cwd and its io authority have exactly one owner.
/// The erased tool ABI still passes the same session io to every execute call;
/// tools ignore that parameter and rely on `Workspace.io` instead.
const Workspace = struct {
    io: std.Io,
    cwd: std.Io.Dir,

    /// Takes ownership of `cwd`. Callers transfer their handle into the session
    /// and must not close it themselves after a successful construction.
    fn init(io: std.Io, cwd: std.Io.Dir) Workspace {
        return .{ .io = io, .cwd = cwd };
    }

    fn deinit(self: *Workspace) void {
        self.cwd.close(self.io);
        self.* = undefined;
    }
};

// Shared tool constants and helpers --------------------------------------

const max_path_bytes = 4096;
const max_file_bytes = 8 * 1024 * 1024;
const max_read_arguments_bytes = 64 * 1024;
const max_write_arguments_bytes = 1024 * 1024;
const max_edit_arguments_bytes = 1024 * 1024;
const max_bash_arguments_bytes = 128 * 1024;
const max_output_bytes = 50 * 1024;
const max_output_lines = 2000;
const max_edits = 64;
const max_command_bytes = 64 * 1024;
const max_capture_bytes = 8 * 1024 * 1024;
const output_overhead_bytes = 512;
const output_overhead_lines = 3;
const invalid_read_message = "Read arguments require a path and optional positive integer offset and limit.";
const invalid_write_message = "Write arguments require a non-empty path and a content string.";
const invalid_edit_message = "Edit arguments require a non-empty path and one to 64 oldText/newText replacements.";
const invalid_bash_message = "Bash arguments require one non-empty UTF-8 command without NUL bytes.";
const utf8_bom = "\xef\xbb\xbf";

/// Bounded typed argument parsing shared by every cwd tool. The project's
/// bounded JSON preflight rejects oversized documents, values, nesting, and
/// collection counts before the strict typed parse runs.
const Decoder = struct {
    const Limits = struct {
        document_bytes: usize,
        value_bytes: usize,
        depth: usize = 4,
        collection_items: usize = 256,
    };

    fn parse(
        comptime T: type,
        allocator: std.mem.Allocator,
        arguments_json: []const u8,
        limits: Limits,
    ) error{ OutOfMemory, InvalidArguments }!std.json.Parsed(T) {
        BoundedJson.validate(allocator, arguments_json, .{
            .document_bytes = limits.document_bytes,
            .value_bytes = limits.value_bytes,
            .depth = limits.depth,
            .collection_items = limits.collection_items,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidArguments,
        };
        return std.json.parseFromSlice(T, allocator, arguments_json, .{
            .ignore_unknown_fields = false,
        }) catch |failure| {
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidArguments,
            };
        };
    }
};

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

// Read -------------------------------------------------------------------

const Read = struct {
    workspace: *Workspace,

    const Arguments = struct {
        path: []const u8,
        offset: ?usize = null,
        limit: ?usize = null,
    };

    fn asTool(self: *Read) tool_api.Tool {
        return tool_api.Tool.from(self, read_definition);
    }

    pub fn execute(
        self: *Read,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: tool_api.Tool.RunContext,
        arguments_json: []const u8,
    ) tool_api.ToolFatalError!tool_api.ToolExecution {
        try checkCancellation(run_context);
        _ = io;
        if (arguments_json.len > max_read_arguments_bytes) {
            return modelFailure(allocator, "Read arguments exceed the 64KB input limit.", .{});
        }

        var parsed = Decoder.parse(Arguments, allocator, arguments_json, .{
            .document_bytes = max_read_arguments_bytes,
            .value_bytes = 4096,
            .collection_items = 8,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => modelFailure(allocator, invalid_read_message, .{}),
        };
        defer parsed.deinit();
        const arguments = parsed.value;
        if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
            arguments.offset == 0 or arguments.limit == 0)
        {
            return modelFailure(allocator, invalid_read_message, .{});
        }

        const bytes = self.workspace.cwd.readFileAlloc(
            self.workspace.io,
            arguments.path,
            allocator,
            .limited(max_file_bytes + 1),
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return modelFailure(
                allocator,
                "Cannot read {s}: file exceeds the 8.0MB input limit.",
                .{arguments.path},
            ),
            else => return modelFailure(
                allocator,
                "Cannot read {s}: {s}.",
                .{ arguments.path, @errorName(failure) },
            ),
        };
        if (bytes.len > max_file_bytes) {
            return modelFailure(
                allocator,
                "Cannot read {s}: file exceeds the 8.0MB input limit.",
                .{arguments.path},
            );
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return modelFailure(allocator, "Cannot read {s}: file is not valid UTF-8.", .{arguments.path});
        }

        const offset = arguments.offset orelse 1;
        const total_lines = Read.lineCount(bytes);
        if (offset > total_lines) {
            return modelFailure(
                allocator,
                "Offset {d} is beyond end of file ({d} lines total)",
                .{ offset, total_lines },
            );
        }
        const output = try Read.selectText(allocator, bytes, offset, arguments.limit);
        try checkCancellation(run_context);
        return .{ .success = .{ .content = try contentFrom(allocator, output) } };
    }

    const Continuation = enum {
        none,
        line_limit,
        byte_limit,
        user_limit,
    };

    fn selectText(
        allocator: std.mem.Allocator,
        source: []const u8,
        offset: usize,
        requested_limit: ?usize,
    ) tool_api.ToolFatalError![]const u8 {
        const total_lines = Read.lineCount(source);
        const available_lines = total_lines - offset + 1;
        const selected_lines = if (requested_limit) |limit| @min(limit, available_lines) else available_lines;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var line_ends: [max_output_lines]usize = undefined;

        var cursor: usize = 0;
        var line_number: usize = 1;
        var written_lines: usize = 0;
        var continuation: Continuation = .none;

        while (line_number <= total_lines) : (line_number += 1) {
            const newline = std.mem.findScalarPos(u8, source, cursor, '\n');
            const end = newline orelse source.len;
            const line = source[cursor..end];
            cursor = if (newline) |index| index + 1 else source.len;

            if (line_number < offset) continue;
            if (written_lines >= selected_lines) break;
            if (written_lines >= max_output_lines) {
                continuation = .line_limit;
                break;
            }

            const separator_bytes: usize = if (written_lines == 0) 0 else 1;
            if (separator_bytes + line.len > max_output_bytes -| output.items.len) {
                continuation = .byte_limit;
                break;
            }
            if (separator_bytes == 1) output.append(allocator, '\n') catch return error.OutOfMemory;
            output.appendSlice(allocator, line) catch return error.OutOfMemory;
            line_ends[written_lines] = output.items.len;
            written_lines += 1;
        }

        if (written_lines == 0 and continuation == .byte_limit) {
            return Read.oversizedLineDiagnostic(allocator, source, offset);
        }
        if (continuation == .none and written_lines < selected_lines) continuation = .line_limit;
        if (continuation == .none and requested_limit != null and written_lines < available_lines) {
            continuation = .user_limit;
        }

        if (continuation == .none) {
            if (offset + written_lines - 1 == total_lines and std.mem.endsWith(u8, source, "\n") and
                output.items.len < max_output_bytes)
            {
                output.append(allocator, '\n') catch return error.OutOfMemory;
            }
        } else {
            while (true) {
                const notice = try Read.continuationNotice(
                    allocator,
                    continuation,
                    offset,
                    written_lines,
                    total_lines,
                    available_lines,
                );
                defer allocator.free(notice);
                if (output.items.len + 2 + notice.len <= max_output_bytes) {
                    output.appendSlice(allocator, "\n\n") catch return error.OutOfMemory;
                    output.appendSlice(allocator, notice) catch return error.OutOfMemory;
                    break;
                }
                if (written_lines == 1) {
                    const compact_notice = std.fmt.allocPrint(
                        allocator,
                        "[Use offset={d} to continue.]",
                        .{offset + written_lines},
                    ) catch return error.OutOfMemory;
                    defer allocator.free(compact_notice);
                    if (output.items.len + 2 + compact_notice.len <= max_output_bytes) {
                        output.appendSlice(allocator, "\n\n") catch return error.OutOfMemory;
                        output.appendSlice(allocator, compact_notice) catch return error.OutOfMemory;
                        break;
                    }
                    return Read.oversizedLineDiagnostic(allocator, source, offset);
                }
                written_lines -= 1;
                output.items.len = line_ends[written_lines - 1];
                continuation = .byte_limit;
            }
        }

        return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    fn continuationNotice(
        allocator: std.mem.Allocator,
        continuation: Continuation,
        offset: usize,
        written_lines: usize,
        total_lines: usize,
        available_lines: usize,
    ) tool_api.ToolFatalError![]u8 {
        return switch (continuation) {
            .none => unreachable,
            .line_limit => std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
                .{ offset, offset + written_lines - 1, total_lines, offset + written_lines },
            ),
            .byte_limit => std.fmt.allocPrint(
                allocator,
                "[Showing lines {d}-{d} of {d} (50.0KB limit). Use offset={d} to continue.]",
                .{ offset, offset + written_lines - 1, total_lines, offset + written_lines },
            ),
            .user_limit => std.fmt.allocPrint(
                allocator,
                "[{d} more lines in file. Use offset={d} to continue.]",
                .{ available_lines - written_lines, offset + written_lines },
            ),
        } catch return error.OutOfMemory;
    }

    fn oversizedLineDiagnostic(
        allocator: std.mem.Allocator,
        source: []const u8,
        offset: usize,
    ) tool_api.ToolFatalError![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "[Line {d} is {d} bytes and cannot be returned with a bounded 50.0KB continuation notice.]",
            .{ offset, Read.lineLength(source, offset) },
        ) catch return error.OutOfMemory;
    }

    fn lineCount(source: []const u8) usize {
        if (source.len == 0) return 1;
        const newlines = std.mem.count(u8, source, "\n");
        return newlines + @intFromBool(!std.mem.endsWith(u8, source, "\n"));
    }

    fn lineLength(source: []const u8, target: usize) usize {
        var cursor: usize = 0;
        var line_number: usize = 1;
        while (line_number < target) : (line_number += 1) {
            const newline = std.mem.findScalarPos(u8, source, cursor, '\n') orelse return 0;
            cursor = newline + 1;
        }
        const end = std.mem.findScalarPos(u8, source, cursor, '\n') orelse source.len;
        return end - cursor;
    }
};

// Write ------------------------------------------------------------------

const Write = struct {
    workspace: *Workspace,

    const Arguments = struct {
        path: []const u8,
        content: []const u8,
    };

    fn asTool(self: *Write) tool_api.Tool {
        return tool_api.Tool.from(self, write_definition);
    }

    pub fn execute(
        self: *Write,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: tool_api.Tool.RunContext,
        arguments_json: []const u8,
    ) tool_api.ToolFatalError!tool_api.ToolExecution {
        try checkCancellation(run_context);
        _ = io;
        if (arguments_json.len > max_write_arguments_bytes) {
            return modelFailure(allocator, "Write arguments exceed the 1.0MB input limit.", .{});
        }

        var parsed = Decoder.parse(Arguments, allocator, arguments_json, .{
            .document_bytes = max_write_arguments_bytes,
            .value_bytes = max_write_arguments_bytes,
            .collection_items = 8,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => modelFailure(allocator, invalid_write_message, .{}),
        };
        defer parsed.deinit();
        const arguments = parsed.value;
        if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
            !std.unicode.utf8ValidateSlice(arguments.path) or
            !std.unicode.utf8ValidateSlice(arguments.content))
        {
            return modelFailure(allocator, invalid_write_message, .{});
        }
        if (std.fs.path.dirname(arguments.path)) |parent| {
            self.workspace.cwd.createDirPath(self.workspace.io, parent) catch |failure| switch (failure) {
                error.Canceled => return error.Cancelled,
                else => return modelFailure(
                    allocator,
                    "Cannot create parent directory for {s}: {s}.",
                    .{ arguments.path, @errorName(failure) },
                ),
            };
        }
        try checkCancellation(run_context);

        const output = std.fmt.allocPrint(
            allocator,
            "Successfully wrote {d} bytes to {s}",
            .{ arguments.content.len, arguments.path },
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
        self.workspace.cwd.writeFile(self.workspace.io, .{
            .sub_path = arguments.path,
            .data = arguments.content,
        }) catch |failure| {
            allocator.free(content);
            allocator.free(output);
            return switch (failure) {
                error.Canceled => error.Cancelled,
                else => modelFailure(
                    allocator,
                    "Cannot write {s}: {s}.",
                    .{ arguments.path, @errorName(failure) },
                ),
            };
        };
        return .{ .success = .{ .content = content } };
    }
};

// Edit -------------------------------------------------------------------

const Edit = struct {
    workspace: *Workspace,

    const EditPair = struct {
        oldText: []const u8,
        newText: []const u8,
    };

    const Arguments = struct {
        path: []const u8,
        edits: []const EditPair,
    };

    const Replacement = struct {
        edit_index: usize,
        start: usize,
        end: usize,
        new_text: []const u8,
    };

    const LineEnding = enum { lf, crlf };

    fn asTool(self: *Edit) tool_api.Tool {
        return tool_api.Tool.from(self, edit_definition);
    }

    pub fn execute(
        self: *Edit,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: tool_api.Tool.RunContext,
        arguments_json: []const u8,
    ) tool_api.ToolFatalError!tool_api.ToolExecution {
        try checkCancellation(run_context);
        _ = io;
        if (arguments_json.len > max_edit_arguments_bytes) {
            return modelFailure(allocator, "Edit arguments exceed the 1.0MB input limit.", .{});
        }

        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        var parsed = Decoder.parse(Arguments, scratch, arguments_json, .{
            .document_bytes = max_edit_arguments_bytes,
            .value_bytes = max_edit_arguments_bytes,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => modelFailure(allocator, invalid_edit_message, .{}),
        };
        defer parsed.deinit();
        const arguments = parsed.value;
        if (arguments.path.len == 0 or arguments.path.len > max_path_bytes or
            !std.unicode.utf8ValidateSlice(arguments.path) or
            arguments.edits.len == 0 or arguments.edits.len > max_edits)
        {
            return modelFailure(allocator, invalid_edit_message, .{});
        }

        const source = self.workspace.cwd.readFileAlloc(
            self.workspace.io,
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
        const line_ending = Edit.detectLineEnding(source_text);
        const base = Edit.normalizeToLf(scratch, source_text) catch return error.OutOfMemory;
        var replacements: [max_edits]Replacement = undefined;

        for (arguments.edits, 0..) |edit, edit_index| {
            if (!std.unicode.utf8ValidateSlice(edit.oldText) or !std.unicode.utf8ValidateSlice(edit.newText)) {
                return modelFailure(allocator, invalid_edit_message, .{});
            }
            const old_text = Edit.normalizeToLf(scratch, edit.oldText) catch return error.OutOfMemory;
            const new_text = Edit.normalizeToLf(scratch, edit.newText) catch return error.OutOfMemory;
            if (old_text.len == 0) {
                return Edit.emptyOldTextFailure(allocator, arguments.path, edit_index, arguments.edits.len);
            }
            const match_index = std.mem.find(u8, base, old_text) orelse {
                return Edit.notFoundFailure(allocator, arguments.path, edit_index, arguments.edits.len);
            };
            const occurrences = Edit.countOccurrences(base, old_text);
            if (occurrences > 1) {
                return Edit.duplicateFailure(
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

        Edit.sortReplacements(replacements[0..arguments.edits.len]);
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
                return Edit.resultTooLargeFailure(allocator, arguments.path);
            }
            cursor = replacement.end;
        }
        normalized_result.appendSlice(scratch, base[cursor..]) catch return error.OutOfMemory;
        if (normalized_result.items.len > max_file_bytes) return Edit.resultTooLargeFailure(allocator, arguments.path);
        if (std.mem.eql(u8, base, normalized_result.items)) {
            return Edit.noChangeFailure(allocator, arguments.path, arguments.edits.len);
        }

        const final_content = Edit.restoreText(
            scratch,
            normalized_result.items,
            line_ending,
            has_bom,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResultTooLarge => return Edit.resultTooLargeFailure(allocator, arguments.path),
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
        self.workspace.cwd.writeFile(self.workspace.io, .{
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

    const RestoreError = error{ OutOfMemory, ResultTooLarge };

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
};

// Bash -------------------------------------------------------------------

const Bash = struct {
    workspace: *Workspace,
    timeout: std.Io.Timeout = .none,

    const Arguments = struct {
        command: []const u8,
    };

    fn asTool(self: *Bash) tool_api.Tool {
        return tool_api.Tool.from(self, bash_definition);
    }

    pub fn execute(
        self: *Bash,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: tool_api.Tool.RunContext,
        arguments_json: []const u8,
    ) tool_api.ToolFatalError!tool_api.ToolExecution {
        try checkCancellation(run_context);
        _ = io;
        if (arguments_json.len > max_bash_arguments_bytes) {
            return modelFailure(allocator, "Bash arguments exceed the 128KB input limit.", .{});
        }

        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        var parsed = Decoder.parse(Arguments, scratch, arguments_json, .{
            .document_bytes = max_bash_arguments_bytes,
            .value_bytes = max_command_bytes,
            .collection_items = 8,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => modelFailure(allocator, invalid_bash_message, .{}),
        };
        defer parsed.deinit();
        const command = parsed.value.command;
        if (command.len == 0 or command.len > max_command_bytes or
            !std.unicode.utf8ValidateSlice(command) or std.mem.findScalar(u8, command, 0) != null)
        {
            return modelFailure(allocator, invalid_bash_message, .{});
        }

        const result = std.process.run(scratch, self.workspace.io, .{
            .argv = &.{ "bash", "-c", command },
            .cwd = .{ .dir = self.workspace.cwd },
            .stdout_limit = .limited(max_capture_bytes),
            .stderr_limit = .limited(max_capture_bytes),
            .timeout = Bash.executionTimeout(self.workspace.io, self.timeout, run_context.deadline),
        }) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Cancelled,
            error.Timeout => return error.TimedOut,
            error.StreamTooLong => return modelFailure(
                allocator,
                "Command output exceeded the 8.0MB per-stream capture limit.",
                .{},
            ),
            else => return modelFailure(allocator, "Cannot execute command: {s}.", .{@errorName(failure)}),
        };

        const status = Bash.terminationStatus(scratch, result.term) catch return error.OutOfMemory;
        if (!std.unicode.utf8ValidateSlice(result.stdout) or !std.unicode.utf8ValidateSlice(result.stderr)) {
            return modelFailure(allocator, "Command output is not valid UTF-8.\n\n{s}", .{status});
        }
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(scratch);
        combined.appendSlice(scratch, result.stdout) catch return error.OutOfMemory;
        if (result.stderr.len > 0) {
            if (combined.items.len > 0 and !std.mem.endsWith(u8, combined.items, "\n")) {
                combined.append(scratch, '\n') catch return error.OutOfMemory;
            }
            combined.appendSlice(scratch, "[stderr]\n") catch return error.OutOfMemory;
            combined.appendSlice(scratch, result.stderr) catch return error.OutOfMemory;
        }

        const text = Bash.boundedOutput(allocator, combined.items, status) catch return error.OutOfMemory;
        return switch (result.term) {
            .exited => |code| if (code == 0) Bash.successExecution(allocator, text) else .{ .failure = text },
            .signal, .stopped, .unknown => .{ .failure = text },
        };
    }

    fn executionTimeout(
        io: std.Io,
        configured: std.Io.Timeout,
        run_deadline: ?std.Io.Clock.Timestamp,
    ) std.Io.Timeout {
        if (configured == .none) return if (run_deadline) |deadline|
            .{ .deadline = deadline }
        else
            .none;
        const configured_deadline = configured.toDeadline(io);
        const deadline = run_deadline orelse return configured_deadline;
        const configured_remaining = configured_deadline.toDurationFromNow(io) orelse {
            return .{ .deadline = deadline };
        };
        const run_remaining = deadline.durationFromNow(io);
        return if (run_remaining.raw.nanoseconds <= configured_remaining.raw.nanoseconds)
            .{ .deadline = deadline }
        else
            configured_deadline;
    }

    fn terminationStatus(
        allocator: std.mem.Allocator,
        term: std.process.Child.Term,
    ) error{OutOfMemory}![]const u8 {
        return switch (term) {
            .exited => |code| std.fmt.allocPrint(allocator, "Command exited with code {d}", .{code}),
            .signal => |signal| std.fmt.allocPrint(
                allocator,
                "Command terminated by signal {d}",
                .{@intFromEnum(signal)},
            ),
            .stopped => |signal| std.fmt.allocPrint(
                allocator,
                "Command stopped by signal {d}",
                .{@intFromEnum(signal)},
            ),
            .unknown => |status| std.fmt.allocPrint(allocator, "Command terminated with status {d}", .{status}),
        } catch return error.OutOfMemory;
    }

    fn boundedOutput(
        allocator: std.mem.Allocator,
        output: []const u8,
        status: []const u8,
    ) error{OutOfMemory}![]const u8 {
        const max_body_bytes = max_output_bytes - output_overhead_bytes;
        const max_body_lines = max_output_lines - output_overhead_lines;
        const line_start = Bash.tailLineStart(output, max_body_lines);
        const byte_start = if (output.len > max_body_bytes) output.len - max_body_bytes else 0;
        var start = @max(line_start, byte_start);
        while (start < output.len and output[start] & 0xc0 == 0x80) start += 1;
        const truncated = start > 0;
        const body = output[start..];

        var text: std.Io.Writer.Allocating = .init(allocator);
        errdefer text.deinit();
        if (body.len == 0) {
            text.writer.writeAll("(no output)") catch return error.OutOfMemory;
        } else {
            text.writer.writeAll(body) catch return error.OutOfMemory;
        }
        if (body.len > 0 and std.mem.endsWith(u8, body, "\n")) {
            text.writer.writeByte('\n') catch return error.OutOfMemory;
        } else {
            text.writer.writeAll("\n\n") catch return error.OutOfMemory;
        }
        if (truncated) {
            text.writer.print(
                "[Output truncated; showing the last {d} bytes and at most {d} lines.]\n",
                .{ body.len, max_output_lines },
            ) catch return error.OutOfMemory;
        }
        text.writer.writeAll(status) catch return error.OutOfMemory;
        return text.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn tailLineStart(output: []const u8, max_lines: usize) usize {
        if (output.len == 0) return 0;
        var index = output.len;
        var lines: usize = 1;
        while (index > 0) {
            index -= 1;
            if (output[index] != '\n' or index == output.len - 1) continue;
            lines += 1;
            if (lines > max_lines) return index + 1;
        }
        return 0;
    }

    fn successExecution(
        allocator: std.mem.Allocator,
        text: []const u8,
    ) tool_api.ToolFatalError!tool_api.ToolExecution {
        errdefer allocator.free(text);
        return .{ .success = .{ .content = try contentFrom(allocator, text) } };
    }
};

// Definitions -------------------------------------------------------------

const read_definition: ai_message.ToolDefinition = .{
    .name = "read",
    .description = "Read a UTF-8 text file. Paths may be relative to the session working directory or absolute. " ++
        "Output is limited to 2000 lines or 50KB, whichever is reached first. " ++
        "Use offset and limit to continue through large files.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"}," ++
        "\"offset\":{\"type\":\"integer\",\"minimum\":1," ++
        "\"description\":\"Line number to start reading from (1-indexed)\"}," ++
        "\"limit\":{\"type\":\"integer\",\"minimum\":1," ++
        "\"description\":\"Maximum number of lines to read\"}}," ++
        "\"required\":[\"path\"],\"additionalProperties\":false}",
};

const write_definition: ai_message.ToolDefinition = .{
    .name = "write",
    .description = "Write content to a file. Creates the file if it doesn't exist, overwrites it if it does, " ++
        "and creates parent directories automatically.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to write (relative or absolute)\"}," ++
        "\"content\":{\"type\":\"string\",\"description\":\"Complete content to write to the file\"}}," ++
        "\"required\":[\"path\",\"content\"],\"additionalProperties\":false}",
};

const edit_definition: ai_message.ToolDefinition = .{
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

const bash_definition: ai_message.ToolDefinition = .{
    .name = "bash",
    .description = "Execute one Bash command in the session working directory. " ++
        "Returns bounded stdout followed by stderr and the termination status.",
    .parameters_json_schema = "{\"type\":\"object\",\"properties\":{" ++
        "\"command\":{\"type\":\"string\",\"description\":\"Bash command to execute\"}}," ++
        "\"required\":[\"command\"],\"additionalProperties\":false}",
};

// Toolset -----------------------------------------------------------------

/// Owns the workspace and the four cwd-bound tools for one agent session.
/// Construction transfers ownership of `cwd` into the workspace.
pub const Toolset = struct {
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    read: Read,
    write: Write,
    edit: Edit,
    bash: Bash,

    /// Takes ownership of `cwd` only on success: the only fallible steps are
    /// the two allocations, and `cwd` is not touched until after they succeed.
    /// On failure the caller keeps ownership of `cwd` and must close it.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) error{OutOfMemory}!*Toolset {
        const toolset = try allocator.create(Toolset);
        errdefer allocator.destroy(toolset);
        const workspace = try allocator.create(Workspace);
        errdefer allocator.destroy(workspace);
        workspace.* = Workspace.init(io, cwd);
        toolset.* = .{
            .allocator = allocator,
            .workspace = workspace,
            .read = .{ .workspace = workspace },
            .write = .{ .workspace = workspace },
            .edit = .{ .workspace = workspace },
            .bash = .{ .workspace = workspace },
        };
        return toolset;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *Toolset) void {
        const allocator = self.allocator;
        self.workspace.deinit();
        allocator.destroy(self.workspace);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn tools(self: *Toolset) [4]tool_api.Tool {
        return .{
            self.read.asTool(),
            self.write.asTool(),
            self.edit.asTool(),
            self.bash.asTool(),
        };
    }
};

fn contentFrom(allocator: std.mem.Allocator, text: []const u8) tool_api.ToolFatalError![]ai_message.Content {
    const content = try allocator.alloc(ai_message.Content, 1);
    content[0] = .{ .text = text };
    return content;
}

// Tests ------------------------------------------------------------------

/// Test-only wrapper: opens a dedicated handle over `dir` so the toolset's
/// workspace can close it without closing the caller's TmpDir handle.
const TestToolset = struct {
    value: *Toolset,

    fn init(io: std.Io, dir: std.Io.Dir) !TestToolset {
        const owned = try dir.openDir(io, ".", .{});
        errdefer owned.close(io);
        return .{ .value = try Toolset.init(std.testing.allocator, io, owned) };
    }

    fn deinit(self: *TestToolset) void {
        self.value.deinit();
        self.* = undefined;
    }
};

test "workspace ownership is closed exactly once on transfer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const owned = try temporary.dir.openDir(std.testing.io, ".", .{});
    var workspace = Workspace.init(std.testing.io, owned);
    workspace.deinit();
    // The caller's own handle remains valid and closable by cleanup.
    try temporary.dir.access(std.testing.io, ".", .{});
}

test "read returns exact text and preserves a terminal newline" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "one\ntwo\n" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"plain.txt\"}",
    );
    try std.testing.expectEqualStrings("one\ntwo\n", execution.success.content[0].text);
}

test "read applies offset and limit with a continuation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "lines.txt", .data = "one\ntwo\nthree\nfour" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"lines.txt\",\"offset\":2,\"limit\":2}",
    );
    try std.testing.expectEqualStrings(
        "two\nthree\n\n[1 more lines in file. Use offset=4 to continue.]",
        execution.success.content[0].text,
    );
}

test "read reports offsets beyond the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "short.txt", .data = "one\ntwo\nthree" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"short.txt\",\"offset\":100}",
    );
    try std.testing.expectEqualStrings(
        "Offset 100 is beyond end of file (3 lines total)",
        execution.failure,
    );
}

test "read rejects invalid semantic arguments as model-visible failures" {
    var test_ws = try TestToolset.init(std.testing.io, .cwd());
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "{}",
        "{\"path\":\"\"}",
        "{\"path\":\"x\",\"offset\":0}",
        "{\"path\":\"x\",\"limit\":0}",
        "{\"path\":\"x\",\"extra\":true}",
    }) |arguments| {
        const execution = try test_ws.value.read.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expect(execution == .failure);
    }
}

test "read enforces complete-line output bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "large.txt", .{});
    defer file.close(std.testing.io);
    var bytes: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &bytes);
    for (0..2001) |index| try writer.interface.print("line-{d}\n", .{index + 1});
    try writer.flush();

    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"large.txt\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(std.mem.find(u8, text, "line-2000") != null);
    try std.testing.expect(std.mem.find(u8, text, "line-2001") == null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        text,
        "[Showing lines 1-2000 of 2001. Use offset=2001 to continue.]",
    ));
}

test "read rejects invalid UTF-8 and observes pre-cancellation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = &.{0xff} });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const invalid = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"binary\"}",
    );
    try std.testing.expectEqualStrings("Cannot read binary: file is not valid UTF-8.", invalid.failure);

    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    try std.testing.expectError(error.Cancelled, test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"binary\"}",
    ));
}

test "read handles empty files and preserves CRLF" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "crlf", .data = "one\r\ntwo" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"empty\"}",
    );
    try std.testing.expectEqualStrings("", empty.success.content[0].text);
    const crlf = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"crlf\"}",
    );
    try std.testing.expectEqualStrings("one\r\ntwo", crlf.success.content[0].text);
}

test "read accepts an absolute path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "absolute.txt", .data = "absolute" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const absolute_path = try std.fs.path.join(
        arena.allocator(),
        &.{ path_buffer[0..directory_length], "absolute.txt" },
    );
    const arguments = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        .{ .path = absolute_path },
        .{},
    );
    var test_ws = try TestToolset.init(std.testing.io, .cwd());
    defer test_ws.deinit();

    const execution = try test_ws.value.read.execute(arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings("absolute", execution.success.content[0].text);
}

test "read classifies filesystem failures and enforces the input boundary" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    var exact = try temporary.dir.createFile(std.testing.io, "exact", .{});
    try exact.setLength(std.testing.io, max_file_bytes);
    exact.close(std.testing.io);
    var oversized = try temporary.dir.createFile(std.testing.io, "oversized", .{});
    try oversized.setLength(std.testing.io, max_file_bytes + 1);
    oversized.close(std.testing.io);
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const missing = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"missing\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, missing.failure, "Cannot read missing:"));
    const directory = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"directory\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, directory.failure, "Cannot read directory:"));
    const exact_limit = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"exact\"}",
    );
    try std.testing.expect(exact_limit == .success);
    const over_limit = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"oversized\"}",
    );
    try std.testing.expectEqualStrings(
        "Cannot read oversized: file exceeds the 8.0MB input limit.",
        over_limit.failure,
    );
}

test "read enforces the byte bound without returning partial lines" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "bytes.txt", .{});
    defer file.close(std.testing.io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &file_buffer);
    const payload = "x" ** 200;
    for (0..500) |index| try writer.interface.print("line-{d}-{s}\n", .{ index + 1, payload });
    try writer.flush();

    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"bytes.txt\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, text, "(50.0KB limit)") != null);
    const notice = std.mem.find(u8, text, "\n\n[Showing lines");
    try std.testing.expect(notice != null);
    try std.testing.expect(text[notice.? - 1] == 'x');
}

test "read uses a compact continuation when a near-limit line leaves little notice space" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const first = try std.testing.allocator.alloc(u8, 51_133);
    defer std.testing.allocator.free(first);
    @memset(first, 'x');
    const second = "y" ** 100;
    var file = try temporary.dir.createFile(std.testing.io, "near-limit", .{});
    errdefer file.close(std.testing.io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &file_buffer);
    try writer.interface.writeAll(first);
    try writer.interface.writeByte('\n');
    try writer.interface.writeAll(second);
    try writer.flush();
    file.close(std.testing.io);
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"near-limit\"}",
    );
    const text = execution.success.content[0].text;
    try std.testing.expect(text.len <= max_output_bytes);
    try std.testing.expect(std.mem.startsWith(u8, text, first));
    try std.testing.expect(std.mem.endsWith(u8, text, "[Use offset=2 to continue.]"));
}

test "read reports an oversized first selected line without partial content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const line = try std.testing.allocator.alloc(u8, max_output_bytes + 1);
    defer std.testing.allocator.free(line);
    @memset(line, 'x');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "long-line", .data = line });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.read.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"long-line\"}",
    );
    try std.testing.expectEqualStrings(
        "[Line 1 is 51201 bytes and cannot be returned with a bounded 50.0KB continuation notice.]",
        execution.success.content[0].text,
    );
}

test "write creates parent directories and reports UTF-8 bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"nested/src/main.zig\",\"content\":\"const greeting = \\\"你好\\\";\\n\"}",
    );
    try std.testing.expectEqualStrings(
        "Successfully wrote 27 bytes to nested/src/main.zig",
        execution.success.content[0].text,
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "nested/src/main.zig",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("const greeting = \"你好\";\n", bytes);
}

test "write overwrites a file and accepts empty content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "old" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"content\":\"replacement\"}",
    );
    {
        const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("replacement", bytes);
    }

    const execution = try test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"target\",\"content\":\"\"}",
    );
    try std.testing.expectEqualStrings("Successfully wrote 0 bytes to target", execution.success.content[0].text);
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "write allows parent traversal from the borrowed session directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "workspace", .default_dir);
    var workspace = try temporary.dir.openDir(std.testing.io, "workspace", .{});
    defer workspace.close(std.testing.io);
    var test_ws = try TestToolset.init(std.testing.io, workspace);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"../outside\",\"content\":\"trusted\"}",
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "outside",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("trusted", bytes);
}

test "write accepts an absolute path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(absolute_path);
    const target = try std.fs.path.join(std.testing.allocator, &.{ absolute_path, "absolute.txt" });
    defer std.testing.allocator.free(target);
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = target,
        .content = "absolute",
    }, .{});
    defer std.testing.allocator.free(arguments);
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try test_ws.value.write.execute(arena.allocator(), std.testing.io, .{}, arguments);
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        target,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("absolute", bytes);
}

test "write rejects malformed arguments and enforces path bounds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    const cases = [_][]const u8{
        "{}",
        "{\"path\":\"file\"}",
        "{\"content\":\"text\"}",
        "{\"path\":\"\",\"content\":\"text\"}",
        "{\"path\":1,\"content\":\"text\"}",
        "{\"path\":\"file\",\"content\":1}",
        "{\"path\":\"file\",\"content\":\"text\",\"extra\":true}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try test_ws.value.write.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_write_message, execution.failure);
    }

    const path = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(path);
    @memset(path, 'x');
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .path = path,
        .content = "text",
    }, .{});
    defer std.testing.allocator.free(arguments);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const execution = try test_ws.value.write.execute(arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings(invalid_write_message, execution.failure);
}

test "write rejects non-UTF-8 JSON strings before filesystem output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    const cases = [_][]const u8{
        "{\"path\":\"\xff\",\"content\":\"text\"}",
        "{\"path\":\"invalid\",\"content\":\"\xff\"}",
        "{\"path\":\"\\uD800\",\"content\":\"text\"}",
        "{\"path\":\"invalid\",\"content\":\"\\uD800\"}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try test_ws.value.write.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_write_message, execution.failure);
    }
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "invalid", .{}));
}

test "write admits exactly 1 MiB of arguments and rejects one byte more" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    const prefix = "{\"path\":\"limit\",\"content\":\"";
    const suffix = "\"}";
    const exact = try std.testing.allocator.alloc(u8, max_write_arguments_bytes);
    defer std.testing.allocator.free(exact);
    @memcpy(exact[0..prefix.len], prefix);
    @memset(exact[prefix.len .. exact.len - suffix.len], 'x');
    @memcpy(exact[exact.len - suffix.len ..], suffix);
    var exact_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arena.deinit();

    _ = try test_ws.value.write.execute(exact_arena.allocator(), std.testing.io, .{}, exact);
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "limit",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(max_write_arguments_bytes - prefix.len - suffix.len, bytes.len);

    const oversized = try std.testing.allocator.alloc(u8, max_write_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    var oversized_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer oversized_arena.deinit();
    const execution = try test_ws.value.write.execute(oversized_arena.allocator(), std.testing.io, .{}, oversized);
    try std.testing.expectEqualStrings("Write arguments exceed the 1.0MB input limit.", execution.failure);
}

test "write returns filesystem failures without partial success" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"directory\",\"content\":\"text\"}",
    );
    try std.testing.expect(std.mem.startsWith(u8, execution.failure, "Cannot write directory:"));
}

test "write honors pre-cancellation without filesystem mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, test_ws.value.write.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"untouched\",\"content\":\"text\"}",
    ));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "untouched", .{}));
}

test "edit applies disjoint replacements and preserves BOM and CRLF" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "target",
        .data = utf8_bom ++ "alpha\r\nbeta\rgamma\r\n",
    });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.edit.execute(
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
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try test_ws.value.edit.execute(
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
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    for (cases) |case| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = original });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try test_ws.value.edit.execute(arena.allocator(), std.testing.io, .{}, case.arguments);
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
    const overlapping_occurrences = try test_ws.value.edit.execute(
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
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
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
        const execution = try test_ws.value.edit.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_edit_message, execution.failure);
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
    const path_failure = try test_ws.value.edit.execute(
        path_arena.allocator(),
        std.testing.io,
        .{},
        long_path_arguments,
    );
    try std.testing.expectEqualStrings(invalid_edit_message, path_failure.failure);

    var missing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer missing_arena.deinit();
    const missing = try test_ws.value.edit.execute(
        missing_arena.allocator(),
        std.testing.io,
        .{},
        "{\"path\":\"missing\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"}]}",
    );
    try std.testing.expect(std.mem.startsWith(u8, missing.failure, "Cannot edit missing:"));

    var directory_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer directory_arena.deinit();
    const directory = try test_ws.value.edit.execute(
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
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "argument-limit", .data = "a" });
    const prefix = "{\"path\":\"argument-limit\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"";
    const suffix = "\"}]}";
    const exact_arguments = try std.testing.allocator.alloc(u8, max_edit_arguments_bytes);
    defer std.testing.allocator.free(exact_arguments);
    @memcpy(exact_arguments[0..prefix.len], prefix);
    @memset(exact_arguments[prefix.len .. exact_arguments.len - suffix.len], 'x');
    @memcpy(exact_arguments[exact_arguments.len - suffix.len ..], suffix);
    var exact_arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arguments_arena.deinit();
    _ = try test_ws.value.edit.execute(
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
        try std.testing.expectEqual(max_edit_arguments_bytes - prefix.len - suffix.len, bytes.len);
    }

    const oversized_arguments = try std.testing.allocator.alloc(u8, max_edit_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized_arguments);
    @memset(oversized_arguments, 'x');
    var arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arguments_arena.deinit();
    const arguments_failure = try test_ws.value.edit.execute(
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
    const count_failure = try test_ws.value.edit.execute(count_arena.allocator(), std.testing.io, .{}, too_many);
    try std.testing.expectEqualStrings(invalid_edit_message, count_failure.failure);

    var oversized = try temporary.dir.createFile(std.testing.io, "oversized", .{});
    try oversized.setLength(std.testing.io, max_file_bytes + 1);
    oversized.close(std.testing.io);
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source_failure = try test_ws.value.edit.execute(
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
    const result_failure = try test_ws.value.edit.execute(
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
    var test_ws = try TestToolset.init(std.testing.io, workspace);
    defer test_ws.deinit();
    var traversal_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer traversal_arena.deinit();

    _ = try test_ws.value.edit.execute(
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

    _ = try test_ws.value.edit.execute(absolute_arena.allocator(), std.testing.io, .{}, arguments);
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
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, test_ws.value.edit.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"path\":\"target\",\"edits\":[{\"oldText\":\"before\",\"newText\":\"after\"}]}",
    ));
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);
}

test "bash applies only explicit and run-scoped deadlines" {
    try std.testing.expect(Bash.executionTimeout(std.testing.io, .none, null) == .none);
    const run_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromSeconds(30),
        .clock = .awake,
    });
    const run_only = Bash.executionTimeout(std.testing.io, .none, run_deadline);
    try std.testing.expect(run_only == .deadline);

    const configured = Bash.executionTimeout(std.testing.io, .{ .duration = .{
        .raw = .fromSeconds(1),
        .clock = .awake,
    } }, run_deadline);
    try std.testing.expect(configured == .deadline);
}

test "bash executes in the borrowed cwd and captures stderr and exit zero" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "" });
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const execution = try test_ws.value.bash.execute(
        arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"test -f marker && printf stdout; printf stderr >&2\"}",
    );
    try std.testing.expectEqualStrings(
        "stdout\n[stderr]\nstderr\n\nCommand exited with code 0",
        execution.success.content[0].text,
    );
}

test "bash returns bounded model failures for non-zero and empty output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var failure_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer failure_arena.deinit();
    const failure = try test_ws.value.bash.execute(
        failure_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf problem; exit 7\"}",
    );
    try std.testing.expectEqualStrings(
        "problem\n\nCommand exited with code 7",
        failure.failure,
    );

    var success_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer success_arena.deinit();
    const success = try test_ws.value.bash.execute(
        success_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\":\"}",
    );
    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand exited with code 0",
        success.success.content[0].text,
    );

    var signal_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer signal_arena.deinit();
    const signal = try test_ws.value.bash.execute(
        signal_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"kill -TERM $$\"}",
    );
    try std.testing.expect(std.mem.endsWith(u8, signal.failure, "Command terminated by signal 15"));
}

test "bash retains bounded line and byte tails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var lines_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lines_arena.deinit();

    const lines = try test_ws.value.bash.execute(
        lines_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"i=1; while [ $i -lt 2100 ]; do printf 'line-%04d\\n' $i; i=$((i+1)); done; " ++
            "printf 'line-%04d' $i\"}",
    );
    const line_text = lines.success.content[0].text;
    try std.testing.expect(line_text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0001") == null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0103") == null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-0104") != null);
    try std.testing.expect(std.mem.find(u8, line_text, "line-2100") != null);
    try std.testing.expect(std.mem.find(u8, line_text, "[Output truncated;") != null);
    try std.testing.expect(std.mem.count(u8, line_text, "\n") + 1 <= max_output_lines);

    var bytes_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer bytes_arena.deinit();
    const bytes = try test_ws.value.bash.execute(
        bytes_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf '%060000d' 0\"}",
    );
    const byte_text = bytes.success.content[0].text;
    try std.testing.expect(byte_text.len <= max_output_bytes);
    try std.testing.expect(std.mem.find(u8, byte_text, "[Output truncated;") != null);
    try std.testing.expect(std.mem.endsWith(u8, byte_text, "Command exited with code 0"));
}

test "bash rejects invalid arguments and invalid UTF-8 output" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    const cases = [_][]const u8{
        "{}",
        "{\"command\":\"\"}",
        "{\"command\":1}",
        "{\"command\":\"printf ok\",\"extra\":true}",
        "{\"command\":\"\\uD800\"}",
        "{\"command\":\"printf \\u0000\"}",
    };
    for (cases) |arguments| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const execution = try test_ws.value.bash.execute(arena.allocator(), std.testing.io, .{}, arguments);
        try std.testing.expectEqualStrings(invalid_bash_message, execution.failure);
    }

    var output_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output_arena.deinit();
    const invalid_output = try test_ws.value.bash.execute(
        output_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"printf '\\\\377'\"}",
    );
    try std.testing.expectEqualStrings(
        "Command output is not valid UTF-8.\n\nCommand exited with code 0",
        invalid_output.failure,
    );
}

test "bash enforces command bounds and settles timeout" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    const exact_command = try std.testing.allocator.alloc(u8, max_command_bytes);
    defer std.testing.allocator.free(exact_command);
    @memset(exact_command, ' ');
    exact_command[0] = ':';
    const exact_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .command = exact_command },
        .{},
    );
    defer std.testing.allocator.free(exact_arguments);
    var exact_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_arena.deinit();
    const exact = try test_ws.value.bash.execute(exact_arena.allocator(), std.testing.io, .{}, exact_arguments);
    try std.testing.expectEqualStrings(
        "(no output)\n\nCommand exited with code 0",
        exact.success.content[0].text,
    );

    const command = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(command);
    @memset(command, 'x');
    const arguments = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .command = command }, .{});
    defer std.testing.allocator.free(arguments);
    var command_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer command_arena.deinit();
    const command_failure = try test_ws.value.bash.execute(command_arena.allocator(), std.testing.io, .{}, arguments);
    try std.testing.expectEqualStrings(invalid_bash_message, command_failure.failure);

    const oversized_arguments = try std.testing.allocator.alloc(u8, max_bash_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized_arguments);
    @memset(oversized_arguments, 'x');
    var arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arguments_arena.deinit();
    const arguments_failure = try test_ws.value.bash.execute(
        arguments_arena.allocator(),
        std.testing.io,
        .{},
        oversized_arguments,
    );
    try std.testing.expectEqualStrings("Bash arguments exceed the 128KB input limit.", arguments_failure.failure);

    var timeout_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer timeout_ws.deinit();
    timeout_ws.value.bash.timeout = .{ .duration = .{
        .raw = .fromMilliseconds(10),
        .clock = .awake,
    } };
    var timeout_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer timeout_arena.deinit();
    try std.testing.expectError(error.TimedOut, timeout_ws.value.bash.execute(
        timeout_arena.allocator(),
        std.testing.io,
        .{},
        "{\"command\":\"while :; do :; done\"}",
    ));

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(10),
        .clock = .awake,
    });
    var deadline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer deadline_arena.deinit();
    try std.testing.expectError(error.TimedOut, test_ws.value.bash.execute(
        deadline_arena.allocator(),
        std.testing.io,
        .{ .deadline = deadline },
        "{\"command\":\"while :; do :; done\"}",
    ));
}

test "bash honors pre-cancellation without spawning" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var test_ws = try TestToolset.init(std.testing.io, temporary.dir);
    defer test_ws.deinit();
    var cancellation: ai_model.CancellationToken = .{};
    cancellation.cancel();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Cancelled, test_ws.value.bash.execute(
        arena.allocator(),
        std.testing.io,
        .{ .cancellation = &cancellation },
        "{\"command\":\"touch spawned\"}",
    ));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "spawned", .{}));
}
