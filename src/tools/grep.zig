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
const protocol = @import("../agent/protocol.zig");
const util = @import("util.zig");

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

pub fn makeTool(ctx: *util.BuiltinCtx) protocol.AgentTool {
    return .{
        .name = "grep",
        .description = DESCRIPTION,
        .label = "Grep",
        .parameters = util.parseSchema(SCHEMA),
        .ctx = @ptrCast(ctx),
        .execute = &execute,
    };
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

    // Build the rg argv. We rely on rg being on PATH (same assumption pi
    // makes — nix or system install). The agent will surface a "command
    // not found" style error if it isn't.
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

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 8 * 1024 * 1024,
    }) catch |err|
        return util.errorf(allocator, "grep error: {s}", .{@errorName(err)});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 2,
    };
    // rg exits 1 on no matches, 0 on matches, 2+ on error.
    if (exited_code != 0 and exited_code != 1) {
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\n\r");
        if (stderr_trimmed.len > 0) {
            const msg = allocator.dupe(u8, stderr_trimmed) catch
                return util.errorResult(allocator, "grep failed");
            return util.errorResult(allocator, msg);
        }
        return util.errorf(allocator, "ripgrep exited with code {d}", .{exited_code});
    }

    return parseRgJson(allocator, result.stdout, search_path);
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
        const text_trimmed = std.mem.trimRight(u8, text_str, "\r\n");

        events.append(allocator, .{
            .kind = kind,
            .file_path = allocator.dupe(u8, path_str) catch continue,
            .line_number = ln,
            .line_text = allocator.dupe(u8, text_trimmed) catch continue,
        }) catch continue;

        if (kind == .match) total_matches += 1;
        if (total_matches >= MAX_TOTAL_MATCHES) break;
    }

    if (total_matches == 0) {
        return util.textResult(allocator, allocator.dupe(u8, "no matches found") catch "no matches found");
    }

    // Walk events grouped by file. Per-file cap is enforced inline;
    // the relative-path display is cached per file-change to avoid the
    // alloc-and-free per match the first version did (oracle review).
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

            // Cache the display path for this file. Free the previous
            // owned buffer (if any) before replacing.
            if (current_display_owned) |buf| {
                allocator.free(buf);
                current_display_owned = null;
            }
            const rel = std.fs.path.relative(allocator, base_path, ev.file_path) catch null;
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

        // Per-file match cap.
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

    // Trailing notices.
    if (total_matches >= MAX_TOTAL_MATCHES) {
        w.print("\n[stopped at {d} matches — refine pattern]\n", .{MAX_TOTAL_MATCHES}) catch {};
    }
    if (files_at_limit > 0) {
        w.print("[{d} file(s) hit the {d}-per-file limit]\n", .{ files_at_limit, MAX_PER_FILE }) catch {};
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "grep alloc failed");
    return util.textResult(allocator, out);
}
