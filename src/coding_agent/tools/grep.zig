//! Grep tool — ripgrep wrapper with structured output and tight limits.
//!
//! pi-mono parity: ports `grep.ts`. Spawns `rg --json` and parses
//! match/context events line by line. Differences from pi's stock built-in:
//! - per-file match limit (10) so one noisy file can't blow the budget
//! - 200-char line cap on every match line
//! - ±1 lines of surrounding context (rg --context 1)
//! - case-sensitive by default, override with `caseSensitive: false`
//! - `literal: true` for fixed-string mode; otherwise rust-flavored regex

const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const runtime_process = @import("../../zio/root.zig").process;

/// Hard cap on matches we ever return to the model. Both collection
/// and rendering enforce it; the constants used to be split (collect
/// 200, advertise 100) which meant we could ship 200 results while
/// claiming 100 — oracle review caught it. Single source of truth now.
const MAX_TOTAL_MATCHES: usize = 100;
const MAX_PER_FILE: usize = 10;
const MAX_LINE_CHARS: usize = 200;

const SCHEMA =
    \\{"type":"object","properties":{
    \\"pattern":{"type":"string","description":"The pattern to search for (regex by default)."},
    \\"path":{"type":"string","description":"The file or directory path to search in."},
    \\"glob":{"type":"string","description":"Glob filter (e.g., '**/*.ts'). Cannot be used with path."},
    \\"caseSensitive":{"type":"boolean","description":"Case-sensitive (default true)."},
    \\"literal":{"type":"boolean","description":"Treat pattern as a literal string."}
    \\},"required":["pattern"]}
;

const DESCRIPTION =
    "Search for exact text patterns in files using ripgrep, a fast keyword search tool.\n\n" ++
    "# When to use\n- Finding exact text matches (variable names, function calls, specific strings)\n\n" ++
    "# Constraints\n" ++
    "- Results are limited to 100 matches (up to 10 per file)\n" ++
    "- Lines are truncated at 200 characters\n\n" ++
    "# Strategy\n" ++
    "- Use 'path' or 'glob' to narrow searches; run multiple focused calls rather than one broad search\n" ++
    "- Uses Rust-style regex (escape `{` and `}`); use `literal: true` for literal text search\n";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "grep",
        .description = DESCRIPTION,
        .label = "Grep",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Search file contents for patterns (respects .gitignore)",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "grep" },
    };
}

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: protocol.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolExecution {
    return .{ .ready = executeSync(raw_ctx, allocator, tool_call_id, args, signal, on_update, update_ctx) };
}

fn executeSync(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    signal: protocol.Token,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "grep tool: missing context")));

    const pattern = util.getString(args, "pattern") orelse
        return util.errorResult(allocator, "grep tool: missing 'pattern' argument");

    const search_path: []const u8 = blk: {
        if (util.getString(args, "path")) |p| {
            if (std.fs.path.isAbsolute(p)) break :blk allocator.dupe(u8, p) catch
                return util.errorResult(allocator, "alloc failed");
            break :blk std.fs.path.resolve(allocator, &.{ ctx.cwd, p }) catch
                return util.errorResult(allocator, "alloc failed");
        }
        break :blk allocator.dupe(u8, ctx.cwd) catch
            return util.errorResult(allocator, "alloc failed");
    };
    defer allocator.free(search_path);

    const case_sensitive = util.getBool(args, "caseSensitive") orelse true;
    const literal = util.getBool(args, "literal") orelse false;
    const glob = util.getString(args, "glob");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "rg") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "--json") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "--line-number") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "--color=never") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "--hidden") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "--context") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, "1") catch return util.errorResult(allocator, "alloc failed");
    if (!case_sensitive) argv.append(allocator, "--ignore-case") catch return util.errorResult(allocator, "alloc failed");
    if (literal) argv.append(allocator, "--fixed-strings") catch return util.errorResult(allocator, "alloc failed");
    if (glob) |g| {
        argv.append(allocator, "--glob") catch return util.errorResult(allocator, "alloc failed");
        argv.append(allocator, g) catch return util.errorResult(allocator, "alloc failed");
    }
    argv.append(allocator, "--") catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, pattern) catch return util.errorResult(allocator, "alloc failed");
    argv.append(allocator, search_path) catch return util.errorResult(allocator, "alloc failed");

    var proc_result = runtime_process.run(allocator, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(util.Limits.process_stdout_bytes),
        .stderr = .ignore,
        .kill_scope = .process_group,
        .signal = signal,
    }) catch |err| return util.errorf(allocator, "grep error: {s}", .{@errorName(err)});
    defer proc_result.deinit(allocator);

    const completed = switch (proc_result) {
        .completed => |completed| completed,
        .timed_out => return util.errorResult(allocator, "grep timed out"),
        .aborted => return util.errorResult(allocator, "grep aborted"),
        .stdout_too_long, .stderr_too_long => |err| return util.errorf(allocator, "grep error: {s}", .{err.message}),
    };
    const exited_code: u8 = switch (completed.term) {
        .exited => |c| c,
        else => 2,
    };
    const stdout = completed.stdout;
    if (exited_code != 0 and exited_code != 1) {
        return util.errorf(allocator, "ripgrep exited with code {d}", .{exited_code});
    }

    return parseRgJson(allocator, stdout, search_path);
}

const RgEvent = struct {
    kind: enum { match, context },
    file_path: []const u8,
    line_number: u64,
    line_text: []const u8,
};

fn parseRgJson(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    base_path: []const u8,
) protocol.AgentToolResult {
    var events: std.ArrayList(RgEvent) = .empty;
    defer {
        for (events.items) |e| {
            allocator.free(e.file_path);
            allocator.free(e.line_text);
        }
        events.deinit(allocator);
    }
    var total_matches: usize = 0;

    var line_it = std.mem.splitScalar(u8, stdout, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const ty_v = obj.get("type") orelse continue;
        const ty = switch (ty_v) {
            .string => |s| s,
            else => continue,
        };
        const kind: @TypeOf(@as(RgEvent, undefined).kind) =
            if (std.mem.eql(u8, ty, "match")) .match else if (std.mem.eql(u8, ty, "context")) .context else continue;
        const data = switch (obj.get("data") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const path_obj = switch (data.get("path") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const path_str = switch (path_obj.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const ln = switch (data.get("line_number") orelse continue) {
            .integer => |i| @as(u64, @intCast(i)),
            else => continue,
        };
        const lines_obj = switch (data.get("lines") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const text_str = switch (lines_obj.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const text_trimmed = std.mem.trimEnd(u8, text_str, "\r\n");

        const kept_text = text_trimmed[0..@min(text_trimmed.len, MAX_LINE_CHARS + 1)];
        events.append(allocator, .{
            .kind = kind,
            .file_path = allocator.dupe(u8, path_str) catch continue,
            .line_number = ln,
            .line_text = allocator.dupe(u8, kept_text) catch continue,
        }) catch continue;

        if (kind == .match) total_matches += 1;
        if (total_matches >= MAX_TOTAL_MATCHES) break;
    }

    if (total_matches == 0) {
        return util.textResult(allocator, "no matches found");
    }

    var per_file_count = std.StringHashMap(usize).init(allocator);
    defer per_file_count.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    var current_file: []const u8 = "";
    var current_display: []const u8 = "";
    var current_display_owned: ?[]u8 = null;
    defer if (current_display_owned) |buf| allocator.free(buf);
    var first_file = true;
    var files_at_limit: usize = 0;

    var i: usize = 0;
    while (i < events.items.len) : (i += 1) {
        const ev = events.items[i];
        const file_changed = !std.mem.eql(u8, ev.file_path, current_file);
        if (file_changed) {
            current_file = ev.file_path;
            if (!first_file) w.writeAll("\n") catch break;
            first_file = false;

            if (current_display_owned) |buf| {
                allocator.free(buf);
                current_display_owned = null;
            }
            const rel = std.fs.path.relative(allocator, base_path, null, base_path, ev.file_path) catch null;
            if (rel) |r| {
                if (r.len > 0 and !std.mem.startsWith(u8, r, "..")) {
                    current_display = r;
                    current_display_owned = r;
                } else {
                    allocator.free(r);
                    current_display = std.fs.path.basename(ev.file_path);
                }
            } else {
                current_display = std.fs.path.basename(ev.file_path);
            }
        }

        if (ev.kind == .match) {
            const gop = per_file_count.getOrPut(ev.file_path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > MAX_PER_FILE) {
                if (gop.value_ptr.* == MAX_PER_FILE + 1) files_at_limit += 1;
                continue;
            }
        }

        const text_show = if (ev.line_text.len > MAX_LINE_CHARS)
            ev.line_text[0..MAX_LINE_CHARS]
        else
            ev.line_text;
        const ellipsis = if (ev.line_text.len > MAX_LINE_CHARS) "..." else "";

        w.print("{s}:{d}: {s}{s}\n", .{ current_display, ev.line_number, text_show, ellipsis }) catch break;
    }

    if (total_matches >= MAX_TOTAL_MATCHES) {
        w.print("\n[stopped at {d} matches — refine pattern]\n", .{MAX_TOTAL_MATCHES}) catch {};
    }
    if (files_at_limit > 0) {
        w.print("[{d} file(s) hit the {d}-per-file limit]\n", .{ files_at_limit, MAX_PER_FILE }) catch {};
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "grep alloc failed");
    return util.ownedTextResult(allocator, out, false);
}
