//! Ls tool — directory listing shadow that delegates to read's
//! directory walk. Models call `ls` by habit; this answers without a
//! second round-trip and steers them toward `read` for future calls.

const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("output_buffer.zig");

const MAX_DIR_ENTRIES: usize = util.Limits.listing_entries;
const MAX_DIR_SCAN_ENTRIES: usize = util.Limits.listing_scan_entries;

const SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The absolute path to the directory to list. Defaults to cwd."}}}
;

const DESCRIPTION =
    "List directory contents. Prefer using the read tool instead — it handles both files and directories.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "ls",
        .description = DESCRIPTION,
        .label = "List Directory",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "List directory contents",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "ls" },
    };
}

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    args: std.json.Value,
    signal: protocol.AbortSignal,
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
    _: protocol.AbortSignal,
    _: ?protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "ls tool: missing context")));

    const path_arg = util.getString(args, "path") orelse ctx.cwd;
    const resolved = util.resolvePath(allocator, path_arg, ctx.cwd) catch
        return util.errorResult(allocator, "ls tool: failed to resolve path");
    defer allocator.free(resolved);

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, resolved, .{ .iterate = true }) catch |err|
        return util.errorf(allocator, "ls tool: cannot open {s}: {s}", .{ resolved, @errorName(err) });
    defer dir.close(std.Options.debug_io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    var scanned: usize = 0;
    while (it.next(std.Options.debug_io) catch null) |entry| {
        if (scanned >= MAX_DIR_SCAN_ENTRIES) break;
        scanned += 1;
        const formatted = if (entry.kind == .directory)
            std.fmt.allocPrint(allocator, "{s}/", .{entry.name}) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;
        names.append(allocator, formatted) catch {
            allocator.free(formatted);
            continue;
        };
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    output_buffer.appendHeadTail(
        &aw.writer,
        names.items,
        MAX_DIR_ENTRIES,
        "... [{d} more entries] ...",
    ) catch return util.errorResult(allocator, "ls alloc failed");
    if (scanned >= MAX_DIR_SCAN_ENTRIES) {
        aw.writer.print("\n\n(stopped after {d} entries; narrow the path to inspect more.)", .{MAX_DIR_SCAN_ENTRIES}) catch {};
    }
    aw.writer.writeAll("\n\n(note: prefer the read tool for directory listing — it handles both files and directories.)") catch {};

    const out = aw.toOwnedSlice() catch
        return util.errorResult(allocator, "ls alloc failed");
    return util.ownedTextResult(allocator, out, false);
}
