//! Glob (a.k.a. find) tool — fast file finder via `rg --files`.
//!
//! pi-mono parity: ports `glob.ts`. Spawns
//!   rg --files --hidden --color=never --sortr modified --glob !.git --glob !.jj --glob <pat>
//! and returns a relative-path listing sorted by mtime descending.
//! Supports limit + offset pagination.

const std = @import("std");
const protocol = @import("../agent/protocol.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");

const DEFAULT_LIMIT: usize = 500;

const SCHEMA =
    \\{"type":"object","properties":{
    \\"filePattern":{"type":"string","description":"Glob pattern like \"**/*.js\" or \"src/**/*.ts\" to match files."},
    \\"limit":{"type":"number","description":"Maximum number of results to return."},
    \\"offset":{"type":"number","description":"Number of results to skip (for pagination)."}
    \\},"required":["filePattern"]}
;

const DESCRIPTION =
    "Fast file pattern matching tool that works with any codebase size.\n\n" ++
    "Returns matching file paths sorted by most recent modification time first.\n\n" ++
    "## Pattern syntax\n" ++
    "- `**/*.js` — All JavaScript files in any directory\n" ++
    "- `src/**/*.ts` — TypeScript files under src/\n" ++
    "- `*.json` — JSON files in the current directory\n" ++
    "- `**/*test*` — Files with \"test\" in their name\n" ++
    "- `**/*.{js,ts}` — JavaScript and TypeScript files\n";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "find",
        .description = DESCRIPTION,
        .label = "Find Files",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Find files by glob pattern (respects .gitignore)",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "find" },
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
        return util.errorResult(allocator, "find tool: missing context")));
    const pattern = util.getString(args, "filePattern") orelse
        return util.errorResult(allocator, "find tool: missing 'filePattern' argument");
    const limit_i = util.getI64(args, "limit") orelse @as(i64, @intCast(DEFAULT_LIMIT));
    const offset_i = util.getI64(args, "offset") orelse 0;
    const limit: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    const offset: usize = if (offset_i < 0) 0 else @intCast(offset_i);

    const argv = [_][]const u8{
        "rg",       "--files",
        "--hidden", "--color=never",
        "--sortr",  "modified",
        "--glob",   "!.git",
        "--glob",   "!.jj",
        "--glob",   pattern,
        ctx.cwd,
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 8 * 1024 * 1024,
    }) catch |err|
        return util.errorf(allocator, "find error: {s}", .{@errorName(err)});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 2,
    };

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const rel = std.fs.path.relative(allocator, ctx.cwd, trimmed) catch continue;
        if (rel.len == 0 or std.mem.startsWith(u8, rel, "..")) {
            allocator.free(rel);
            continue;
        }
        paths.append(allocator, rel) catch {
            allocator.free(rel);
            break;
        };
    }

    if (paths.items.len == 0) {
        if (code != 0 and code != 1) {
            const stderr_t = std.mem.trim(u8, result.stderr, " \t\n\r");
            if (stderr_t.len > 0) {
                const dup = allocator.dupe(u8, stderr_t) catch
                    return util.errorResult(allocator, "find failed");
                return util.errorResult(allocator, dup);
            }
        }
        return util.textResult(allocator, allocator.dupe(u8, "no files found matching pattern") catch "no files found matching pattern");
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    const total = paths.items.len;

    if (offset > 0) {
        const end = @min(total, offset + limit);
        var i = offset;
        while (i < end) : (i += 1) {
            if (i > offset) w.writeAll("\n") catch break;
            w.writeAll(paths.items[i]) catch break;
        }
        w.print("\n\n(showing {d}-{d} of {d} results)", .{ offset + 1, end, total }) catch {};
    } else if (total > limit) {
        const half = limit / 2;
        var i: usize = 0;
        while (i < half) : (i += 1) {
            if (i > 0) w.writeAll("\n") catch break;
            w.writeAll(paths.items[i]) catch break;
        }
        w.print("\n\n... [{d} more results, use a more specific pattern to narrow] ...\n\n", .{total - 2 * half}) catch {};
        i = total - half;
        var first = true;
        while (i < total) : (i += 1) {
            if (!first) w.writeAll("\n") catch break;
            first = false;
            w.writeAll(paths.items[i]) catch break;
        }
        w.print("\n\n({d} total results)", .{total}) catch {};
    } else {
        for (paths.items, 0..) |p, idx| {
            if (idx > 0) w.writeAll("\n") catch break;
            w.writeAll(p) catch break;
        }
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "find alloc failed");
    return util.textResult(allocator, out);
}
