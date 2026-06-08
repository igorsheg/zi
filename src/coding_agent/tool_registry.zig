const std = @import("std");
const agent = @import("../agent/root.zig");
const bash_tool = @import("tools/bash.zig");
const edit_tool = @import("tools/edit.zig");
const file_mutation_queue = @import("tools/file_mutation_queue.zig");
const find_tool = @import("tools/find.zig");
const grep_tool = @import("tools/grep.zig");
const ls_tool = @import("tools/ls.zig");
const read_tool = @import("tools/read.zig");
const write_tool = @import("tools/write.zig");

const BashTool = bash_tool.BashTool;
const EditTool = edit_tool.EditTool;
const FileMutationQueue = file_mutation_queue.FileMutationQueue;
const FindTool = find_tool.FindTool;
const GrepTool = grep_tool.GrepTool;
const LsTool = ls_tool.LsTool;
const ReadTool = read_tool.ReadTool;
const WriteTool = write_tool.WriteTool;

const max_tool_definitions = 64;
const max_active_tools = 64;
pub const builtin_tool_count = default_active_tool_names.len;
pub const default_active_tool_names: []const []const u8 = &.{ "read", "ls", "grep", "find", "bash", "edit", "write" };

const read_description = "Read a text file with bounded output. Supports optional 1-indexed offset and line limit. " ++
    "Use offset/limit to continue large files.";
const bash_description = "Run one shell command in the session cwd. Supports optional timeout in seconds. " ++
    "Output is bounded.";
const bash_prompt_snippet = "Run one shell command in the session cwd. " ++
    "Prefer read/ls/grep/find/edit/write for file work.";
const edit_prompt_snippet = "Edit a file using exact unique text replacements. " ++
    "Use one call for multiple disjoint edits.";

pub const ToolSource = union(enum) {
    builtin,
    custom: []const u8,
};

pub const ToolDisplayPresentation = enum { generic, command, file, patch, search, directory };
pub const ToolDisplayBodyMode = enum { visible, hidden_on_success };

pub const ToolDisplay = struct {
    presentation: ToolDisplayPresentation = .generic,
    body_mode: ToolDisplayBodyMode = .visible,
};

pub const ToolMetadata = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: []const []const u8 = &.{},
    source: ToolSource = .builtin,
    execution_mode: ?agent.ToolExecutionMode = null,
    display: ToolDisplay = .{},
};

pub const ToolImplementation = struct {
    context: *anyopaque,
    as_agent_tool_fn: *const fn (*anyopaque) agent.AgentTool,

    pub fn init(ptr: anytype) ToolImplementation {
        const Pointer = @TypeOf(ptr);
        const info = @typeInfo(Pointer);
        if (info != .pointer) @compileError("ToolImplementation.init requires a pointer");
        const Child = info.pointer.child;
        if (!@hasDecl(Child, "tool")) @compileError("tool implementation must expose tool(self) agent.AgentTool");

        const gen = struct {
            fn asAgentTool(context: *anyopaque) agent.AgentTool {
                const typed: Pointer = @ptrCast(@alignCast(context));
                return typed.tool();
            }
        };

        return .{ .context = ptr, .as_agent_tool_fn = gen.asAgentTool };
    }

    pub fn asAgentTool(self: ToolImplementation) agent.AgentTool {
        return self.as_agent_tool_fn(self.context);
    }
};

pub const ToolDefinition = struct {
    metadata: ToolMetadata,
    parameters: std.json.Value,
    implementation: ToolImplementation,

    pub fn init(ptr: anytype, metadata: ToolMetadata) ToolDefinition {
        const implementation = ToolImplementation.init(ptr);
        const tool = implementation.asAgentTool();
        std.debug.assert(std.mem.eql(u8, metadata.name, tool.name));
        std.debug.assert(std.mem.eql(u8, metadata.label, tool.label));
        if (metadata.execution_mode) |mode| std.debug.assert(tool.execution_mode == mode);
        return .{
            .metadata = metadata,
            .parameters = tool.parameters,
            .implementation = implementation,
        };
    }

    pub fn asAgentTool(self: ToolDefinition) agent.AgentTool {
        return self.implementation.asAgentTool();
    }
};

pub const ActiveToolSet = struct {
    names: []const []const u8,
    agent_tools: []const agent.AgentTool,

    pub fn deinit(self: *ActiveToolSet, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_tools);
        allocator.free(self.names);
        self.* = undefined;
    }
};

pub const ToolRegistry = struct {
    definitions: std.ArrayList(ToolDefinition) = .empty,
    active_names: std.ArrayList([]const u8) = .empty,
    agent_tools: std.ArrayList(agent.AgentTool) = .empty,

    pub fn deinit(self: *ToolRegistry, allocator: std.mem.Allocator) void {
        self.agent_tools.deinit(allocator);
        self.active_names.deinit(allocator);
        self.definitions.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(self: *ToolRegistry, allocator: std.mem.Allocator, definition: ToolDefinition) !void {
        if (self.definitions.items.len == max_tool_definitions) return error.ToolDefinitionLimitExceeded;
        if (self.findDefinition(definition.metadata.name) != null) return error.DuplicateToolName;
        try self.definitions.append(allocator, definition);
    }

    pub fn buildActiveToolSet(
        self: *const ToolRegistry,
        allocator: std.mem.Allocator,
        names: []const []const u8,
    ) !ActiveToolSet {
        var active_names = std.ArrayList([]const u8).empty;
        errdefer active_names.deinit(allocator);
        var active_agent_tools = std.ArrayList(agent.AgentTool).empty;
        errdefer active_agent_tools.deinit(allocator);

        try active_names.ensureTotalCapacity(allocator, @min(names.len, max_active_tools));
        try active_agent_tools.ensureTotalCapacity(allocator, @min(names.len, max_active_tools));
        for (names) |name| {
            if (containsName(active_names.items, name)) continue;
            if (active_names.items.len == max_active_tools) return error.ActiveToolLimitExceeded;
            const definition = self.findDefinition(name) orelse return error.UnknownToolName;
            active_names.appendAssumeCapacity(definition.metadata.name);
            active_agent_tools.appendAssumeCapacity(definition.asAgentTool());
        }

        return .{
            .names = try active_names.toOwnedSlice(allocator),
            .agent_tools = try active_agent_tools.toOwnedSlice(allocator),
        };
    }

    pub fn ensureActiveCapacity(self: *ToolRegistry, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity > max_active_tools) return error.ActiveToolLimitExceeded;
        try self.active_names.ensureTotalCapacity(allocator, capacity);
        try self.agent_tools.ensureTotalCapacity(allocator, capacity);
    }

    pub fn commitActiveToolSet(self: *ToolRegistry, active_set: ActiveToolSet) void {
        std.debug.assert(self.active_names.capacity >= active_set.names.len);
        std.debug.assert(self.agent_tools.capacity >= active_set.agent_tools.len);
        self.active_names.clearRetainingCapacity();
        self.agent_tools.clearRetainingCapacity();
        self.active_names.appendSliceAssumeCapacity(active_set.names);
        self.agent_tools.appendSliceAssumeCapacity(active_set.agent_tools);
    }

    pub fn setActiveToolsByName(self: *ToolRegistry, allocator: std.mem.Allocator, names: []const []const u8) !void {
        var active_set = try self.buildActiveToolSet(allocator, names);
        defer active_set.deinit(allocator);
        try self.ensureActiveCapacity(allocator, active_set.names.len);
        self.commitActiveToolSet(active_set);
    }

    pub fn activeAgentTools(self: *const ToolRegistry) []const agent.AgentTool {
        return self.agent_tools.items;
    }

    pub fn activeToolNames(self: *const ToolRegistry) []const []const u8 {
        return self.active_names.items;
    }

    pub fn findDefinition(self: *const ToolRegistry, name: []const u8) ?ToolDefinition {
        for (self.definitions.items) |definition| {
            if (std.mem.eql(u8, definition.metadata.name, name)) return definition;
        }
        return null;
    }
};

pub const BuiltinTools = struct {
    allocator: std.mem.Allocator,
    mutation_queue: *FileMutationQueue,
    read: *ReadTool,
    ls: *LsTool,
    grep: *GrepTool,
    find: *FindTool,
    bash: *BashTool,
    edit: *EditTool,
    write: *WriteTool,

    pub const Options = struct {
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map = null,
        allow_paths_outside_cwd: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !BuiltinTools {
        const mutation_queue = try allocator.create(FileMutationQueue);
        errdefer allocator.destroy(mutation_queue);
        mutation_queue.* = .{};

        const read = try allocator.create(ReadTool);
        errdefer allocator.destroy(read);
        read.* = try ReadTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        errdefer read.deinit();

        const ls = try allocator.create(LsTool);
        errdefer allocator.destroy(ls);
        ls.* = try LsTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        errdefer ls.deinit();

        const grep = try allocator.create(GrepTool);
        errdefer allocator.destroy(grep);
        grep.* = try GrepTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        errdefer grep.deinit();

        const find = try allocator.create(FindTool);
        errdefer allocator.destroy(find);
        find.* = try FindTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        errdefer find.deinit();

        const bash = try allocator.create(BashTool);
        errdefer allocator.destroy(bash);
        bash.* = try BashTool.init(allocator, .{
            .cwd = options.cwd,
            .environ = options.environ,
        });
        errdefer bash.deinit();

        const edit = try allocator.create(EditTool);
        errdefer allocator.destroy(edit);
        edit.* = try EditTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
            .mutation_queue = mutation_queue,
        });
        errdefer edit.deinit();

        const write = try allocator.create(WriteTool);
        errdefer allocator.destroy(write);
        write.* = try WriteTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
            .mutation_queue = mutation_queue,
        });

        return .{
            .allocator = allocator,
            .mutation_queue = mutation_queue,
            .read = read,
            .ls = ls,
            .grep = grep,
            .find = find,
            .bash = bash,
            .edit = edit,
            .write = write,
        };
    }

    pub fn deinit(self: *BuiltinTools) void {
        self.write.deinit();
        self.allocator.destroy(self.write);
        self.edit.deinit();
        self.allocator.destroy(self.edit);
        self.bash.deinit();
        self.allocator.destroy(self.bash);
        self.find.deinit();
        self.allocator.destroy(self.find);
        self.grep.deinit();
        self.allocator.destroy(self.grep);
        self.ls.deinit();
        self.allocator.destroy(self.ls);
        self.read.deinit();
        self.allocator.destroy(self.read);
        self.allocator.destroy(self.mutation_queue);
        self.* = undefined;
    }

    pub fn appendDefinitions(self: *BuiltinTools, registry: *ToolRegistry) !void {
        try registry.append(self.allocator, ToolDefinition.init(self.read, .{
            .name = "read",
            .label = "read",
            .description = read_description,
            .prompt_snippet = "Read file contents. Use offset/limit for large files; continue with offset when needed.",
            .display = .{ .presentation = .file, .body_mode = .hidden_on_success },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.ls, .{
            .name = "ls",
            .label = "ls",
            .description = "List one directory with bounded output.",
            .prompt_snippet = "List one directory. Prefer this over bash ls for directory inspection.",
            .display = .{ .presentation = .directory },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.grep, .{
            .name = "grep",
            .label = "grep",
            .description = "Search files for a literal text pattern with bounded output.",
            .prompt_snippet = "Search files for literal text. Prefer this over bash grep for simple searches.",
            .display = .{ .presentation = .search },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.find, .{
            .name = "find",
            .label = "find",
            .description = "Recursively find paths under a directory with bounded output.",
            .prompt_snippet = "Find paths under a directory. Prefer this over bash find for simple path discovery.",
            .display = .{ .presentation = .directory },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.bash, .{
            .name = "bash",
            .label = "bash",
            .description = bash_description,
            .prompt_snippet = bash_prompt_snippet,
            .execution_mode = .sequential,
            .display = .{ .presentation = .command },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.edit, .{
            .name = "edit",
            .label = "edit",
            .description = "Edit a single file using exact, unique, non-overlapping text replacements.",
            .prompt_snippet = edit_prompt_snippet,
            .execution_mode = .sequential,
            .display = .{ .presentation = .patch, .body_mode = .hidden_on_success },
        }));
        try registry.append(self.allocator, ToolDefinition.init(self.write, .{
            .name = "write",
            .label = "write",
            .description = "Create or overwrite a text file. Creates parent directories as needed.",
            .prompt_snippet = "Create or overwrite a text file, creating parent directories as needed.",
            .execution_mode = .sequential,
            .display = .{ .presentation = .file, .body_mode = .visible },
        }));
    }
};

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

test "tool registry stores definitions first and exposes active agent tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    var builtins = try BuiltinTools.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd_len] });
    defer builtins.deinit();
    var registry: ToolRegistry = .{};
    defer registry.deinit(std.testing.allocator);

    try builtins.appendDefinitions(&registry);
    try registry.setActiveToolsByName(
        std.testing.allocator,
        &.{ "read", "ls", "grep", "find", "bash", "edit", "write" },
    );

    try std.testing.expectEqual(@as(usize, builtin_tool_count), registry.definitions.items.len);
    try std.testing.expectEqual(@as(usize, builtin_tool_count), registry.activeAgentTools().len);
    try std.testing.expectEqualStrings("read", registry.activeAgentTools()[0].name);
    try std.testing.expectEqualStrings("ls", registry.activeAgentTools()[1].name);
    try std.testing.expectEqualStrings("grep", registry.activeAgentTools()[2].name);
    try std.testing.expectEqualStrings("find", registry.activeAgentTools()[3].name);
    try std.testing.expectEqualStrings("bash", registry.activeAgentTools()[4].name);
    try std.testing.expectEqual(agent.ToolExecutionMode.sequential, registry.activeAgentTools()[4].execution_mode.?);
    try std.testing.expectEqualStrings("edit", registry.activeAgentTools()[5].name);
    try std.testing.expectEqual(agent.ToolExecutionMode.sequential, registry.activeAgentTools()[5].execution_mode.?);
    try std.testing.expectEqual(
        ToolDisplayPresentation.command,
        registry.definitions.items[4].metadata.display.presentation,
    );
    try std.testing.expectEqual(
        ToolDisplayPresentation.patch,
        registry.definitions.items[5].metadata.display.presentation,
    );
    try std.testing.expectEqual(ToolDisplayBodyMode.visible, registry.definitions.items[6].metadata.display.body_mode);
}

test "tool registry rejects duplicate and unknown tool names without changing active set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    var builtins = try BuiltinTools.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd_len] });
    defer builtins.deinit();
    var registry: ToolRegistry = .{};
    defer registry.deinit(std.testing.allocator);

    try builtins.appendDefinitions(&registry);
    try registry.setActiveToolsByName(std.testing.allocator, &.{"read"});
    try std.testing.expectError(error.DuplicateToolName, registry.append(
        std.testing.allocator,
        ToolDefinition.init(builtins.read, .{
            .name = "read",
            .label = "read",
            .description = "Read a text file with bounded output. Supports optional 1-indexed offset and line limit.",
        }),
    ));
    try std.testing.expectError(error.UnknownToolName, registry.setActiveToolsByName(
        std.testing.allocator,
        &.{ "edit", "missing" },
    ));
    try std.testing.expectEqual(@as(usize, 1), registry.activeToolNames().len);
    try std.testing.expectEqualStrings("read", registry.activeToolNames()[0]);
}
