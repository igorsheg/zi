//! Write tool — create or overwrite a file with mkdir-p semantics.
//!
//! pi-mono parity: ports `create-file.ts`. Carries over the per-path
//! mutex from the ts override via `lock_registry`: two concurrent
//! writes to the same canonicalized path serialize. Deferred:
//! - file-tracker change record for undo_edit (undo tool not yet ported)

const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const lock_registry = @import("lock_registry.zig");

const SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string","description":"The absolute path of the file to be created (must be absolute, not relative)."},"content":{"type":"string","description":"The content for the file."}},"required":["path","content"]}
;

const DESCRIPTION =
    "Create or overwrite a file in the workspace.\n\n" ++
    "Use this tool to create a **new file** that does not yet exist.\n\n" ++
    "For **existing files**, prefer the edit tool instead — even for extensive changes. " ++
    "Only use this tool to overwrite an existing file when you are replacing nearly all " ++
    "of its content AND the file is small (under ~250 lines).\n\n" ++
    "Automatically creates parent directories if they don't exist.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "write",
        .description = DESCRIPTION,
        .label = "Create File",
        .parameters = util.parseSchema(SCHEMA),
        .prompt_snippet = "Create or overwrite files",
        .prompt_guidelines = &.{"Use write only for new files or complete rewrites."},
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "write" },
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
        return util.errorResult(allocator, "write tool: missing context")));

    const path = util.getString(args, "path") orelse
        return util.errorResult(allocator, "write tool: missing 'path' argument");
    const content = util.getString(args, "content") orelse
        return util.errorResult(allocator, "write tool: missing 'content' argument");

    const resolved = util.resolvePath(allocator, path, ctx.cwd) catch
        return util.errorResult(allocator, "write tool: failed to resolve path");
    defer allocator.free(resolved);

    const lock_entry = lock_registry.global().acquirePath(allocator, resolved) catch
        return util.errorResult(allocator, "write tool: failed to acquire file lock");
    defer lock_registry.global().release(lock_entry);

    var is_new = false;
    std.Io.Dir.cwd().access(std.Options.debug_io, resolved, .{}) catch {
        is_new = true;
    };

    if (std.fs.path.dirname(resolved)) |parent| {
        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent) catch |err|
            return util.errorf(allocator, "write tool: failed to create parent dir: {s}", .{@errorName(err)});
    }

    const file = std.Io.Dir.cwd().createFile(std.Options.debug_io, resolved, .{ .truncate = true }) catch |err|
        return util.errorf(allocator, "write tool: failed to create file: {s}", .{@errorName(err)});
    defer file.close(std.Options.debug_io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(std.Options.debug_io, &write_buf);
    file_writer.interface.writeAll(content) catch |err|
        return util.errorf(allocator, "write tool: failed to write: {s}", .{@errorName(err)});
    file_writer.interface.flush() catch |err|
        return util.errorf(allocator, "write tool: failed to write: {s}", .{@errorName(err)});

    var line_count: usize = 1;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }

    const verb = if (is_new) "created" else "overwrote";
    const msg = std.fmt.allocPrint(allocator, "{s} {s} ({d} lines)", .{
        verb,
        std.fs.path.basename(resolved),
        line_count,
    }) catch return util.errorResult(allocator, "write tool: alloc failed");
    return util.ownedTextResult(allocator, msg, false);
}
