//! Shared test fixture for the builtin tools: a tmp dir resolved to a real
//! cwd, and one entry point that executes a tool from a JSON argument string.

const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    cwd_buffer: [std.Io.Dir.max_path_bytes]u8,
    cwd_len: usize,

    /// Creates a tmp dir containing `sub_path`; `cwd()` is its real path.
    pub fn init(sub_path: []const u8) !Fixture {
        var self: Fixture = .{ .tmp = std.testing.tmpDir(.{}), .cwd_buffer = undefined, .cwd_len = 0 };
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(std.testing.io, sub_path);
        self.cwd_len = try self.tmp.dir.realPathFile(std.testing.io, sub_path, &self.cwd_buffer);
        return self;
    }

    pub fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.* = undefined;
    }

    pub fn cwd(self: *const Fixture) []const u8 {
        return self.cwd_buffer[0..self.cwd_len];
    }

    pub fn dir(self: *Fixture, sub_path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, sub_path);
    }

    pub fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// Caller frees with std.testing.allocator.
    pub fn read(self: *Fixture, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, sub_path, std.testing.allocator, .unlimited);
    }
};

pub fn execute(tool: agent.AgentTool, args_json: []const u8) !agent.ToolExecutionResult {
    return executeWithUpdate(tool, args_json, null);
}

pub fn executeWithUpdate(
    tool: agent.AgentTool,
    args_json: []const u8,
    on_update: ?agent.AgentToolUpdateCallback,
) !agent.ToolExecutionResult {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try runtime.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args_json, .{});
    defer parsed.deinit();
    return tool.execute.call_fn(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        tool.execute.context,
        cancel_source.token(),
        "call",
        parsed.value,
        on_update,
    );
}
