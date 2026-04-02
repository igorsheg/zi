const std = @import("std");
const agent = @import("agent");

/// Bash tool — executes shell commands via /bin/sh -c.
/// pi-mono equivalent: packages/coding-agent/src/core/tools/bash/

const bash_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"}},"required":["command"]}
;

pub fn makeTool() agent.protocol.AgentTool {
    return .{
        .name = "Bash",
        .description = "Execute a bash command on the system. Use for running shell commands, scripts, or system operations.",
        .label = "bash",
        .parameters = parseSchema(),
        .execute = &execute,
    };
}

fn parseSchema() std.json.Value {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        bash_schema,
        .{ .allocate = .alloc_if_needed },
    ) catch return .null;
    return parsed.value;
}

fn execute(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    _: ?*anyopaque,
    _: ?agent.protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) agent.protocol.AgentToolResult {
    const command = extractCommand(args) orelse {
        return errorResult(allocator, "missing 'command' argument");
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-c", command },
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        return errorResult(allocator, std.fmt.allocPrint(
            allocator,
            "failed to execute command: {s}",
            .{@errorName(err)},
        ) catch "failed to execute command");
    };

    var output_parts: std.ArrayListUnmanaged(u8) = .{};
    if (result.stdout.len > 0) {
        output_parts.appendSlice(allocator, result.stdout) catch {};
    }
    if (result.stderr.len > 0) {
        if (output_parts.items.len > 0) {
            output_parts.appendSlice(allocator, "\n") catch {};
        }
        output_parts.appendSlice(allocator, result.stderr) catch {};
    }

    const is_error = result.term.Exited != 0;
    if (output_parts.items.len == 0 and is_error) {
        output_parts.appendSlice(allocator, std.fmt.allocPrint(
            allocator,
            "command exited with code {d}",
            .{result.term.Exited},
        ) catch "command failed") catch {};
    }

    const text_content = allocator.alloc(agent.protocol.AgentToolResult.ContentBlock, 1) catch {
        return errorResult(allocator, "allocation failed");
    };
    text_content[0] = .{ .text = .{ .text = output_parts.items } };

    return .{
        .content = text_content,
    };
}

fn extractCommand(args: std.json.Value) ?[]const u8 {
    switch (args) {
        .object => |obj| {
            if (obj.get("command")) |cmd| {
                switch (cmd) {
                    .string => |s| return s,
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

fn errorResult(allocator: std.mem.Allocator, msg: []const u8) agent.protocol.AgentToolResult {
    const content = allocator.alloc(agent.protocol.AgentToolResult.ContentBlock, 1) catch {
        return .{ .content = &.{} };
    };
    content[0] = .{ .text = .{ .text = msg } };
    return .{ .content = content };
}
