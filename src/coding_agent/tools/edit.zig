const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const diff_mod = @import("../../diff/document.zig");
const diff_unified = @import("../../diff/unified.zig");
const tool_result_details = @import("result_details.zig");
const lock_registry = @import("lock_registry.zig");
const json_value = @import("../../json/value.zig");
const zio_fs = @import("../../zio/root.zig").file;
const anchors = @import("anchors.zig");
const observations = @import("observations.zig");
const file_mutation = @import("file_mutation.zig");

const SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The absolute path to the file (MUST be absolute, not relative). File must exist and must have been observed with read or grep."},"edits":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after"]},"start":{"type":"string"},"end":{"type":"string"},"anchor":{"type":"string"},"content":{"type":"string"}},"required":["op","content"]},"description":"Anchor-addressed edits. replace requires start and end. insert_before/insert_after require anchor."}},"required":["path","edits"]}
;

const DESCRIPTION =
    "Make anchor-addressed edits to a text file.\n\n" ++
    "This is the only edit contract. Legacy old_str/new_str/replace_all are not accepted.\n\n" ++
    "The file must first be observed with read or grep. Anchors come from read/grep output and have the form LINE:HASH, for example `42:a9f1`.\n\n" ++
    "Operations: replace(start,end,content), insert_before(anchor,content), insert_after(anchor,content).\n\n" ++
    "All edits are validated against the original file and applied atomically. Overlapping edits fail before mutation.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "edit",
        .description = DESCRIPTION,
        .label = "Edit File",
        .display_call = "path",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Make precise file edits using anchors from read/grep output",
        .prompt_guidelines = &.{
            "Use edit with anchors from read/grep output; old_str/new_str are invalid.",
            "Read or grep the file before editing so zi can validate the observed version.",
            "Batch disjoint edits in one call; overlapping edits are rejected.",
        },
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "edit" },
    };
}

const OpTag = enum { replace, insert_before, insert_after };
const EditOp = struct {
    tag: OpTag,
    start: anchors.Anchor,
    end: ?anchors.Anchor = null,
    content: []const u8,
    input_index: usize,
};
const Replacement = struct { start: usize, end: usize, content: []const u8, input_index: usize };

fn execute(raw_ctx: ?*anyopaque, allocator: std.mem.Allocator, tool_call_id: []const u8, args: std.json.Value, signal: protocol.Token, on_update: ?protocol.AgentToolUpdateCallback, update_ctx: ?*anyopaque) protocol.AgentToolExecution {
    _ = tool_call_id;
    _ = signal;
    _ = on_update;
    _ = update_ctx;
    return .{ .ready = executeSync(raw_ctx, allocator, args) };
}

fn executeSync(raw_ctx: ?*anyopaque, allocator: std.mem.Allocator, args: std.json.Value) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse return util.errorResult(allocator, "edit tool: missing context")));
    const path = util.getString(args, "path") orelse return util.errorResult(allocator, "edit tool: missing 'path' argument");
    const resolved = util.resolvePath(allocator, path, ctx.cwd) catch return util.errorResult(allocator, "edit tool: failed to resolve path");
    defer allocator.free(resolved);

    const lock_entry = lock_registry.global().acquirePath(allocator, resolved) catch return util.errorResult(allocator, "edit tool: failed to acquire file lock");
    defer lock_registry.global().release(lock_entry);

    const validation = ctx.observations.validateFile(allocator, resolved) catch .path_not_comparable;
    switch (validation) {
        .ok, .refreshed_metadata => {},
        else => return util.errorf(allocator, "{s}: {s}", .{ observations.validationMessage(validation, "edit", resolved), resolved }),
    }

    var ops = parseOps(allocator, args) catch |err| return util.errorf(allocator, "edit tool: invalid edits: {s}", .{@errorName(err)});
    defer ops.deinit(allocator);
    if (ops.items.len == 0) return util.errorResult(allocator, "edit tool: edits must not be empty");

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, resolved, .{}) catch |err| return util.errorf(allocator, "edit tool: stat failed: {s}", .{@errorName(err)});
    var input = zio_fs.readOnlyBytes(std.Options.debug_io, allocator, resolved, .{ .max_bytes = 16 * 1024 * 1024 }) catch |err| return util.errorf(allocator, "edit tool: read failed: {s}", .{@errorName(err)});
    defer input.deinit(allocator);
    const raw = input.bytes();
    const ending = detectLineEnding(raw);
    const normalized = normalizeToLfDup(allocator, raw) catch return util.errorResult(allocator, "alloc failed");
    defer allocator.free(normalized);

    var replacements = resolveOps(allocator, normalized, ops.items) catch |err| return formatAnchorError(allocator, err, normalized, ops.items);
    defer replacements.deinit(allocator);
    const new_content = applyReplacements(allocator, normalized, replacements.items) catch |err| return util.errorf(allocator, "edit tool: apply failed: {s}", .{@errorName(err)});
    defer allocator.free(new_content);
    if (std.mem.eql(u8, normalized, new_content)) return util.errorResult(allocator, "no changes made — edit produced identical content");

    const final_bytes = if (ending == .crlf) restoreCrlf(allocator, new_content) catch return util.errorResult(allocator, "alloc failed") else allocator.dupe(u8, new_content) catch return util.errorResult(allocator, "alloc failed");
    defer allocator.free(final_bytes);
    file_mutation.atomicWrite(resolved, final_bytes, stat.permissions) catch return util.errorResult(allocator, "edit tool: write failed");
    ctx.observation_events.recordFile(allocator, resolved, .edit) catch {};

    const inputs = [_]diff_mod.Input{.{ .old_path = std.fs.path.basename(resolved), .new_path = std.fs.path.basename(resolved), .old_text = normalized, .new_text = new_content }};
    var doc = diff_mod.buildDocument(allocator, &inputs, .{}) catch |err| return util.errorf(allocator, "diff failed: {s}", .{@errorName(err)});
    defer doc.deinit();
    const details = tool_result_details.diffToJsonValue(allocator, doc.document) catch return util.errorResult(allocator, "diff details serialize failed");
    errdefer json_value.freeJsonValue(allocator, details);
    var unified = diff_unified.toUnified(allocator, doc.document) catch return util.errorResult(allocator, "diff serialize failed");
    errdefer allocator.free(unified);
    if (unified.len > util.Limits.text_result_bytes) {
        const marker = "\n... [edit diff truncated at 64KiB safety cap] ...";
        const prefix_len = util.Limits.text_result_bytes - @min(marker.len, util.Limits.text_result_bytes);
        const truncated = allocator.alloc(u8, util.Limits.text_result_bytes) catch return util.errorResult(allocator, "alloc failed");
        @memcpy(truncated[0..prefix_len], unified[0..prefix_len]);
        @memcpy(truncated[prefix_len..], marker[0 .. util.Limits.text_result_bytes - prefix_len]);
        allocator.free(unified);
        unified = truncated;
    }
    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch {
        json_value.freeJsonValue(allocator, details);
        return util.errorResult(allocator, "alloc failed");
    };
    blocks[0] = .{ .text = .{ .text = unified } };
    return .{ .content = blocks, .details = details };
}

fn parseOps(allocator: std.mem.Allocator, args: std.json.Value) !std.ArrayList(EditOp) {
    const obj = if (args == .object) args.object else return error.BadArgs;
    if (obj.get("old_str") != null or obj.get("new_str") != null or obj.get("replace_all") != null) return error.LegacyEditFieldsForbidden;
    const arr = (obj.get("edits") orelse return error.MissingEdits).array;
    var out: std.ArrayList(EditOp) = .empty;
    errdefer out.deinit(allocator);
    for (arr.items, 0..) |item, i| {
        const eo = if (item == .object) item.object else return error.BadEdit;
        const op_s = (eo.get("op") orelse return error.MissingOp).string;
        const content = (eo.get("content") orelse return error.MissingContent).string;
        if (std.ascii.indexOfIgnoreCase(content, "[REDACTED]") != null or std.ascii.indexOfIgnoreCase(content, "... existing code") != null) return error.RedactionMarker;
        if (std.mem.eql(u8, op_s, "replace")) {
            try out.append(allocator, .{ .tag = .replace, .start = try anchors.parse((eo.get("start") orelse return error.MissingStart).string), .end = try anchors.parse((eo.get("end") orelse return error.MissingEnd).string), .content = content, .input_index = i });
        } else if (std.mem.eql(u8, op_s, "insert_before")) {
            try out.append(allocator, .{ .tag = .insert_before, .start = try anchors.parse((eo.get("anchor") orelse return error.MissingAnchor).string), .content = content, .input_index = i });
        } else if (std.mem.eql(u8, op_s, "insert_after")) {
            try out.append(allocator, .{ .tag = .insert_after, .start = try anchors.parse((eo.get("anchor") orelse return error.MissingAnchor).string), .content = content, .input_index = i });
        } else return error.UnknownOp;
    }
    return out;
}

fn resolveOps(allocator: std.mem.Allocator, content: []const u8, ops: []const EditOp) !std.ArrayList(Replacement) {
    var reps: std.ArrayList(Replacement) = .empty;
    errdefer reps.deinit(allocator);
    for (ops) |op| {
        switch (op.tag) {
            .replace => {
                const a = try anchors.resolve(content, op.start);
                const b = try anchors.resolve(content, op.end.?);
                if (b.end < a.start) return error.RangeOrder;
                try reps.append(allocator, .{ .start = a.start, .end = b.end, .content = op.content, .input_index = op.input_index });
            },
            .insert_before => {
                const a = try anchors.resolve(content, op.start);
                try reps.append(allocator, .{ .start = a.start, .end = a.start, .content = op.content, .input_index = op.input_index });
            },
            .insert_after => {
                const a = try anchors.resolve(content, op.start);
                try reps.append(allocator, .{ .start = a.next, .end = a.next, .content = op.content, .input_index = op.input_index });
            },
        }
    }
    std.mem.sort(Replacement, reps.items, {}, struct {
        fn lt(_: void, a: Replacement, b: Replacement) bool {
            return if (a.start == b.start) a.input_index < b.input_index else a.start < b.start;
        }
    }.lt);
    var i: usize = 1;
    while (i < reps.items.len) : (i += 1) if (reps.items[i - 1].end > reps.items[i].start) return error.Overlap;
    return reps;
}

fn applyReplacements(allocator: std.mem.Allocator, base: []const u8, reps: []const Replacement) ![]u8 {
    var final_len = base.len;
    for (reps) |r| final_len = final_len - (r.end - r.start) + r.content.len;
    std.debug.assert(final_len <= base.len + blk: {
        var added: usize = 0;
        for (reps) |r| added += r.content.len;
        break :blk added;
    });
    var out = try allocator.alloc(u8, final_len);
    var src: usize = 0;
    var dst: usize = 0;
    for (reps) |r| {
        @memcpy(out[dst..][0 .. r.start - src], base[src..r.start]);
        dst += r.start - src;
        @memcpy(out[dst..][0..r.content.len], r.content);
        dst += r.content.len;
        src = r.end;
    }
    @memcpy(out[dst..][0 .. base.len - src], base[src..]);
    return out;
}

fn formatAnchorError(allocator: std.mem.Allocator, err: anyerror, content: []const u8, ops: []const EditOp) protocol.AgentToolResult {
    if (err == error.StaleAnchor) {
        for (ops) |op| {
            const candidates = anchors.findCandidates(allocator, content, op.start.hash, 8) catch &.{};
            defer if (candidates.len > 0) allocator.free(candidates);
            if (candidates.len > 0) {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                errdefer aw.deinit();
                aw.writer.print("edit rejected: stale anchor {d}:{x:0>4}\ncandidate anchors:\n", .{ op.start.line, op.start.hash }) catch {};
                for (candidates) |c| aw.writer.print("{d}:{x:0>4}\n", .{ c.line, c.hash }) catch {};
                return util.ownedTextResult(allocator, aw.toOwnedSlice() catch return util.errorResult(allocator, "stale anchor"), true);
            }
        }
        return util.errorResult(allocator, "edit rejected: stale anchor no longer exists. read the file again before editing.");
    }
    return util.errorf(allocator, "edit rejected: {s}", .{@errorName(err)});
}

const LineEnding = enum { lf, crlf };
fn detectLineEnding(s: []const u8) LineEnding {
    return if (std.mem.indexOf(u8, s, "\r\n") != null) .crlf else .lf;
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
    var nl: usize = 0;
    for (s) |c| {
        if (c == '\n') nl += 1;
    }
    var out = try allocator.alloc(u8, s.len + nl);
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
