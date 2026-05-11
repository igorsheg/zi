//! Patch tool — apply Codex/OpenAI apply_patch style patches.
//!
//! Production shape: parse -> plan all changes -> lock all affected paths in
//! deterministic order -> commit. Matching is line-oriented and follows the
//! opencode/Codex behavior: exact, rstrip, trim, then normalized punctuation.
//! Move commits are best-effort atomic: the destination is atomically written,
//! then the source is deleted; a delete failure may leave both files present.

const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const lock_registry = @import("lock_registry.zig");
const zio_fs = @import("../../zio/root.zig").file;
const diff_mod = @import("../../diff/document.zig");
const diff_unified = @import("../../diff/unified.zig");
const tool_result_details = @import("result_details.zig");
const json_value = @import("../../json/value.zig");

const SCHEMA =
    \\{"type":"object","properties":{"patchText":{"type":"string","description":"The full apply_patch text, including *** Begin Patch and *** End Patch markers."}},"required":["patchText"]}
;

const DESCRIPTION =
    "Apply a Codex/OpenAI apply_patch style patch to files in the workspace.\n\n" ++
    "Use this for manual code edits when producing a patch is clearer than exact string replacement.\n\n" ++
    "Patch format:\n" ++
    "*** Begin Patch\n" ++
    "*** Add File: path\n" ++
    "+new file content\n" ++
    "*** Update File: path\n" ++
    "@@ optional anchor text\n" ++
    " context line\n" ++
    "-removed line\n" ++
    "+added line\n" ++
    "*** Delete File: path\n" ++
    "*** End Patch\n\n" ++
    "Paths may be relative to the workspace cwd. The tool validates the whole patch before mutating files.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "patch",
        .description = DESCRIPTION,
        .label = "Apply Patch",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Apply Codex/OpenAI apply_patch style patches to files",
        .prompt_guidelines = &.{
            "Prefer patch for OpenAI GPT-5/Codex style manual code edits.",
            "Emit the complete patchText with *** Begin Patch and *** End Patch markers.",
            "Use Add File, Update File, and Delete File sections; prefix content lines with +, -, or space in Update File chunks.",
        },
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "patch" },
    };
}

const HunkTag = enum { add, delete, update };
const Line = struct { tag: u8, text: []const u8 };
const Hunk = struct { tag: HunkTag, path: []const u8, move_path: ?[]const u8 = null, lines: std.ArrayList(Line) = .empty };
const PlanTag = enum { add, delete, update, move };
const PlanChange = struct {
    tag: PlanTag,
    path: []const u8,
    dest_path: ?[]const u8 = null,
    old_content: ?[]u8 = null,
    new_content: ?[]u8 = null,
    old_text: ?[]u8 = null,
    new_text: ?[]u8 = null,
    permissions: ?std.Io.File.Permissions = null,
    fn deinit(self: *PlanChange, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.dest_path) |p| allocator.free(p);
        if (self.old_content) |c| allocator.free(c);
        if (self.new_content) |c| allocator.free(c);
        if (self.old_text) |c| allocator.free(c);
        if (self.new_text) |c| allocator.free(c);
    }
};

fn execute(raw_ctx: ?*anyopaque, allocator: std.mem.Allocator, tool_call_id: []const u8, args: std.json.Value, signal: protocol.Token, on_update: ?protocol.AgentToolUpdateCallback, update_ctx: ?*anyopaque) protocol.AgentToolExecution {
    return .{ .ready = executeSync(raw_ctx, allocator, tool_call_id, args, signal, on_update, update_ctx) };
}

fn executeSync(raw_ctx: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, args: std.json.Value, _: protocol.Token, _: ?protocol.AgentToolUpdateCallback, _: ?*anyopaque) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse return util.errorResult(allocator, "patch tool: missing context")));
    const patch_text = util.getString(args, "patchText") orelse return util.errorResult(allocator, "patch tool: missing 'patchText' argument");

    var hunks = parsePatch(allocator, patch_text) catch |err| return util.errorf(allocator, "patch parse failed: {s}", .{@errorName(err)});
    defer deinitHunks(allocator, &hunks);
    if (hunks.items.len == 0) return util.errorResult(allocator, "patch contained no file changes");

    var plan = buildPlan(allocator, ctx.cwd, hunks.items) catch |err| return util.errorf(allocator, "patch plan failed: {s}", .{@errorName(err)});
    defer deinitPlan(allocator, &plan);

    var lock_paths = collectLockPaths(allocator, plan.items) catch return util.errorResult(allocator, "patch tool: alloc failed");
    defer freeStringList(allocator, &lock_paths);
    sortStrings(lock_paths.items);

    var locks: std.ArrayList(*lock_registry.Entry) = .empty;
    defer {
        var i = locks.items.len;
        while (i > 0) : (i -= 1) lock_registry.global().release(locks.items[i - 1]);
        locks.deinit(allocator);
    }
    var previous_lock_path: ?[]const u8 = null;
    for (lock_paths.items) |p| {
        if (previous_lock_path) |prev| if (std.mem.eql(u8, prev, p)) continue;
        tryAcquireLock(allocator, &locks, p) catch return util.errorResult(allocator, "patch tool: failed to acquire file lock");
        previous_lock_path = p;
    }

    commitPlan(plan.items) catch |err| return util.errorf(allocator, "patch commit failed: {s}", .{@errorName(err)});

    return patchDiffResult(allocator, plan.items);
}

fn parsePatch(allocator: std.mem.Allocator, raw_text: []const u8) !std.ArrayList(Hunk) {
    const text = stripHeredoc(raw_text);
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer deinitHunks(allocator, &hunks);
    var in_patch = false;
    var saw_end = false;
    var current: ?Hunk = null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "*** Begin Patch")) {
            in_patch = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "*** End Patch")) {
            saw_end = true;
            break;
        }
        if (!in_patch) continue;
        if (std.mem.startsWith(u8, line, "*** Add File:")) {
            if (current) |h| try finishHunk(allocator, &hunks, h);
            current = .{ .tag = .add, .path = nonEmpty(std.mem.trim(u8, line[13..], " \t")) orelse return error.EmptyPath };
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Delete File:")) {
            if (current) |h| try finishHunk(allocator, &hunks, h);
            current = .{ .tag = .delete, .path = nonEmpty(std.mem.trim(u8, line[16..], " \t")) orelse return error.EmptyPath };
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Update File:")) {
            if (current) |h| try finishHunk(allocator, &hunks, h);
            current = .{ .tag = .update, .path = nonEmpty(std.mem.trim(u8, line[16..], " \t")) orelse return error.EmptyPath };
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Move to:")) {
            if (current) |*h| h.move_path = nonEmpty(std.mem.trim(u8, line[12..], " \t")) orelse return error.EmptyPath else return error.MoveWithoutFile;
            continue;
        }
        if (current) |*h| {
            switch (h.tag) {
                .delete => return error.MalformedDeleteFileLine,
                .add => {
                    if (std.mem.startsWith(u8, line, "@@") or std.mem.eql(u8, line, "*** End of File")) return error.MalformedAddFileLine;
                    if (line.len > 0 and line[0] == '+') try h.lines.append(allocator, .{ .tag = '+', .text = line[1..] }) else return error.MalformedAddFileLine;
                },
                .update => {
                    if (std.mem.startsWith(u8, line, "@@")) try h.lines.append(allocator, .{ .tag = '@', .text = std.mem.trim(u8, line[2..], " \t") }) else if (std.mem.eql(u8, line, "*** End of File")) try h.lines.append(allocator, .{ .tag = '$', .text = "" }) else if (line.len == 0) try h.lines.append(allocator, .{ .tag = ' ', .text = "" }) else if (line[0] == '+' or line[0] == '-' or line[0] == ' ') try h.lines.append(allocator, .{ .tag = line[0], .text = line[1..] }) else return error.MalformedPatchLine;
                },
            }
        } else return error.BodyBeforeFile;
    }
    if (current) |h| try finishHunk(allocator, &hunks, h);
    if (!in_patch) return error.MissingBeginPatch;
    if (!saw_end) return error.MissingEndPatch;
    return hunks;
}

fn finishHunk(allocator: std.mem.Allocator, hunks: *std.ArrayList(Hunk), h: Hunk) !void {
    if (h.path.len == 0) return error.EmptyPath;
    try hunks.append(allocator, h);
}
fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn stripHeredoc(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    const first = std.mem.trim(u8, trimmed[0..nl], " \t");
    const marker_start = std.mem.indexOf(u8, first, "<<") orelse return trimmed;
    const marker = std.mem.trim(u8, first[marker_start + 2 ..], " '\"");
    if (marker.len == 0) return trimmed;
    var end = trimmed.len;
    while (end > nl + 1) {
        const prev_nl = std.mem.lastIndexOfScalar(u8, trimmed[0..end], '\n') orelse break;
        const last = std.mem.trim(u8, trimmed[prev_nl + 1 .. end], " \t\r");
        if (std.mem.eql(u8, last, marker)) return trimmed[nl + 1 .. prev_nl];
        end = prev_nl;
    }
    return trimmed;
}

fn deinitHunks(allocator: std.mem.Allocator, hunks: *std.ArrayList(Hunk)) void {
    for (hunks.items) |*h| h.lines.deinit(allocator);
    hunks.deinit(allocator);
}

fn buildPlan(allocator: std.mem.Allocator, cwd: []const u8, hunks: []Hunk) !std.ArrayList(PlanChange) {
    var plan: std.ArrayList(PlanChange) = .empty;
    errdefer deinitPlan(allocator, &plan);
    for (hunks) |hunk| {
        const path = try util.resolvePath(allocator, hunk.path, cwd);
        switch (hunk.tag) {
            .add => {
                var change = PlanChange{ .tag = .add, .path = path };
                var appended = false;
                errdefer if (!appended) change.deinit(allocator);
                if (try exists(path)) return error.AddFileAlreadyExists;
                change.new_content = try collectAddedContent(allocator, hunk.lines.items);
                change.new_text = try allocator.dupe(u8, change.new_content.?);
                try plan.append(allocator, change);
                appended = true;
            },
            .delete => {
                var change = PlanChange{ .tag = .delete, .path = path };
                var appended = false;
                errdefer if (!appended) change.deinit(allocator);
                change.old_content = try readFileAlloc(allocator, path);
                change.old_text = try textWithoutBomNormalizeLf(allocator, change.old_content.?);
                try plan.append(allocator, change);
                appended = true;
            },
            .update => {
                var change = PlanChange{ .tag = .update, .path = path };
                var appended = false;
                errdefer if (!appended) change.deinit(allocator);
                change.old_content = try readFileAlloc(allocator, path);
                const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
                change.permissions = stat.permissions;
                change.old_text = try textWithoutBomNormalizeLf(allocator, change.old_content.?);
                change.new_text = try applyUpdate(allocator, change.old_text.?, hunk.lines.items);
                change.new_content = try restoreFileConventions(allocator, change.old_content.?, change.new_text.?);
                change.dest_path = if (hunk.move_path) |mp| try util.resolvePath(allocator, mp, cwd) else null;
                if (change.dest_path) |d| if (try exists(d)) return error.MoveDestinationAlreadyExists;
                change.tag = if (change.dest_path == null) .update else .move;
                try plan.append(allocator, change);
                appended = true;
            },
        }
    }
    return plan;
}

fn deinitPlan(allocator: std.mem.Allocator, plan: *std.ArrayList(PlanChange)) void {
    for (plan.items) |*c| c.deinit(allocator);
    plan.deinit(allocator);
}

fn exists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var input = try zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 16 * 1024 * 1024 });
    defer input.deinit(allocator);
    return try allocator.dupe(u8, input.bytes());
}

fn collectAddedContent(allocator: std.mem.Allocator, lines: []const Line) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var first = true;
    for (lines) |line| if (line.tag == '+') {
        if (!first) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line.text);
        first = false;
    } else if (line.tag != '@') return error.MalformedAddFileLine;
    return out.toOwnedSlice(allocator);
}

fn applyUpdate(allocator: std.mem.Allocator, original: []const u8, patch_lines: []const Line) ![]u8 {
    var original_lines = try splitLines(allocator, original);
    defer original_lines.deinit(allocator);
    const trailing_nl = original.len > 0 and original[original.len - 1] == '\n';
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);
    var cursor: usize = 0;
    var start: usize = 0;
    while (start < patch_lines.len) {
        var anchor: ?[]const u8 = null;
        var eof = false;
        if (patch_lines[start].tag == '@') {
            if (patch_lines[start].text.len > 0) anchor = patch_lines[start].text;
            start += 1;
        }
        var end = start;
        while (end < patch_lines.len and patch_lines[end].tag != '@') : (end += 1) {
            if (patch_lines[end].tag == '$') eof = true;
        }
        if (start == end) {
            start = end;
            continue;
        }
        var old_lines: std.ArrayList([]const u8) = .empty;
        defer old_lines.deinit(allocator);
        var new_lines: std.ArrayList([]const u8) = .empty;
        defer new_lines.deinit(allocator);
        for (patch_lines[start..end]) |line| switch (line.tag) {
            ' ' => {
                try old_lines.append(allocator, line.text);
                try new_lines.append(allocator, line.text);
            },
            '-' => try old_lines.append(allocator, line.text),
            '+' => try new_lines.append(allocator, line.text),
            '$' => {},
            else => return error.MalformedPatchLine,
        };
        if (old_lines.items.len == 0) return error.EmptyUpdateChunk;
        var search_from = cursor;
        if (anchor) |a| {
            if (seekSequence(original_lines.items, &.{a}, search_from, false)) |idx| {
                search_from = idx + 1;
            } else return error.ContextNotFound;
        }
        const found = seekSequence(original_lines.items, old_lines.items, search_from, eof) orelse return error.ExpectedLinesNotFound;
        if (found < cursor) return error.OverlappingPatchChunks;
        try replacements.append(allocator, .{ .start = found, .old_len = old_lines.items.len, .new_lines = try allocator.dupe([]const u8, new_lines.items) });
        cursor = found + old_lines.items.len;
        start = end;
    }
    defer for (replacements.items) |r| allocator.free(r.new_lines);
    return joinWithReplacements(allocator, original_lines.items, replacements.items, trailing_nl);
}

const Replacement = struct { start: usize, old_len: usize, new_lines: []const []const u8 };

fn splitLines(allocator: std.mem.Allocator, bytes: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (it.index == null and line.len == 0) break;
        try lines.append(allocator, line);
    }
    return lines;
}

fn seekSequence(lines: []const []const u8, pattern: []const []const u8, start: usize, eof: bool) ?usize {
    if (pattern.len == 0 or pattern.len > lines.len) return null;
    if (eof) {
        const from_end = lines.len - pattern.len;
        if (from_end >= start and matchAt(lines, pattern, from_end)) return from_end;
    }
    var i = start;
    while (i + pattern.len <= lines.len) : (i += 1) if (matchAt(lines, pattern, i)) return i;
    return null;
}

fn matchAt(lines: []const []const u8, pattern: []const []const u8, at: usize) bool {
    const Mode = enum { exact, rstrip, trim, normalized };
    inline for (.{ Mode.exact, Mode.rstrip, Mode.trim, Mode.normalized }) |mode| {
        var ok = true;
        for (pattern, 0..) |p, j| if (!lineEqual(lines[at + j], p, mode)) {
            ok = false;
            break;
        };
        if (ok) return true;
    }
    return false;
}

fn trimRight(comptime T: type, slice: []const T, values: []const T) []const T {
    var end = slice.len;
    while (end > 0 and std.mem.indexOfScalar(T, values, slice[end - 1]) != null) end -= 1;
    return slice[0..end];
}

fn lineEqual(a: []const u8, b: []const u8, comptime mode: anytype) bool {
    return switch (mode) {
        .exact => std.mem.eql(u8, a, b),
        .rstrip => std.mem.eql(u8, trimRight(u8, a, " \t"), trimRight(u8, b, " \t")),
        .trim => std.mem.eql(u8, std.mem.trim(u8, a, " \t"), std.mem.trim(u8, b, " \t")),
        .normalized => normalizedEqual(std.mem.trim(u8, a, " \t"), std.mem.trim(u8, b, " \t")),
    };
}

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < a.len and ib < b.len) {
        const na = normalizedToken(a[ia..]);
        const nb = normalizedToken(b[ib..]);
        if (!std.mem.eql(u8, na.text, nb.text)) return false;
        ia += na.len;
        ib += nb.len;
    }
    return ia == a.len and ib == b.len;
}
const Token = struct { text: []const u8, len: usize };
fn normalizedToken(s: []const u8) Token {
    const reps = [_]struct { bytes: []const u8, repl: []const u8 }{
        .{ .bytes = "\xE2\x80\x98", .repl = "'" },   .{ .bytes = "\xE2\x80\x99", .repl = "'" },
        .{ .bytes = "\xE2\x80\x9C", .repl = "\"" },  .{ .bytes = "\xE2\x80\x9D", .repl = "\"" },
        .{ .bytes = "\xE2\x80\x93", .repl = "-" },   .{ .bytes = "\xE2\x80\x94", .repl = "-" },
        .{ .bytes = "\xE2\x80\xA6", .repl = "..." }, .{ .bytes = "\xC2\xA0", .repl = " " },
    };
    for (reps) |r| if (std.mem.startsWith(u8, s, r.bytes)) return .{ .text = r.repl, .len = r.bytes.len };
    return .{ .text = s[0..1], .len = 1 };
}

fn joinWithReplacements(allocator: std.mem.Allocator, lines: []const []const u8, replacements: []const Replacement, trailing_nl: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (replacements) |r| {
        try appendLines(&out, allocator, lines[cursor..r.start], true);
        try appendLines(&out, allocator, r.new_lines, true);
        cursor = r.start + r.old_len;
    }
    try appendLines(&out, allocator, lines[cursor..], trailing_nl);
    return out.toOwnedSlice(allocator);
}

fn appendLines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lines: []const []const u8, append_final_nl: bool) !void {
    for (lines, 0..) |line, i| {
        try out.appendSlice(allocator, line);
        if (i + 1 < lines.len or append_final_nl) try out.append(allocator, '\n');
    }
}

fn collectLockPaths(allocator: std.mem.Allocator, plan: []const PlanChange) !std.ArrayList([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, &paths);
    for (plan) |c| {
        try paths.append(allocator, try allocator.dupe(u8, c.path));
        if (c.dest_path) |p| try paths.append(allocator, try allocator.dupe(u8, p));
    }
    return paths;
}
fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}
fn sortStrings(items: [][]u8) void {
    std.mem.sort([]u8, items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}
fn tryAcquireLock(allocator: std.mem.Allocator, locks: *std.ArrayList(*lock_registry.Entry), path: []const u8) !void {
    try locks.append(allocator, try lock_registry.global().acquirePath(allocator, path));
}

fn hasUtf8Bom(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF;
}

fn textWithoutBomNormalizeLf(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const text = if (hasUtf8Bom(bytes)) bytes[3..] else bytes;
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return allocator.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') continue;
        }
        try out.append(allocator, text[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn restoreFileConventions(allocator: std.mem.Allocator, old_raw: []const u8, new_lf_text: []const u8) ![]u8 {
    const use_crlf = dominantLineEnding(old_raw) == .crlf;
    const with_eol = if (use_crlf) try restoreCrlf(allocator, new_lf_text) else try allocator.dupe(u8, new_lf_text);
    defer allocator.free(with_eol);
    if (!hasUtf8Bom(old_raw)) return allocator.dupe(u8, with_eol);
    var out = try allocator.alloc(u8, with_eol.len + 3);
    out[0] = 0xEF;
    out[1] = 0xBB;
    out[2] = 0xBF;
    @memcpy(out[3..], with_eol);
    return out;
}

const Eol = enum { lf, crlf };
fn dominantLineEnding(bytes: []const u8) Eol {
    var lf: usize = 0;
    var crlf: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            lf += 1;
            if (i > 0 and bytes[i - 1] == '\r') crlf += 1;
        }
    }
    return if (crlf > 0 and crlf * 2 >= lf) .crlf else .lf;
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

fn patchDiffResult(allocator: std.mem.Allocator, plan: []const PlanChange) protocol.AgentToolResult {
    var inputs = std.ArrayList(diff_mod.Input).empty;
    defer inputs.deinit(allocator);
    for (plan) |c| {
        const old_text = c.old_text orelse "";
        const new_text = c.new_text orelse "";
        const new_path = c.dest_path orelse c.path;
        inputs.append(allocator, .{
            .old_path = std.fs.path.basename(c.path),
            .new_path = std.fs.path.basename(new_path),
            .old_text = old_text,
            .new_text = new_text,
        }) catch return util.errorResult(allocator, "patch diff alloc failed");
    }
    var doc = diff_mod.buildDocument(allocator, inputs.items, .{}) catch |err| return util.errorf(allocator, "patch diff failed: {s}", .{@errorName(err)});
    defer doc.deinit();
    const details = tool_result_details.diffToJsonValue(allocator, doc.document) catch return util.errorResult(allocator, "patch diff details serialize failed");
    var unified = diff_unified.toUnified(allocator, doc.document) catch {
        json_value.freeJsonValue(allocator, details);
        return util.errorResult(allocator, "patch diff serialize failed");
    };
    unified = truncateOwnedText(allocator, unified) catch {
        json_value.freeJsonValue(allocator, details);
        allocator.free(unified);
        return util.errorResult(allocator, "patch diff truncate failed");
    };
    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch {
        json_value.freeJsonValue(allocator, details);
        allocator.free(unified);
        return util.errorResult(allocator, "alloc failed");
    };
    blocks[0] = .{ .text = .{ .text = unified } };
    return .{ .content = blocks, .details = details, .is_error = false };
}

fn truncateOwnedText(allocator: std.mem.Allocator, owned: []u8) ![]u8 {
    if (owned.len <= util.Limits.text_result_bytes) return owned;
    const marker = "\n... [patch diff truncated at 64KiB safety cap] ...";
    const marker_len = @min(marker.len, util.Limits.text_result_bytes);
    const prefix_len = util.Limits.text_result_bytes - marker_len;
    const truncated = try allocator.alloc(u8, util.Limits.text_result_bytes);
    @memcpy(truncated[0..prefix_len], owned[0..prefix_len]);
    @memcpy(truncated[prefix_len..], marker[0..marker_len]);
    allocator.free(owned);
    return truncated;
}

fn commitPlan(plan: []const PlanChange) !void {
    for (plan) |c| switch (c.tag) {
        .add => {
            if (std.fs.path.dirname(c.path)) |p| try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, p);
            try writeFileAtomic(c.path, c.new_content.?, null);
        },
        .delete => try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, c.path),
        .update => try writeFileAtomic(c.path, c.new_content.?, c.permissions),
        .move => {
            if (std.fs.path.dirname(c.dest_path.?)) |p| try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, p);
            try writeFileAtomic(c.dest_path.?, c.new_content.?, c.permissions);
            try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, c.path);
        },
    };
}

fn writeFileAtomic(path: []const u8, content: []const u8, permissions: ?std.Io.File.Permissions) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(std.Options.debug_io, path, .{ .permissions = permissions orelse .fromMode(0o666), .replace = true });
    defer atomic_file.deinit(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try atomic_file.file.sync(std.Options.debug_io);
    try atomic_file.replace(std.Options.debug_io);
}

test "parse heredoc apply_patch update" {
    const allocator = std.testing.allocator;
    var hunks = try parsePatch(allocator, "cat <<'PATCH'\n*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch\nPATCH");
    defer deinitHunks(allocator, &hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqual(HunkTag.update, hunks.items[0].tag);
    try std.testing.expectEqualStrings("a.txt", hunks.items[0].path);
}

test "apply update replaces expected block" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{ .{ .tag = ' ', .text = "a" }, .{ .tag = '-', .text = "b" }, .{ .tag = '+', .text = "c" } };
    const out = try applyUpdate(allocator, "a\nb\nd\n", &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\nc\nd\n", out);
}

test "apply update uses rstrip matching" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{ .{ .tag = '-', .text = "b" }, .{ .tag = '+', .text = "c" } };
    const out = try applyUpdate(allocator, "a\nb   \nd\n", &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\nc\nd\n", out);
}

test "apply update supports anchors and multiple chunks" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{
        .{ .tag = '@', .text = "section one" }, .{ .tag = '-', .text = "old1" }, .{ .tag = '+', .text = "new1" },
        .{ .tag = '@', .text = "section two" }, .{ .tag = '-', .text = "old2" }, .{ .tag = '+', .text = "new2" },
    };
    const out = try applyUpdate(allocator, "section one\nold1\nsection two\nold2\n", &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("section one\nnew1\nsection two\nnew2\n", out);
}

test "apply update supports EOF matching" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{ .{ .tag = '-', .text = "tail" }, .{ .tag = '+', .text = "done" }, .{ .tag = '$', .text = "" } };
    const out = try applyUpdate(allocator, "tail\nmid\ntail\n", &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("tail\nmid\ndone\n", out);
}

test "apply update uses unicode punctuation normalization" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{ .{ .tag = '-', .text = "say \"hello\" - now" }, .{ .tag = '+', .text = "ok" } };
    const out = try applyUpdate(allocator, "say “hello” — now\n", &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok\n", out);
}

test "add file allows explicit blank plus lines" {
    const allocator = std.testing.allocator;
    const lines = [_]Line{ .{ .tag = '+', .text = "a" }, .{ .tag = '+', .text = "" }, .{ .tag = '+', .text = "b" } };
    const out = try collectAddedContent(allocator, &lines);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\n\nb", out);
}

test "restore preserves CRLF" {
    const allocator = std.testing.allocator;
    const out = try restoreFileConventions(allocator, "a\r\nb\r\n", "a\nc\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\r\nc\r\n", out);
}

test "restore preserves UTF-8 BOM" {
    const allocator = std.testing.allocator;
    const out = try restoreFileConventions(allocator, "\xEF\xBB\xBFa\n", "b\n");
    defer allocator.free(out);
    try std.testing.expectEqual(@as(u8, 0xEF), out[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), out[1]);
    try std.testing.expectEqual(@as(u8, 0xBF), out[2]);
    try std.testing.expectEqualStrings("b\n", out[3..]);
}

test "patch diff result returns unified diff" {
    const allocator = std.testing.allocator;
    var change = PlanChange{
        .tag = .update,
        .path = try allocator.dupe(u8, "/tmp/a.txt"),
        .old_text = try allocator.dupe(u8, "a\nb\n"),
        .new_text = try allocator.dupe(u8, "a\nc\n"),
    };
    defer change.deinit(allocator);
    var result = patchDiffResult(allocator, &.{change});
    defer result.free(allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "--- a.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "+++ a.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "+c\n") != null);
}
