const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("output_buffer.zig");
const runtime_process = @import("../../zio/root.zig").process;

const DEFAULT_LIMIT: usize = 500;
const MAX_LIMIT: usize = util.Limits.listing_entries;

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
        .display_call = "filePattern",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Find files by glob pattern (respects .gitignore)",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "find" },
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
        return util.errorResult(allocator, "find tool: missing context")));
    const pattern = util.getString(args, "filePattern") orelse
        return util.errorResult(allocator, "find tool: missing 'filePattern' argument");
    const limit_i = util.getI64(args, "limit") orelse @as(i64, @intCast(DEFAULT_LIMIT));
    const offset_i = util.getI64(args, "offset") orelse 0;
    const requested_limit: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    const limit: usize = @min(requested_limit, MAX_LIMIT);
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

    var proc_result = runtime_process.run(allocator, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(util.Limits.process_stdout_bytes),
        .stderr = .ignore,
        .kill_scope = .process_group,
        .signal = signal,
    }) catch |err| return util.errorf(allocator, "find error: {s}", .{@errorName(err)});
    defer proc_result.deinit(allocator);

    const completed = switch (proc_result) {
        .completed => |completed| completed,
        .timed_out => return util.errorResult(allocator, "find timed out"),
        .aborted => return util.errorResult(allocator, "find aborted"),
        .stdout_too_long, .stderr_too_long => |err| return util.errorf(allocator, "find error: {s}", .{err.message}),
    };
    const code: u8 = switch (completed.term) {
        .exited => |c| c,
        else => 2,
    };
    const stdout = completed.stdout;

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, stdout, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const rel = std.fs.path.relative(allocator, ctx.cwd, null, ctx.cwd, trimmed) catch continue;
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
            return util.errorf(allocator, "find exited with code {d}", .{code});
        }
        return util.textResult(allocator, "no files found matching pattern");
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
        output_buffer.appendHeadTail(
            w,
            paths.items,
            limit,
            "... [{d} more results, use a more specific pattern to narrow] ...",
        ) catch return util.errorResult(allocator, "find alloc failed");
        w.print("\n\n({d} total results)", .{total}) catch {};
    } else {
        for (paths.items, 0..) |p, idx| {
            if (idx > 0) w.writeAll("\n") catch break;
            w.writeAll(p) catch break;
        }
    }

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "find alloc failed");
    return util.ownedTextResult(allocator, out, false);
}
