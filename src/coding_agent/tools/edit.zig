//! Edit tool — replace text in a file with 3-tier matching.
//!
//! pi-mono parity: ports `edit-file.ts`. Carries over:
//! - tier-1 exact match → tier-2 unescape (\\n,\\t,\\r,\\\\) → tier-3
//!   "fuzzy" (trim trailing whitespace per line + smart-quote/dash
//!   normalization). Tier 3 mirrors pi's normalizeForFuzzyMatch sans the
//!   NFKC pass — full unicode normalization is not in zig std and the
//!   high-frequency cases (smart quotes / em dash / nbsp) cover almost
//!   every observed mismatch.
//! - replace_all single-edit mode
//! - multi-edit mode with overlap detection
//! - redaction marker guard (rejects new_str that introduces a
//!   "[REDACTED]" / "// ... existing code" placeholder)
//! - CRLF preservation: detect file's line ending, normalize to LF for
//!   matching, restore on write.
//!
//! Per-path mutex via `lock_registry`: two concurrent edits targeting
//! the same canonicalized file serialize, mirroring the ts override's
//! `withFileLock` on a `realpathSync.native` key. The lock spans the
//! full read-modify-write window.
//!
//! Skipped (deferred): BOM preservation (rare in practice for files we
//! edit), file-tracker hookup for undo_edit.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const diff_mod = @import("../../diff/document.zig");
const diff_unified = @import("../../diff/unified.zig");
const tool_result_details = @import("result_details.zig");
const lock_registry = @import("lock_registry.zig");
const json_value = @import("../../json/value.zig");

const SCHEMA =
    \\{"type":"object","properties":{
    \\"path":{"type":"string","description":"The absolute path to the file (MUST be absolute, not relative). File must exist."},
    \\"old_str":{"type":"string","description":"Text to search for in single-edit mode. Must match exactly."},
    \\"new_str":{"type":"string","description":"Text to replace old_str with in single-edit mode."},
    \\"replace_all":{"type":"boolean","description":"Set to true to replace all occurrences of old_str."},
    \\"edits":{"type":"array","items":{"type":"object","properties":{"old_str":{"type":"string"},"new_str":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["old_str","new_str"]},"description":"Multiple disjoint edits to apply in one call."}
    \\},"required":["path"]}
;

const DESCRIPTION =
    "Make edits to a text file.\n\n" ++
    "Use either `old_str` + `new_str` for one replacement, or `edits` for multiple disjoint replacements in one file.\n\n" ++
    "Returns a diff showing the changes made.\n\n" ++
    "The file specified by `path` MUST exist.\n\n" ++
    "Each `old_str` MUST exist in the file.\n\n" ++
    "For single mode, `old_str` and `new_str` MUST be different.\n\n" ++
    "Set `replace_all` to true to replace all occurrences of `old_str`. Otherwise, `old_str` MUST be unique within the file or the edit will fail.\n\n" ++
    "In `edits` mode, each edit is matched against the original file. Edits must not overlap.\n\n" ++
    "When changing an existing file, use this tool. Only use the write tool for files that do not exist yet.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "edit",
        .description = DESCRIPTION,
        .label = "Edit File",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
        .prompt_guidelines = &.{
            "Use edit for precise changes (edits[].old_str must match exactly)",
            "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
            "Each edits[].old_str is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
            "Keep edits[].old_str as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
        },
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .prepare_arguments = &prepareArguments, .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "edit" },
    };
}

const EditBlock = struct {
    old_str: []const u8,
    new_str: []const u8,
    replace_all: bool,
};

const MatchedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_len: usize,
    occurrences: usize,
    replace_str: []const u8,
    search_str: []const u8,
};

fn prepareArguments(allocator: std.mem.Allocator, args: std.json.Value) !std.json.Value {
    const obj = switch (args) {
        .object => |o| o,
        else => return args,
    };

    const old_str = util.getString(args, "old_str") orelse return args;
    const new_str = util.getString(args, "new_str") orelse return args;
    const top_level_replace_all = util.getBool(args, "replace_all");

    var normalized = try json_value.cloneJsonValue(allocator, args);
    var normalized_obj = &normalized.object;

    var edits_array = if (normalized_obj.fetchSwapRemove("edits")) |kv| blk: {
        allocator.free(kv.key);
        switch (kv.value) {
            .array => |arr| break :blk arr,
            else => {
                json_value.freeJsonValue(allocator, kv.value);
                return normalized;
            },
        }
    } else std.json.Array.init(allocator);

    var folded_edit: std.json.ObjectMap = .{};
    errdefer folded_edit.deinit(allocator);
    try folded_edit.put(allocator, try allocator.dupe(u8, "old_str"), .{ .string = try allocator.dupe(u8, old_str) });
    try folded_edit.put(allocator, try allocator.dupe(u8, "new_str"), .{ .string = try allocator.dupe(u8, new_str) });
    if (top_level_replace_all) |replace_all| {
        try folded_edit.put(allocator, try allocator.dupe(u8, "replace_all"), .{ .bool = replace_all });
    }
    try edits_array.append(.{ .object = folded_edit });

    try normalized_obj.put(allocator, try allocator.dupe(u8, "edits"), .{ .array = edits_array });
    if (normalized_obj.fetchSwapRemove("old_str")) |kv| {
        allocator.free(kv.key);
        json_value.freeJsonValue(allocator, kv.value);
    }
    if (normalized_obj.fetchSwapRemove("new_str")) |kv| {
        allocator.free(kv.key);
        json_value.freeJsonValue(allocator, kv.value);
    }
    if (normalized_obj.fetchSwapRemove("replace_all")) |kv| {
        allocator.free(kv.key);
        json_value.freeJsonValue(allocator, kv.value);
    }

    _ = obj;
    return normalized;
}

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    _: protocol.AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "edit tool: missing context")));

    const path = util.getString(args, "path") orelse
        return util.errorResult(allocator, "edit tool: missing 'path' argument");

    const resolved = util.resolvePath(allocator, path, ctx.cwd) catch
        return util.errorResult(allocator, "edit tool: failed to resolve path");
    defer allocator.free(resolved);

    const lock_entry = lock_registry.global().acquirePath(allocator, resolved) catch
        return util.errorResult(allocator, "edit tool: failed to acquire file lock");
    defer lock_registry.global().release(lock_entry);

    var edits: std.ArrayList(EditBlock) = .empty;
    defer edits.deinit(allocator);

    const obj = switch (args) {
        .object => |o| o,
        else => return util.errorResult(allocator, "edit tool: bad args"),
    };
    const has_edits_array = if (obj.get("edits")) |v| v == .array else false;

    if (has_edits_array) {
        const arr = obj.get("edits").?.array;
        for (arr.items) |item| {
            const eo = switch (item) {
                .object => |o| o,
                else => return util.errorResult(allocator, "edit tool: edits[] entries must be objects"),
            };
            const o_str = (eo.get("old_str") orelse return util.errorResult(allocator, "edit tool: missing old_str in edits[]")).string;
            const n_str = (eo.get("new_str") orelse return util.errorResult(allocator, "edit tool: missing new_str in edits[]")).string;
            const ra = if (eo.get("replace_all")) |v| (v == .bool and v.bool) else false;
            edits.append(allocator, .{
                .old_str = normalizeToLfDup(allocator, o_str) catch return util.errorResult(allocator, "alloc failed"),
                .new_str = normalizeToLfDup(allocator, n_str) catch return util.errorResult(allocator, "alloc failed"),
                .replace_all = ra,
            }) catch return util.errorResult(allocator, "alloc failed");
        }
    } else {
        return util.errorResult(allocator, "edit tool: input must be canonicalized to a non-empty edits array before execution.");
    }
    defer for (edits.items) |e| {
        allocator.free(e.old_str);
        allocator.free(e.new_str);
    };

    if (edits.items.len == 0)
        return util.errorResult(allocator, "edits must contain at least one replacement.");

    if (edits.items.len > 1) {
        for (edits.items) |e| if (e.replace_all) {
            return util.errorResult(allocator, "replace_all is only supported in single-edit mode. split this into separate calls or make each edit unique.");
        };
    }

    for (edits.items, 0..) |e, i| {
        if (e.old_str.len == 0) {
            return util.errorf(allocator, "edits[{d}].old_str must not be empty.", .{i});
        }
        if (std.mem.eql(u8, e.old_str, e.new_str)) {
            return util.errorf(allocator, "edits[{d}].old_str and new_str are identical. no changes needed.", .{i});
        }
        if (findRedactionMarker(e.old_str, e.new_str)) |marker| {
            return util.errorf(allocator, "rejected: edits[{d}].new_str contains a redaction marker (\"{s}\"). provide the actual content instead of placeholders.", .{ i, marker });
        }
    }

    const io_path = lock_registry.canonicalizePath(allocator, resolved) catch
        allocator.dupe(u8, resolved) catch return util.errorResult(allocator, "alloc failed");
    defer allocator.free(io_path);

    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, io_path, .{}) catch |err| {
        if (err == error.FileNotFound)
            return util.errorf(allocator, "file not found: {s}", .{resolved});
        return util.errorf(allocator, "edit tool: open failed: {s}", .{@errorName(err)});
    };
    const stat = file.stat(std.Options.debug_io) catch {
        file.close(std.Options.debug_io);
        return util.errorResult(allocator, "edit tool: stat failed");
    };
    if (stat.kind == .directory) {
        file.close(std.Options.debug_io);
        return util.errorf(allocator, "{s} is a directory, not a file.", .{resolved});
    }
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &read_buf);
    const raw = file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch {
        file.close(std.Options.debug_io);
        return util.errorResult(allocator, "edit tool: read failed");
    };
    file.close(std.Options.debug_io);
    defer allocator.free(raw);

    const ending = detectLineEnding(raw);
    const normalized = normalizeToLfDup(allocator, raw) catch
        return util.errorResult(allocator, "alloc failed");
    defer allocator.free(normalized);

    var failure: ?EditFailure = null;
    const apply_result = applyEdits(allocator, normalized, edits.items, &failure) catch |err| {
        return formatEditError(allocator, err, failure, edits.items);
    };
    defer {
        if (apply_result.base.ptr != normalized.ptr) allocator.free(apply_result.base);
        allocator.free(apply_result.new_content);
    }
    const base = apply_result.base;
    const new_content = apply_result.new_content;

    if (std.mem.eql(u8, base, new_content)) {
        return util.errorResult(allocator, "no changes made — replacement produced identical content.");
    }

    const final_bytes = if (ending == .crlf)
        restoreCrlf(allocator, new_content) catch return util.errorResult(allocator, "alloc failed")
    else
        allocator.dupe(u8, new_content) catch return util.errorResult(allocator, "alloc failed");
    defer allocator.free(final_bytes);

    atomicWriteFile(io_path, final_bytes, stat.permissions) catch
        return util.errorResult(allocator, "edit tool: write failed");

    const inputs = [_]diff_mod.Input{.{
        .old_path = std.fs.path.basename(resolved),
        .new_path = std.fs.path.basename(resolved),
        .old_text = base,
        .new_text = new_content,
    }};
    var doc = diff_mod.buildDocument(allocator, &inputs, .{}) catch |err|
        return util.errorf(allocator, "diff failed: {s}", .{@errorName(err)});
    defer doc.deinit();

    const details = tool_result_details.diffToJsonValue(allocator, doc.document) catch
        return util.errorResult(allocator, "diff details serialize failed");
    errdefer json_value.freeJsonValue(allocator, details);

    var unified = diff_unified.toUnified(allocator, doc.document) catch
        return util.errorResult(allocator, "diff serialize failed");
    errdefer allocator.free(unified);
    unified = tryTruncateOwnedText(allocator, unified) catch
        return util.errorResult(allocator, "diff truncate failed");

    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch {
        json_value.freeJsonValue(allocator, details);
        return util.errorResult(allocator, "alloc failed");
    };
    blocks[0] = .{ .text = .{ .text = unified } };
    return .{
        .content = blocks,
        .details = details,
        .is_error = false,
    };
}

fn tryTruncateOwnedText(allocator: std.mem.Allocator, owned: []u8) ![]u8 {
    if (owned.len <= util.Limits.text_result_bytes) return owned;
    const marker = "\n... [edit diff truncated at 64KiB safety cap] ...";
    const marker_len = @min(marker.len, util.Limits.text_result_bytes);
    const prefix_len = util.Limits.text_result_bytes - marker_len;
    const truncated = try allocator.alloc(u8, util.Limits.text_result_bytes);
    @memcpy(truncated[0..prefix_len], owned[0..prefix_len]);
    @memcpy(truncated[prefix_len..], marker[0..marker_len]);
    allocator.free(owned);
    return truncated;
}

const LineEnding = enum { lf, crlf };

fn detectLineEnding(s: []const u8) LineEnding {
    const crlf_idx = std.mem.indexOf(u8, s, "\r\n");
    const lf_idx = std.mem.indexOfScalar(u8, s, '\n');
    if (lf_idx == null or crlf_idx == null) return .lf;
    return if (crlf_idx.? < lf_idx.?) .crlf else .lf;
}

fn normalizeToLfDup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r') {
            out[n] = '\n';
            n += 1;
            if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
        } else {
            out[n] = s[i];
            n += 1;
        }
    }
    return allocator.realloc(out, n);
}

fn restoreCrlf(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var nl_count: usize = 0;
    for (s) |c| {
        if (c == '\n') nl_count += 1;
    }
    var out = try allocator.alloc(u8, s.len + nl_count);
    var n: usize = 0;
    for (s) |c| {
        if (c == '\n') {
            out[n] = '\r';
            out[n + 1] = '\n';
            n += 2;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

fn atomicWriteFile(path: []const u8, bytes: []const u8, permissions: std.Io.File.Permissions) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(std.Options.debug_io, path, .{ .permissions = permissions, .replace = true });
    defer atomic_file.deinit(std.Options.debug_io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(std.Options.debug_io, &write_buffer);
    try file_writer.interface.writeAll(bytes);
    try file_writer.interface.flush();
    try atomic_file.file.sync(std.Options.debug_io);
    try atomic_file.replace(std.Options.debug_io);
}

// pi-mono normalizes via NFKC + trailing-whitespace trim + smart-quote
// normalization. We skip NFKC (no unicode tables in std) and do the
// trim + the most common smart-quote / dash / nbsp substitutions, which
// covers >95% of the cases the fuzzy tier exists for.

fn fuzzyNormalize(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);

    var i: usize = 0;
    while (i < s.len) {
        const remaining = s[i..];
        if (remaining.len >= 3) {
            const a = remaining[0];
            const b = remaining[1];
            const c = remaining[2];
            if (a == 0xE2 and b == 0x80 and c >= 0x98 and c <= 0x9F) {
                try out.append(allocator, if (c <= 0x9B) @as(u8, '\'') else @as(u8, '"'));
                i += 3;
                continue;
            }
            if (a == 0xE2 and b == 0x80 and c >= 0x90 and c <= 0x95) {
                try out.append(allocator, '-');
                i += 3;
                continue;
            }
            if (a == 0xE2 and b == 0x88 and c == 0x92) {
                try out.append(allocator, '-');
                i += 3;
                continue;
            }
            if (a == 0xE2 and b == 0x80 and ((c >= 0x82 and c <= 0x8A) or c == 0xAF)) {
                try out.append(allocator, ' ');
                i += 3;
                continue;
            }
            if (a == 0xE2 and b == 0x81 and c == 0x9F) {
                try out.append(allocator, ' ');
                i += 3;
                continue;
            }
            if (a == 0xE3 and b == 0x80 and c == 0x80) {
                try out.append(allocator, ' ');
                i += 3;
                continue;
            }
        }
        if (remaining.len >= 2) {
            if (remaining[0] == 0xC2 and remaining[1] == 0xA0) {
                try out.append(allocator, ' ');
                i += 2;
                continue;
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }

    var trimmed: std.ArrayList(u8) = .empty;
    defer trimmed.deinit(allocator);
    try trimmed.ensureTotalCapacity(allocator, out.items.len);
    var line_start: usize = 0;
    var k: usize = 0;
    while (k <= out.items.len) : (k += 1) {
        if (k == out.items.len or out.items[k] == '\n') {
            const line = out.items[line_start..k];
            const t = std.mem.trimEnd(u8, line, " \t");
            try trimmed.appendSlice(allocator, t);
            if (k < out.items.len) try trimmed.append(allocator, '\n');
            line_start = k + 1;
        }
    }
    return trimmed.toOwnedSlice(allocator);
}

fn unescapeStrDup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const c = s[i + 1];
            const replacement: ?u8 = switch (c) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => null,
            };
            if (replacement) |r| {
                try out.append(allocator, r);
                i += 1;
                continue;
            }
        }
        try out.append(allocator, s[i]);
    }
    return out.toOwnedSlice(allocator);
}

const ApplyResult = struct {
    base: []const u8,
    new_content: []u8,
};

const EditError = error{
    NotFound,
    Ambiguous,
    Overlap,
    OutOfMemory,
};

/// Per-failure context. Populated by `applyEdits` on the error return
/// path so the caller can build a descriptive message that tells the
/// model WHICH edit failed and WHAT it tried to match. Without this
/// the model just sees "NotFound" and loops forever retrying the same
/// broken old_str.
const EditFailure = struct {
    edit_index: usize,
    kind: enum { not_found, ambiguous, overlap },
    occurrences: usize = 0,
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) {
            n += 1;
            i += needle.len;
        } else i += 1;
    }
    return n;
}

const SearchStats = struct {
    first_index: usize,
    occurrences: usize,
};

const PreparedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_len: usize,
    occurrences: usize,
    search_str: []const u8,
    replace_str: []const u8,
};

const CachedEdit = struct {
    edit_index: usize,
    old_str: []const u8,
    new_str: []const u8,
    unescaped_old: ?[]const u8 = null,
    unescaped_new: ?[]const u8 = null,
    fuzzy_old: ?[]const u8 = null,

    fn deinit(self: *CachedEdit, allocator: std.mem.Allocator) void {
        if (self.unescaped_old) |s| allocator.free(s);
        if (self.unescaped_new) |s| allocator.free(s);
        if (self.fuzzy_old) |s| allocator.free(s);
    }
};

const MatchMode = enum { no_fuzzy, fuzzy_base };

fn findSearchStats(haystack: []const u8, needle: []const u8) ?SearchStats {
    if (needle.len == 0) return .{ .first_index = 0, .occurrences = 0 };
    if (needle.len > haystack.len) return null;

    var first: ?usize = null;
    var occurrences: usize = 0;
    var start: usize = 0;
    while (start <= haystack.len - needle.len) {
        const idx = std.mem.indexOfPos(u8, haystack, start, needle) orelse break;
        if (first == null) first = idx;
        occurrences += 1;
        start = idx + needle.len;
    }

    return if (first) |idx| .{ .first_index = idx, .occurrences = occurrences } else null;
}

fn needsUnescape(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\\') != null;
}

fn cachedUnescapedOld(allocator: std.mem.Allocator, cache: *CachedEdit) !?[]const u8 {
    if (!needsUnescape(cache.old_str)) return null;
    if (cache.unescaped_old == null) {
        const unescaped = try unescapeStrDup(allocator, cache.old_str);
        if (std.mem.eql(u8, unescaped, cache.old_str)) {
            allocator.free(unescaped);
            return null;
        }
        cache.unescaped_old = unescaped;
    }
    return cache.unescaped_old;
}

fn cachedUnescapedNew(allocator: std.mem.Allocator, cache: *CachedEdit) ![]const u8 {
    if (cache.unescaped_new) |s| return s;
    const unescaped = try unescapeStrDup(allocator, cache.new_str);
    cache.unescaped_new = unescaped;
    return unescaped;
}

fn cachedFuzzyOld(allocator: std.mem.Allocator, cache: *CachedEdit) ![]const u8 {
    if (cache.fuzzy_old) |s| return s;
    const fuzzy = try fuzzyNormalize(allocator, cache.old_str);
    cache.fuzzy_old = fuzzy;
    return fuzzy;
}

fn prepareMatch(
    allocator: std.mem.Allocator,
    base: []const u8,
    cache: *CachedEdit,
    mode: MatchMode,
) !?PreparedEdit {
    if (findSearchStats(base, cache.old_str)) |stats| {
        return .{
            .edit_index = cache.edit_index,
            .match_index = stats.first_index,
            .match_len = cache.old_str.len,
            .occurrences = stats.occurrences,
            .search_str = cache.old_str,
            .replace_str = cache.new_str,
        };
    }

    if (try cachedUnescapedOld(allocator, cache)) |unescaped_old| {
        if (findSearchStats(base, unescaped_old)) |stats| {
            return .{
                .edit_index = cache.edit_index,
                .match_index = stats.first_index,
                .match_len = unescaped_old.len,
                .occurrences = stats.occurrences,
                .search_str = unescaped_old,
                .replace_str = try cachedUnescapedNew(allocator, cache),
            };
        }
    }

    if (mode == .fuzzy_base) {
        const fuzzy_old = try cachedFuzzyOld(allocator, cache);
        if (findSearchStats(base, fuzzy_old)) |stats| {
            return .{
                .edit_index = cache.edit_index,
                .match_index = stats.first_index,
                .match_len = fuzzy_old.len,
                .occurrences = stats.occurrences,
                .search_str = fuzzy_old,
                .replace_str = cache.new_str,
            };
        }
    }

    return null;
}

fn rewriteOnce(
    allocator: std.mem.Allocator,
    base: []const u8,
    matches: []const MatchedEdit,
) EditError![]u8 {
    var final_len = base.len;
    for (matches) |m| {
        final_len = final_len - m.match_len + m.replace_str.len;
    }

    var out = allocator.alloc(u8, final_len) catch return error.OutOfMemory;
    var src_index: usize = 0;
    var dst_index: usize = 0;

    for (matches) |m| {
        const unchanged = base[src_index..m.match_index];
        @memcpy(out[dst_index..][0..unchanged.len], unchanged);
        dst_index += unchanged.len;

        @memcpy(out[dst_index..][0..m.replace_str.len], m.replace_str);
        dst_index += m.replace_str.len;
        src_index = m.match_index + m.match_len;
    }

    const tail = base[src_index..];
    @memcpy(out[dst_index..][0..tail.len], tail);
    return out;
}

fn rewriteReplaceAll(
    allocator: std.mem.Allocator,
    base: []const u8,
    match: MatchedEdit,
) EditError![]u8 {
    if (match.occurrences == 0) return allocator.dupe(u8, base) catch return error.OutOfMemory;

    const final_len = base.len - (match.match_len * match.occurrences) + (match.replace_str.len * match.occurrences);
    var out = allocator.alloc(u8, final_len) catch return error.OutOfMemory;

    var src_index: usize = 0;
    var dst_index: usize = 0;
    while (std.mem.indexOfPos(u8, base, src_index, match.search_str)) |idx| {
        const unchanged = base[src_index..idx];
        @memcpy(out[dst_index..][0..unchanged.len], unchanged);
        dst_index += unchanged.len;

        @memcpy(out[dst_index..][0..match.replace_str.len], match.replace_str);
        dst_index += match.replace_str.len;
        src_index = idx + match.match_len;
    }

    const tail = base[src_index..];
    @memcpy(out[dst_index..][0..tail.len], tail);
    return out;
}

fn applyEdits(
    allocator: std.mem.Allocator,
    content: []const u8,
    edits: []const EditBlock,
    failure_out: *?EditFailure,
) EditError!ApplyResult {
    var caches = try allocator.alloc(CachedEdit, edits.len);
    defer allocator.free(caches);
    for (edits, 0..) |e, idx| {
        caches[idx] = .{ .edit_index = idx, .old_str = e.old_str, .new_str = e.new_str };
    }
    defer for (caches) |*cache| cache.deinit(allocator);

    var any_fuzzy = false;
    for (caches) |*cache| {
        if (try prepareMatch(allocator, content, cache, .no_fuzzy) == null) {
            any_fuzzy = true;
            break;
        }
    }

    const base: []const u8 = if (any_fuzzy)
        try fuzzyNormalize(allocator, content)
    else
        content;
    const base_owned = any_fuzzy;
    errdefer if (base_owned) allocator.free(base);

    var matches: std.ArrayList(MatchedEdit) = .empty;
    defer matches.deinit(allocator);
    try matches.ensureTotalCapacity(allocator, edits.len);

    for (caches) |*cache| {
        const prepared = (try prepareMatch(allocator, base, cache, if (any_fuzzy) .fuzzy_base else .no_fuzzy)) orelse {
            failure_out.* = .{ .edit_index = cache.edit_index, .kind = .not_found };
            return error.NotFound;
        };
        if (!edits[cache.edit_index].replace_all and prepared.occurrences > 1) {
            failure_out.* = .{ .edit_index = cache.edit_index, .kind = .ambiguous, .occurrences = prepared.occurrences };
            return error.Ambiguous;
        }
        matches.appendAssumeCapacity(.{
            .edit_index = prepared.edit_index,
            .match_index = prepared.match_index,
            .match_len = prepared.match_len,
            .occurrences = prepared.occurrences,
            .replace_str = prepared.replace_str,
            .search_str = prepared.search_str,
        });
    }

    if (matches.items.len == 1 and edits[matches.items[0].edit_index].replace_all) {
        const new_content = try rewriteReplaceAll(allocator, base, matches.items[0]);
        return .{ .base = base, .new_content = new_content };
    }

    std.mem.sort(MatchedEdit, matches.items, {}, struct {
        fn lt(_: void, a: MatchedEdit, b: MatchedEdit) bool {
            return a.match_index < b.match_index;
        }
    }.lt);

    var i: usize = 1;
    while (i < matches.items.len) : (i += 1) {
        const prev = matches.items[i - 1];
        const cur = matches.items[i];
        if (prev.match_index + prev.match_len > cur.match_index) {
            failure_out.* = .{ .edit_index = cur.edit_index, .kind = .overlap };
            return error.Overlap;
        }
    }

    const new_content = try rewriteOnce(allocator, base, matches.items);
    return .{ .base = base, .new_content = new_content };
}

const REDACTION_NEEDLES = [_][]const u8{
    "[REDACTED]",
    "// ... existing code",
    "// ...existing code",
    "# ... existing code",
    "[rest of file unchanged]",
    "[remaining code unchanged]",
};

fn findRedactionMarker(old_str: []const u8, new_str: []const u8) ?[]const u8 {
    for (REDACTION_NEEDLES) |needle| {
        if (std.ascii.indexOfIgnoreCase(new_str, needle) != null and
            std.ascii.indexOfIgnoreCase(old_str, needle) == null)
        {
            return needle;
        }
    }
    return null;
}

// `applyEdits` raises bare error tags (NotFound / Ambiguous / Overlap).
// The caller pairs each tag with the populated `EditFailure` to build
// a message the model can ACT ON: which edit failed, why, and a
// preview of the offending old_str so it can correct course.
// Without this the model just sees "NotFound" and retries the same
// broken edit forever.

const PREVIEW_MAX: usize = 120;

fn formatEditError(
    allocator: std.mem.Allocator,
    err: EditError,
    failure: ?EditFailure,
    edits: []const EditBlock,
) protocol.AgentToolResult {
    if (err == error.OutOfMemory) {
        return util.errorResult(allocator, "edit tool: out of memory");
    }
    const f = failure orelse {
        return util.errorf(allocator, "edit tool: {s}", .{@errorName(err)});
    };
    const idx = f.edit_index;
    const single = edits.len == 1;
    const which = if (single) @as([]const u8, "old_str") else "edits[N].old_str";
    _ = which;

    switch (f.kind) {
        .not_found => {
            const preview = previewLine(allocator, edits[idx].old_str) catch "?";
            defer if (preview.len > 0 and !std.mem.eql(u8, preview, "?")) allocator.free(preview);
            const msg = if (single)
                std.fmt.allocPrint(
                    allocator,
                    "could not find old_str in the file. the text must match EXACTLY including whitespace, indentation and newlines.\n\nfirst line of what you tried to find:\n  {s}\n\nfix: read the file again to confirm the exact text, then retry with the precise content.",
                    .{preview},
                )
            else
                std.fmt.allocPrint(
                    allocator,
                    "could not find edits[{d}].old_str in the file. the text must match EXACTLY including whitespace, indentation and newlines.\n\nfirst line of what you tried to find:\n  {s}\n\nfix: read the file again to confirm the exact text, then retry with the precise content.",
                    .{ idx, preview },
                );
            const owned = msg catch return util.errorResult(allocator, "could not find old_str in the file");
            return util.errorResult(allocator, owned);
        },
        .ambiguous => {
            const msg = std.fmt.allocPrint(
                allocator,
                "found {d} occurrences of {s}old_str in the file. set replace_all=true if you want them all replaced, OR add more surrounding context to old_str so it uniquely identifies one location.",
                .{ f.occurrences, if (single) "" else std.fmt.allocPrint(allocator, "edits[{d}].", .{idx}) catch "" },
            ) catch return util.errorResult(allocator, "ambiguous match");
            return util.errorResult(allocator, msg);
        },
        .overlap => {
            const msg = std.fmt.allocPrint(
                allocator,
                "edits[{d}] overlaps with another edit. each edit must target a disjoint region of the file. merge them into a single edit or split them across separate tool calls.",
                .{idx},
            ) catch return util.errorResult(allocator, "overlapping edits");
            return util.errorResult(allocator, msg);
        },
    }
}

/// Truncate to the first line, then to PREVIEW_MAX bytes. Returns
/// owned memory unless the input is short enough to slice (in which
/// case it returns the static string "?" sentinel — caller checks).
fn previewLine(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    const first = s[0..nl];
    const cap = @min(first.len, PREVIEW_MAX);
    if (cap == first.len and first.len > 0) return allocator.dupe(u8, first);
    if (first.len == 0) return allocator.dupe(u8, "(empty line)");
    // Truncation marker: ASCII "..." (3 bytes) — keeps the buffer
    // bytes-not-codepoints since `previewLine`'s caller treats it as a
    // []const u8 slice. A real `…` is 3 bytes of UTF-8 too but doesn't
    // fit in a single u8.
    const buf = try allocator.alloc(u8, cap + 3);
    @memcpy(buf[0..cap], first[0..cap]);
    buf[cap] = '.';
    buf[cap + 1] = '.';
    buf[cap + 2] = '.';
    return buf;
}

test "prepareArguments folds top-level single edit into canonical edits array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"path":"file.txt","old_str":"before","new_str":"after","replace_all":true}
    ,
        .{},
    );

    const prepared = try prepareArguments(std.testing.allocator, input);
    defer json_value.freeJsonValue(std.testing.allocator, prepared);

    try std.testing.expectEqualStrings("file.txt", prepared.object.get("path").?.string);
    try std.testing.expect(prepared.object.get("old_str") == null);
    try std.testing.expect(prepared.object.get("new_str") == null);
    try std.testing.expect(prepared.object.get("replace_all") == null);
    const edits = prepared.object.get("edits").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("before", edits[0].object.get("old_str").?.string);
    try std.testing.expectEqualStrings("after", edits[0].object.get("new_str").?.string);
    try std.testing.expectEqual(true, edits[0].object.get("replace_all").?.bool);
}

test "prepareArguments appends top-level single edit to existing edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"path":"file.txt","edits":[{"old_str":"a","new_str":"b"}],"old_str":"c","new_str":"d"}
    ,
        .{},
    );

    const prepared = try prepareArguments(std.testing.allocator, input);
    defer json_value.freeJsonValue(std.testing.allocator, prepared);

    const edits = prepared.object.get("edits").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("a", edits[0].object.get("old_str").?.string);
    try std.testing.expectEqualStrings("b", edits[0].object.get("new_str").?.string);
    try std.testing.expectEqualStrings("c", edits[1].object.get("old_str").?.string);
    try std.testing.expectEqualStrings("d", edits[1].object.get("new_str").?.string);
}

test "prepareArguments leaves non-canonical input unchanged when it cannot fold a single edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        \\{"path":"file.txt","old_str":"before"}
    ,
        .{},
    );

    const prepared = try prepareArguments(std.testing.allocator, input);
    try std.testing.expect(prepared == .object);
    try std.testing.expectEqualStrings("file.txt", prepared.object.get("path").?.string);
    try std.testing.expectEqualStrings("before", prepared.object.get("old_str").?.string);
    try std.testing.expect(prepared.object.get("new_str") == null);
    try std.testing.expect(prepared.object.get("edits") == null);
}

test "atomic write preserves mode and replaces hardlink identity" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.Options.debug_io, "target.txt", .{});
    var write_buf: [64]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &write_buf);
    try writer.interface.writeAll("before\n");
    try writer.interface.flush();
    try file.setPermissions(std.Options.debug_io, .fromMode(0o640));
    file.close(std.Options.debug_io);

    const target_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "target.txt", testing.allocator);
    defer testing.allocator.free(target_path);
    const link_path = try std.fs.path.join(testing.allocator, &.{ std.fs.path.dirname(target_path).?, "linked.txt" });
    defer testing.allocator.free(link_path);
    const target_z = try testing.allocator.dupeZ(u8, target_path);
    defer testing.allocator.free(target_z);
    const link_z = try testing.allocator.dupeZ(u8, link_path);
    defer testing.allocator.free(link_z);
    if (std.c.link(target_z, link_z) != 0) return error.Unexpected;

    const before_target = try tmp.dir.statFile(std.Options.debug_io, "target.txt", .{});
    const before_link = try tmp.dir.statFile(std.Options.debug_io, "linked.txt", .{});
    try testing.expectEqual(before_target.inode, before_link.inode);

    try atomicWriteFile(target_path, "after\n", before_target.permissions);

    const after_target = try tmp.dir.statFile(std.Options.debug_io, "target.txt", .{});
    const after_link = try tmp.dir.statFile(std.Options.debug_io, "linked.txt", .{});
    try testing.expect(after_target.inode != before_target.inode);
    try testing.expectEqual(before_link.inode, after_link.inode);
    try testing.expectEqual(before_target.permissions, after_target.permissions);

    const target_contents = try tmp.dir.readFileAlloc(std.Options.debug_io, "target.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(target_contents);
    const link_contents = try tmp.dir.readFileAlloc(std.Options.debug_io, "linked.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(link_contents);
    try testing.expectEqualStrings("after\n", target_contents);
    try testing.expectEqualStrings("before\n", link_contents);
}

test "execute returns unified diff content with structured diff details" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "note.txt",
        .data = "one\ntwo\nthree\n",
    });

    const abs_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "note.txt", testing.allocator);
    defer testing.allocator.free(abs_path);

    var edit_obj: std.json.ObjectMap = .{};
    errdefer json_value.freeJsonValue(testing.allocator, .{ .object = edit_obj });
    try edit_obj.put(testing.allocator, try testing.allocator.dupe(u8, "old_str"), .{ .string = try testing.allocator.dupe(u8, "two\n") });
    try edit_obj.put(testing.allocator, try testing.allocator.dupe(u8, "new_str"), .{ .string = try testing.allocator.dupe(u8, "TWO\n") });

    var edits_arr = std.json.Array.init(testing.allocator);
    errdefer json_value.freeJsonValue(testing.allocator, .{ .array = edits_arr });
    try edits_arr.append(.{ .object = edit_obj });

    var args_obj: std.json.ObjectMap = .{};
    errdefer json_value.freeJsonValue(testing.allocator, .{ .object = args_obj });
    try args_obj.put(testing.allocator, try testing.allocator.dupe(u8, "path"), .{ .string = try testing.allocator.dupe(u8, abs_path) });
    try args_obj.put(testing.allocator, try testing.allocator.dupe(u8, "edits"), .{ .array = edits_arr });
    const args: std.json.Value = .{ .object = args_obj };
    defer json_value.freeJsonValue(testing.allocator, args);

    var builtin_ctx = util.BuiltinCtx{ .cwd = "/" };
    const result = execute(
        @ptrCast(&builtin_ctx),
        testing.allocator,
        "call-1",
        args,
        protocol.AbortSignal.none,
        null,
        null,
    );
    defer result.free(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expect(result.content[0] == .text);

    const unified = result.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, unified, "--- note.txt\n") != null);
    try testing.expect(std.mem.indexOf(u8, unified, "+++ note.txt\n") != null);
    try testing.expect(std.mem.indexOf(u8, unified, "-two\n") != null);
    try testing.expect(std.mem.indexOf(u8, unified, "+TWO\n") != null);

    try testing.expect(result.details == .object);
    try testing.expectEqualStrings("diff", result.details.object.get("kind").?.string);
    try testing.expectEqual(@as(i64, 2), result.details.object.get("version").?.integer);
    const diff_details = result.details.object.get("diff").?;
    try testing.expectEqual(@as(i64, 1), diff_details.object.get("stats").?.object.get("added").?.integer);
    try testing.expectEqual(@as(i64, 1), diff_details.object.get("stats").?.object.get("removed").?.integer);

    const final_contents = try tmp.dir.readFileAlloc(std.Options.debug_io, "note.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(final_contents);
    try testing.expectEqualStrings("one\nTWO\nthree\n", final_contents);
}
