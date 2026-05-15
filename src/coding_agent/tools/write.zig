const std = @import("std");
const protocol = @import("../../agent/types.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const lock_registry = @import("lock_registry.zig");
const file_mutation = @import("file_mutation.zig");
const observations = @import("observations.zig");

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
        .display_call = "path",
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
    _: protocol.Token,
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
    std.Io.Dir.cwd().access(std.Options.debug_io, resolved, .{}) catch |err| {
        if (err == error.FileNotFound) {
            is_new = true;
        } else {
            return util.errorf(allocator, "write tool: failed to inspect target: {s}", .{@errorName(err)});
        }
    };

    const permissions = if (!is_new) blk: {
        const validation = ctx.observations.validateFile(allocator, resolved) catch .path_not_comparable;
        switch (validation) {
            .ok, .refreshed_metadata => {},
            else => return util.errorf(allocator, "{s}: {s}", .{ observations.validationMessage(validation, "write", resolved), resolved }),
        }
        break :blk file_mutation.statPermissions(resolved);
    } else null;

    file_mutation.atomicWrite(resolved, content, permissions) catch |err| {
        return util.errorf(allocator, "write tool: failed to write: {s}", .{@errorName(err)});
    };

    const observe_effect = observations.sideEffectFromFile(allocator, resolved, .write) catch null;

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
    var details_obj: std.json.ObjectMap = .{};
    errdefer details_obj.deinit(allocator);
    util.jsonPutString(&details_obj, allocator, "path", resolved) catch return util.ownedTextResult(allocator, msg, false);
    util.jsonPutBool(&details_obj, allocator, "created", is_new) catch return util.ownedTextResult(allocator, msg, false);
    util.jsonPutBool(&details_obj, allocator, "overwrote", !is_new) catch return util.ownedTextResult(allocator, msg, false);
    util.jsonPutInt(&details_obj, allocator, "line_count", @intCast(line_count)) catch return util.ownedTextResult(allocator, msg, false);
    if (observe_effect) |effect| switch (effect) {
        .observe_file => |event| util.jsonPutOwnedString(&details_obj, allocator, "hash", observations.hashHex(allocator, event.hash) catch return util.ownedTextResult(allocator, msg, false)) catch return util.ownedTextResult(allocator, msg, false),
    };
    var result = util.ownedTextResult(allocator, msg, false);
    result.details = .{ .object = details_obj };
    if (observe_effect) |effect| {
        const side_effects = allocator.alloc(protocol.ToolSideEffect, 1) catch return result;
        side_effects[0] = effect;
        result.side_effects = side_effects;
    }
    return result;
}
