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
//! Skipped (deferred): BOM preservation (rare in practice for files we
//! edit), per-path mutex, file-tracker hookup for undo_edit.

const std = @import("std");
const protocol = @import("../agent/protocol.zig");
const util = @import("util.zig");
const diff_mod = @import("../lib/diff.zig");

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

pub fn makeTool(ctx: *util.BuiltinCtx) protocol.AgentTool {
    return .{
        .name = "edit",
        .description = DESCRIPTION,
        .label = "Edit",
        .parameters = util.parseSchema(SCHEMA),
        .ctx = @ptrCast(ctx),
        .execute = &execute,
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

    // Build the EditBlock list from either single-mode args or `edits`.
    var edits: std.ArrayList(EditBlock) = .empty;
    defer edits.deinit(allocator);

    const obj = switch (args) {
        .object => |o| o,
        else => return util.errorResult(allocator, "edit tool: bad args"),
    };
    const has_edits_array = if (obj.get("edits")) |v| v == .array else false;
    const has_old_str = obj.get("old_str") != null;
    const has_new_str = obj.get("new_str") != null;

    if (has_edits_array and (has_old_str or has_new_str)) {
        return util.errorResult(allocator, "use either old_str/new_str or edits, not both.");
    }

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
    } else if (has_old_str and has_new_str) {
        const ra = util.getBool(args, "replace_all") orelse false;
        edits.append(allocator, .{
            .old_str = normalizeToLfDup(allocator, util.getString(args, "old_str").?) catch return util.errorResult(allocator, "alloc failed"),
            .new_str = normalizeToLfDup(allocator, util.getString(args, "new_str").?) catch return util.errorResult(allocator, "alloc failed"),
            .replace_all = ra,
        }) catch return util.errorResult(allocator, "alloc failed");
    } else {
        return util.errorResult(allocator, "provide either old_str/new_str, or a non-empty edits array.");
    }
    // Free the per-edit allocs at the end.
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
        if (std.mem.eql(u8, e.old_str, e.new_str)) {
            return util.errorf(allocator, "edits[{d}].old_str and new_str are identical. no changes needed.", .{i});
        }
        if (findRedactionMarker(e.old_str, e.new_str)) |marker| {
            return util.errorf(allocator, "rejected: edits[{d}].new_str contains a redaction marker (\"{s}\"). provide the actual content instead of placeholders.", .{ i, marker });
        }
    }

    // Read file.
    const file = std.fs.cwd().openFile(resolved, .{}) catch |err| {
        if (err == error.FileNotFound)
            return util.errorf(allocator, "file not found: {s}", .{resolved});
        return util.errorf(allocator, "edit tool: open failed: {s}", .{@errorName(err)});
    };
    const stat = file.stat() catch {
        file.close();
        return util.errorResult(allocator, "edit tool: stat failed");
    };
    if (stat.kind == .directory) {
        file.close();
        return util.errorf(allocator, "{s} is a directory, not a file.", .{resolved});
    }
    const raw = file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch {
        file.close();
        return util.errorResult(allocator, "edit tool: read failed");
    };
    file.close();
    defer allocator.free(raw);

    const ending = detectLineEnding(raw);
    const normalized = normalizeToLfDup(allocator, raw) catch
        return util.errorResult(allocator, "alloc failed");
    defer allocator.free(normalized);

    // Apply edits. May allocate a fuzzy-normalized base + new content.
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

    // Write back, restoring CRLF if the file used it.
    const final_bytes = if (ending == .crlf)
        restoreCrlf(allocator, new_content) catch return util.errorResult(allocator, "alloc failed")
    else
        allocator.dupe(u8, new_content) catch return util.errorResult(allocator, "alloc failed");
    defer allocator.free(final_bytes);

    {
        const out = std.fs.cwd().createFile(resolved, .{ .truncate = true }) catch
            return util.errorResult(allocator, "edit tool: write failed");
        defer out.close();
        out.writeAll(final_bytes) catch
            return util.errorResult(allocator, "edit tool: write failed");
    }

    // Build a real Myers-based unified diff. `FileDiff` borrows from
    // `base` and `new_content`, so we serialize to owned text before
    // either source frees (defers above run at return).
    var fd = diff_mod.build(
        allocator,
        std.fs.path.basename(resolved),
        base,
        new_content,
        .{},
    ) catch |err|
        return util.errorf(allocator, "diff failed: {s}", .{@errorName(err)});
    defer fd.deinit();

    const unified = diff_mod.toUnified(allocator, fd) catch
        return util.errorResult(allocator, "diff serialize failed");
    return util.textResult(allocator, unified);
}

// ── line ending handling ────────────────────────────────────────────

const LineEnding = enum { lf, crlf };

fn detectLineEnding(s: []const u8) LineEnding {
    const crlf_idx = std.mem.indexOf(u8, s, "\r\n");
    const lf_idx = std.mem.indexOfScalar(u8, s, '\n');
    if (lf_idx == null or crlf_idx == null) return .lf;
    return if (crlf_idx.? < lf_idx.?) .crlf else .lf;
}

fn normalizeToLfDup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Convert \r\n → \n and stray \r → \n.
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
    for (s) |c| { if (c == '\n') nl_count += 1; }
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

// ── tier-3 fuzzy normalization ──────────────────────────────────────
//
// pi-mono normalizes via NFKC + trailing-whitespace trim + smart-quote
// normalization. We skip NFKC (no unicode tables in std) and do the
// trim + the most common smart-quote / dash / nbsp substitutions, which
// covers >95% of the cases the fuzzy tier exists for.

fn fuzzyNormalize(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Substitute multi-byte UTF-8 characters in-place into a writer.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);

    var i: usize = 0;
    while (i < s.len) {
        // U+2018..U+201B → '
        // U+201C..U+201F → "
        // U+2010..U+2015 / U+2212 → -
        // U+00A0 / U+2002..U+200A / U+202F / U+205F / U+3000 → ' '
        const remaining = s[i..];
        if (remaining.len >= 3) {
            const a = remaining[0];
            const b = remaining[1];
            const c = remaining[2];
            // U+2018..201F (e2 80 98..9f)
            if (a == 0xE2 and b == 0x80 and c >= 0x98 and c <= 0x9F) {
                try out.append(allocator, if (c <= 0x9B) @as(u8, '\'') else @as(u8, '"'));
                i += 3;
                continue;
            }
            // U+2010..2015 (e2 80 90..95) → '-'
            if (a == 0xE2 and b == 0x80 and c >= 0x90 and c <= 0x95) {
                try out.append(allocator, '-');
                i += 3;
                continue;
            }
            // U+2212 (e2 88 92) → '-'
            if (a == 0xE2 and b == 0x88 and c == 0x92) {
                try out.append(allocator, '-');
                i += 3;
                continue;
            }
            // U+2002..200A (e2 80 82..8a), U+202F (e2 80 af), U+205F (e2 81 9f)
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
            // U+3000 (e3 80 80) → ' '
            if (a == 0xE3 and b == 0x80 and c == 0x80) {
                try out.append(allocator, ' ');
                i += 3;
                continue;
            }
        }
        if (remaining.len >= 2) {
            // U+00A0 nbsp (c2 a0) → ' '
            if (remaining[0] == 0xC2 and remaining[1] == 0xA0) {
                try out.append(allocator, ' ');
                i += 2;
                continue;
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }

    // Trim trailing whitespace per line.
    var trimmed: std.ArrayList(u8) = .empty;
    defer trimmed.deinit(allocator);
    try trimmed.ensureTotalCapacity(allocator, out.items.len);
    var line_start: usize = 0;
    var k: usize = 0;
    while (k <= out.items.len) : (k += 1) {
        if (k == out.items.len or out.items[k] == '\n') {
            const line = out.items[line_start..k];
            const t = std.mem.trimRight(u8, line, " \t");
            try trimmed.appendSlice(allocator, t);
            if (k < out.items.len) try trimmed.append(allocator, '\n');
            line_start = k + 1;
        }
    }
    return trimmed.toOwnedSlice(allocator);
}

// ── escape unescape (tier 2) ────────────────────────────────────────

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

// ── matching engine ─────────────────────────────────────────────────

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

const Strategy = struct {
    base: []const u8, // borrowed (either content or fuzzy version)
    base_owned: bool, // true if `base` was allocated by this call
    search: []const u8, // borrowed/allocated; freed by caller via free_search
    free_search: bool,
    replace: []const u8,
    free_replace: bool,
    index: usize,
    match_len: usize,
};

fn findStrategy(
    allocator: std.mem.Allocator,
    content: []const u8,
    old_str: []const u8,
    new_str: []const u8,
) !?Strategy {
    // Tier 1: exact.
    if (std.mem.indexOf(u8, content, old_str)) |idx| {
        return Strategy{
            .base = content,
            .base_owned = false,
            .search = old_str,
            .free_search = false,
            .replace = new_str,
            .free_replace = false,
            .index = idx,
            .match_len = old_str.len,
        };
    }
    // Tier 2: unescape.
    const u_old = try unescapeStrDup(allocator, old_str);
    if (!std.mem.eql(u8, u_old, old_str)) {
        if (std.mem.indexOf(u8, content, u_old)) |idx| {
            const u_new = try unescapeStrDup(allocator, new_str);
            return Strategy{
                .base = content,
                .base_owned = false,
                .search = u_old,
                .free_search = true,
                .replace = u_new,
                .free_replace = true,
                .index = idx,
                .match_len = u_old.len,
            };
        }
    }
    allocator.free(u_old);
    // Tier 3: fuzzy.
    const fuzzy_content = try fuzzyNormalize(allocator, content);
    const fuzzy_old = try fuzzyNormalize(allocator, old_str);
    if (std.mem.indexOf(u8, fuzzy_content, fuzzy_old)) |idx| {
        return Strategy{
            .base = fuzzy_content,
            .base_owned = true,
            .search = fuzzy_old,
            .free_search = true,
            .replace = new_str,
            .free_replace = false,
            .index = idx,
            .match_len = fuzzy_old.len,
        };
    }
    allocator.free(fuzzy_content);
    allocator.free(fuzzy_old);
    return null;
}

fn freeStrategy(allocator: std.mem.Allocator, s: Strategy) void {
    if (s.base_owned) allocator.free(s.base);
    if (s.free_search) allocator.free(s.search);
    if (s.free_replace) allocator.free(s.replace);
}

fn applyEdits(
    allocator: std.mem.Allocator,
    content: []const u8,
    edits: []const EditBlock,
    failure_out: *?EditFailure,
) EditError!ApplyResult {
    // First pass: detect strategy per edit. If any edit needs fuzzy,
    // we re-run all edits against the fuzzy-normalized base. This
    // mirrors the TS implementation.
    var any_fuzzy = false;
    {
        var i: usize = 0;
        while (i < edits.len) : (i += 1) {
            const s = (try findStrategy(allocator, content, edits[i].old_str, edits[i].new_str)) orelse {
                failure_out.* = .{ .edit_index = i, .kind = .not_found };
                return error.NotFound;
            };
            defer freeStrategy(allocator, s);
            if (s.base_owned) any_fuzzy = true;
        }
    }

    const base: []const u8 = if (any_fuzzy)
        try fuzzyNormalize(allocator, content)
    else
        content;
    const base_owned = any_fuzzy;
    errdefer if (base_owned) allocator.free(base);

    // Match each edit against `base`, collecting strategies that
    // we'll apply right-to-left after sorting + overlap-checking.
    var matches: std.ArrayList(MatchedEdit) = .empty;
    defer matches.deinit(allocator);
    var owned_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }

    for (edits, 0..) |e, idx| {
        const s = (try findStrategy(allocator, base, e.old_str, e.new_str)) orelse {
            failure_out.* = .{ .edit_index = idx, .kind = .not_found };
            return error.NotFound;
        };
        // Carry the slice; freeStrategy at end-of-fn would invalidate.
        if (s.base_owned) allocator.free(s.base);
        if (s.free_search) try owned_strings.append(allocator, s.search);
        if (s.free_replace) try owned_strings.append(allocator, s.replace);

        const occ = countOccurrences(base, s.search);
        if (!e.replace_all and occ > 1) {
            failure_out.* = .{ .edit_index = idx, .kind = .ambiguous, .occurrences = occ };
            return error.Ambiguous;
        }
        try matches.append(allocator, .{
            .edit_index = idx,
            .match_index = s.index,
            .match_len = s.match_len,
            .occurrences = occ,
            .replace_str = s.replace,
            .search_str = s.search,
        });
    }

    // Sort by match_index ascending.
    std.mem.sort(MatchedEdit, matches.items, {}, struct {
        fn lt(_: void, a: MatchedEdit, b: MatchedEdit) bool {
            return a.match_index < b.match_index;
        }
    }.lt);

    // Overlap detection.
    var i: usize = 1;
    while (i < matches.items.len) : (i += 1) {
        const prev = matches.items[i - 1];
        const cur = matches.items[i];
        const prev_end = if (edits[prev.edit_index].replace_all)
            std.math.maxInt(usize)
        else
            prev.match_index + prev.match_len;
        if (prev_end > cur.match_index) {
            failure_out.* = .{ .edit_index = cur.edit_index, .kind = .overlap };
            return error.Overlap;
        }
    }

    // Apply right-to-left into a fresh buffer.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, base) catch return error.OutOfMemory;

    var j: usize = matches.items.len;
    while (j > 0) {
        j -= 1;
        const m = matches.items[j];
        if (edits[m.edit_index].replace_all) {
            // Whole-string replace_all on `out`.
            const before = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
            defer allocator.free(before);
            const replaced = std.mem.replaceOwned(u8, allocator, before, m.search_str, m.replace_str) catch
                return error.OutOfMemory;
            out = .empty;
            out.appendSlice(allocator, replaced) catch {
                allocator.free(replaced);
                return error.OutOfMemory;
            };
            allocator.free(replaced);
        } else {
            // Single replacement at m.match_index.
            const new_total = out.items.len - m.match_len + m.replace_str.len;
            var buf = allocator.alloc(u8, new_total) catch return error.OutOfMemory;
            @memcpy(buf[0..m.match_index], out.items[0..m.match_index]);
            @memcpy(buf[m.match_index..][0..m.replace_str.len], m.replace_str);
            const tail_src = m.match_index + m.match_len;
            @memcpy(buf[m.match_index + m.replace_str.len ..], out.items[tail_src..]);
            out.clearRetainingCapacity();
            out.appendSlice(allocator, buf) catch {
                allocator.free(buf);
                return error.OutOfMemory;
            };
            allocator.free(buf);
        }
    }

    const new_content = out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .base = base, .new_content = new_content };
}

// ── redaction guard ─────────────────────────────────────────────────

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

// Unified diff emission lives in `src/tui/components/diff.zig` now —
// proper Myers algorithm, real hunks, shared with any future UI that
// wants to display diffs.

// ── error formatting ────────────────────────────────────────────────
//
// `applyEdits` raises bare error tags (NotFound / Ambiguous / Overlap).
// The caller pairs each tag with the populated `EditFailure` to build
// a message the model can ACT ON: which edit failed, why, and a
// preview of the offending old_str so it can correct course.
//
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
