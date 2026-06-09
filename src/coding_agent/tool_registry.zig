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
const builtin_tool_count = default_active_tool_names.len;
pub const default_active_tool_names: []const []const u8 = &.{ "read", "ls", "grep", "find", "bash", "edit", "write" };

const read_description = "Read a text file with bounded output. Supports optional 1-indexed offset and line limit. " ++
    "Use offset/limit to continue large files.";
const bash_description = "Run one shell command in the session cwd. Supports optional timeout in seconds. " ++
    "Output is bounded.";
const bash_prompt_snippet = "Run one shell command in the session cwd. " ++
    "Prefer read/ls/grep/find/edit/write for file work.";
const edit_prompt_snippet = "Edit a file using exact unique text replacements. " ++
    "Use one call for multiple disjoint edits.";

const ToolDisplayPresentation = enum { generic, command, file, patch, search, directory };
const ToolDisplayBodyMode = enum { visible, hidden_on_success };

const ToolDisplay = struct {
    presentation: ToolDisplayPresentation = .generic,
    body_mode: ToolDisplayBodyMode = .visible,
};

const ToolMetadata = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    prompt_snippet: ?[]const u8 = null,
    execution_mode: ?agent.ToolExecutionMode = null,
    display: ToolDisplay = .{},
};

const ToolImplementation = struct {
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

pub const ToolRegistry = struct {
    definitions: [max_tool_definitions]ToolDefinition = undefined,
    active_agent_tools: [max_tool_definitions]agent.AgentTool = undefined,
    definition_count: usize = 0,

    pub fn append(self: *ToolRegistry, definition: ToolDefinition) !void {
        if (self.definition_count == max_tool_definitions) return error.ToolDefinitionLimitExceeded;
        if (self.findDefinition(definition.metadata.name) != null) return error.DuplicateToolName;
        self.definitions[self.definition_count] = definition;
        self.active_agent_tools[self.definition_count] = definition.asAgentTool();
        self.definition_count += 1;
    }

    pub fn activeAgentTools(self: *const ToolRegistry) []const agent.AgentTool {
        return self.active_agent_tools[0..self.definition_count];
    }

    pub fn activeToolNames(_: *const ToolRegistry) []const []const u8 {
        return default_active_tool_names;
    }

    pub fn definitionSlice(self: *const ToolRegistry) []const ToolDefinition {
        return self.definitions[0..self.definition_count];
    }

    pub fn findDefinition(self: *const ToolRegistry, name: []const u8) ?ToolDefinition {
        for (self.definitionSlice()) |definition| {
            if (std.mem.eql(u8, definition.metadata.name, name)) return definition;
        }
        return null;
    }
};

pub const BuiltinTools = struct {
    allocator: std.mem.Allocator,
    mutation_queue: FileMutationQueue,
    read: ReadTool,
    ls: LsTool,
    grep: GrepTool,
    find: FindTool,
    bash: BashTool,
    edit: EditTool,
    write: WriteTool,

    pub const Options = struct {
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map = null,
        allow_paths_outside_cwd: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !*BuiltinTools {
        const self = try allocator.create(BuiltinTools);
        self.allocator = allocator;
        self.mutation_queue = .{};
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

        self.read = try ReadTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        read_init = true;
        self.ls = try LsTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        ls_init = true;
        self.grep = try GrepTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        grep_init = true;
        self.find = try FindTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        });
        find_init = true;
        self.bash = try BashTool.init(allocator, .{
            .cwd = options.cwd,
            .environ = options.environ,
        });
        bash_init = true;
        self.edit = try EditTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
            .mutation_queue = &self.mutation_queue,
        });
        edit_init = true;
        self.write = try WriteTool.init(allocator, .{
            .cwd = options.cwd,
            .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
            .mutation_queue = &self.mutation_queue,
        });
        return self;
    }

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

    pub fn appendDefinitions(self: *BuiltinTools, registry: *ToolRegistry) !void {
        try registry.append(ToolDefinition.init(&self.read, .{
            .name = "read",
            .label = "read",
            .description = read_description,
            .prompt_snippet = "Read file contents. Use offset/limit for large files; continue with offset when needed.",
            .display = .{ .presentation = .file, .body_mode = .hidden_on_success },
        }));
        try registry.append(ToolDefinition.init(&self.ls, .{
            .name = "ls",
            .label = "ls",
            .description = "List one directory with bounded output.",
            .prompt_snippet = "List one directory. Prefer this over bash ls for directory inspection.",
            .display = .{ .presentation = .directory },
        }));
        try registry.append(ToolDefinition.init(&self.grep, .{
            .name = "grep",
            .label = "grep",
            .description = "Search files for a literal text pattern with bounded output.",
            .prompt_snippet = "Search files for literal text. Prefer this over bash grep for simple searches.",
            .display = .{ .presentation = .search },
        }));
        try registry.append(ToolDefinition.init(&self.find, .{
            .name = "find",
            .label = "find",
            .description = "Recursively find paths under a directory with bounded output.",
            .prompt_snippet = "Find paths under a directory. Prefer this over bash find for simple path discovery.",
            .display = .{ .presentation = .directory },
        }));
        try registry.append(ToolDefinition.init(&self.bash, .{
            .name = "bash",
            .label = "bash",
            .description = bash_description,
            .prompt_snippet = bash_prompt_snippet,
            .execution_mode = .sequential,
            .display = .{ .presentation = .command },
        }));
        try registry.append(ToolDefinition.init(&self.edit, .{
            .name = "edit",
            .label = "edit",
            .description = "Edit a single file using exact, unique, non-overlapping text replacements.",
            .prompt_snippet = edit_prompt_snippet,
            .execution_mode = .sequential,
            .display = .{ .presentation = .patch, .body_mode = .hidden_on_success },
        }));
        try registry.append(ToolDefinition.init(&self.write, .{
            .name = "write",
            .label = "write",
            .description = "Create or overwrite a text file. Creates parent directories as needed.",
            .prompt_snippet = "Create or overwrite a text file, creating parent directories as needed.",
            .execution_mode = .sequential,
            .display = .{ .presentation = .file, .body_mode = .visible },
        }));
    }
};

test "tool registry stores definitions first and exposes active agent tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    var builtins = try BuiltinTools.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd_len] });
    defer builtins.deinit();
    var registry: ToolRegistry = .{};
    try builtins.appendDefinitions(&registry);
    try std.testing.expectEqual(@as(usize, builtin_tool_count), registry.definition_count);
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
        .command,
        registry.definitions[4].metadata.display.presentation,
    );
    try std.testing.expectEqual(
        .patch,
        registry.definitions[5].metadata.display.presentation,
    );
    try std.testing.expectEqual(.visible, registry.definitions[6].metadata.display.body_mode);
}

test "tool registry rejects duplicate tool names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buffer);

    var builtins = try BuiltinTools.init(std.testing.allocator, .{ .cwd = cwd_buffer[0..cwd_len] });
    defer builtins.deinit();
    var registry: ToolRegistry = .{};
    try builtins.appendDefinitions(&registry);
    try std.testing.expectError(error.DuplicateToolName, registry.append(
        ToolDefinition.init(&builtins.read, .{
            .name = "read",
            .label = "read",
            .description = "Read a text file with bounded output. Supports optional 1-indexed offset and line limit.",
        }),
    ));
}
