const std = @import("std");
const agent = @import("../agent/root.zig");
const bash_tool = @import("tools/bash.zig");
const edit_tool = @import("tools/edit.zig");
const find_tool = @import("tools/find.zig");
const grep_tool = @import("tools/grep.zig");
const ls_tool = @import("tools/ls.zig");
const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");

pub const default_active_tool_names: []const []const u8 = &.{ "read", "ls", "grep", "find", "bash", "edit", "write" };
const max_tools = default_active_tool_names.len;

/// Bounded set of executable tools plus the per-tool system prompt snippet.
/// The agent core receives the borrowed `agent.AgentTool` views; the snippet
/// is session policy consumed by the system prompt builder.
pub const ToolRegistry = struct {
    tools: [max_tools]agent.AgentTool = undefined,
    names: [max_tools][]const u8 = undefined,
    prompt_snippets: [max_tools]?[]const u8 = undefined,
    len: usize = 0,

    fn append(self: *ToolRegistry, tool: agent.AgentTool, prompt_snippet: ?[]const u8) !void {
        if (self.len == max_tools) return error.ToolLimitExceeded;
        for (self.names[0..self.len]) |name| {
            if (std.mem.eql(u8, name, tool.name)) return error.DuplicateToolName;
        }
        self.tools[self.len] = tool;
        self.names[self.len] = tool.name;
        self.prompt_snippets[self.len] = prompt_snippet;
        self.len += 1;
    }

    pub fn activeAgentTools(self: *const ToolRegistry) []const agent.AgentTool {
        return self.tools[0..self.len];
    }

    pub fn activeToolNames(self: *const ToolRegistry) []const []const u8 {
        return self.names[0..self.len];
    }

    pub fn activePromptSnippets(self: *const ToolRegistry) []const ?[]const u8 {
        return self.prompt_snippets[0..self.len];
    }
};

/// One owner for the builtin tool implementations. Heap-allocated so the
/// `AgentTool` context pointers stay stable for the session lifetime.
pub const BuiltinTools = struct {
    allocator: std.mem.Allocator,
    read: ReadTool,
    ls: LsTool,
    grep: GrepTool,
    find: FindTool,
    bash: BashTool,
    edit: EditTool,
    write: WriteTool,

    const ReadTool = read_tool.ReadTool;
    const LsTool = ls_tool.LsTool;
    const GrepTool = grep_tool.GrepTool;
    const FindTool = find_tool.FindTool;
    const BashTool = bash_tool.BashTool;
    const EditTool = edit_tool.EditTool;
    const WriteTool = write_tool.WriteTool;

    pub const Options = struct {
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map = null,
        allow_paths_outside_cwd: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !*BuiltinTools {
        const self = try allocator.create(BuiltinTools);
        self.allocator = allocator;
        var read_init = false;
        var ls_init = false;
        var grep_init = false;
        var find_init = false;
        var bash_init = false;
        var edit_init = false;
        errdefer {
            if (edit_init) self.edit.deinit();
            if (bash_init) self.bash.deinit();
            if (find_init) self.find.deinit();
            if (grep_init) self.grep.deinit();
            if (ls_init) self.ls.deinit();
            if (read_init) self.read.deinit();
            allocator.destroy(self);
        }

        const cwd = options.cwd;
        const outside = options.allow_paths_outside_cwd;
        self.read = try ReadTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        read_init = true;
        self.ls = try LsTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        ls_init = true;
        self.grep = try GrepTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        grep_init = true;
        self.find = try FindTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        find_init = true;
        self.bash = try BashTool.init(allocator, .{ .cwd = cwd, .environ = options.environ });
        bash_init = true;
        self.edit = try EditTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        edit_init = true;
        self.write = try WriteTool.init(allocator, .{ .cwd = cwd, .allow_paths_outside_cwd = outside });
        return self;
    }

    // ziglint-ignore: Z030 heap owner is poisoned before allocator.destroy(self).
    pub fn deinit(self: *BuiltinTools) void {
        const allocator = self.allocator;
        self.write.deinit();
        self.edit.deinit();
        self.bash.deinit();
        self.find.deinit();
        self.grep.deinit();
        self.ls.deinit();
        self.read.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn registry(self: *BuiltinTools) !ToolRegistry {
        var out: ToolRegistry = .{};
        try out.append(
            self.read.tool(),
            "Read file contents. Use offset/limit for large files; continue with offset when needed.",
        );
        try out.append(
            self.ls.tool(),
            "List one directory. Prefer this over bash ls for directory inspection.",
        );
        try out.append(
            self.grep.tool(),
            "Search files for literal text. Prefer this over bash grep for simple searches.",
        );
        try out.append(
            self.find.tool(),
            "Find paths under a directory. Prefer this over bash find for simple path discovery.",
        );
        try out.append(
            self.bash.tool(),
            "Run one shell command in the session cwd. Prefer read/ls/grep/find/edit/write for file work.",
        );
        try out.append(
            self.edit.tool(),
            "Edit a file using exact unique text replacements. Use one call for multiple disjoint edits.",
        );
        try out.append(
            self.write.tool(),
            "Create or overwrite a text file, creating parent directories as needed.",
        );
        return out;
    }
};

test "tool registry exposes builtin tools names and snippets in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    var builtins = try BuiltinTools.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd_len] });
    defer builtins.deinit();
    const registry = try builtins.registry();

    try std.testing.expectEqual(default_active_tool_names.len, registry.len);
    for (default_active_tool_names, registry.activeToolNames()) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(agent.ToolExecutionMode.sequential, registry.activeAgentTools()[4].execution_mode.?);
    try std.testing.expectEqual(agent.ToolExecutionMode.sequential, registry.activeAgentTools()[5].execution_mode.?);
    try std.testing.expect(registry.activePromptSnippets()[0] != null);
}
