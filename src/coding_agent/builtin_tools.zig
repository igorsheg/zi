const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const json_value = @import("../json/value.zig");

pub const bash = @import("builtin_tools/bash.zig");

pub const max_builtin_tools: usize = 1;

pub const Builtins = struct {
    allocator: std.mem.Allocator,
    bash_config: *bash.Config,
    tools_value: [max_builtin_tools]agent_mod.AgentTool,

    pub const Options = struct {
        bash: bash.Config.Options,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Builtins {
        const bash_config = try allocator.create(bash.Config);
        errdefer allocator.destroy(bash_config);
        bash_config.* = try bash.Config.init(allocator, options.bash);
        errdefer bash_config.deinit();
        return .{
            .allocator = allocator,
            .bash_config = bash_config,
            .tools_value = .{bash.tool(bash_config)},
        };
    }

    pub fn deinit(self: *Builtins) void {
        self.bash_config.deinit();
        self.allocator.destroy(self.bash_config);
        self.* = undefined;
    }

    /// Returned Source borrows this Builtins. The Builtins must outlive the Source
    /// and any Host created from it because AgentTool.ctx points at owned config.
    pub fn source(self: *Builtins) Source {
        self.tools_value[0] = bash.tool(self.bash_config);
        return fromStatic(&self.tools_value);
    }

    /// Returned Host borrows this Builtins through AgentTool.ctx. Deinitialize the
    /// Host before deinitializing Builtins.
    pub fn host(self: *Builtins, allocator: std.mem.Allocator) !@import("extension.zig").Host {
        return builtin_tools_host(allocator, self.source());
    }
};

pub const HostBundle = struct {
    builtins: Builtins,
    host_value: @import("extension.zig").Host,

    pub fn init(allocator: std.mem.Allocator, options: Builtins.Options) !HostBundle {
        var builtins = try Builtins.init(allocator, options);
        errdefer builtins.deinit();
        const host_value = try builtins.host(allocator);
        return .{ .builtins = builtins, .host_value = host_value };
    }

    pub fn deinit(self: *HostBundle) void {
        self.host_value.deinit();
        self.builtins.deinit();
        self.* = undefined;
    }

    pub fn host(self: *HostBundle) *@import("extension.zig").Host {
        return &self.host_value;
    }
};

pub const Source = struct {
    tools_value: []const agent_mod.AgentTool,

    pub fn tools(self: Source) []const agent_mod.AgentTool {
        return self.tools_value;
    }
};

pub fn empty() Source {
    return .{ .tools_value = &.{} };
}

pub fn fromStatic(tools: []const agent_mod.AgentTool) Source {
    return .{ .tools_value = tools };
}

pub fn host(allocator: std.mem.Allocator, source: Source) !@import("extension.zig").Host {
    return builtin_tools_host(allocator, source);
}

fn builtin_tools_host(allocator: std.mem.Allocator, source: Source) !@import("extension.zig").Host {
    return @import("extension.zig").Host.initTools(allocator, source.tools());
}

fn noopTool(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.tool.ToolInvocation, _: agent_mod.tool.ToolCompletionSink) void {}

test "builtin tool source feeds extension host registry" {
    const builtin = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = json_value.OwnedValue.nullValue().borrowed(), .execute_fn = noopTool }};
    var h = try host(std.testing.allocator, fromStatic(&builtin));
    defer h.deinit();

    const registered = h.tools();
    try std.testing.expectEqual(@as(usize, 1), registered.len);
    try std.testing.expectEqualStrings("read", registered[0].name);
    try std.testing.expect(registered[0].name.ptr != builtin[0].name.ptr);
}

test "empty builtin tool source feeds empty host" {
    var h = try host(std.testing.allocator, empty());
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 0), h.tools().len);
}

test "default builtins feed extension host registry" {
    var builtins = try Builtins.init(std.testing.allocator, .{ .bash = .{ .io = std.testing.io } });
    defer builtins.deinit();
    var h = try builtins.host(std.testing.allocator);
    defer h.deinit();

    const registered = h.tools();
    try std.testing.expectEqual(@as(usize, 1), registered.len);
    try std.testing.expectEqualStrings("bash", registered[0].name);
}

test "builtin host bundle owns host and configs in deinit order" {
    var bundle = try HostBundle.init(std.testing.allocator, .{ .bash = .{ .io = std.testing.io } });
    defer bundle.deinit();

    const registered = bundle.host().tools();
    try std.testing.expectEqual(@as(usize, 1), registered.len);
    try std.testing.expectEqualStrings("bash", registered[0].name);
}
