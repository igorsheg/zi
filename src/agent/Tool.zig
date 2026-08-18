//! The erased tool executor seam. A tool pairs a provider-visible definition
//! with a local executor; the catalog admits tools once, before any model I/O,
//! and rejects invalid definitions. Executors classify their own outcomes:
//! `.failure` is a model-visible result and only ToolFatalError aborts the run.

const std = @import("std");
const message = @import("../ai/message.zig");
const model = @import("../ai/model.zig");

pub const Error = error{
    OutOfMemory,
    DuplicateToolName,
    InvalidToolDefinition,
    UnknownTool,
    InvalidToolArguments,
};

/// Failures that terminate the run instead of becoming model-visible results.
pub const ToolFatalError = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
};

/// A completed tool output. Slices are borrowed from the executor's per-call
/// allocation and stay valid until the harness copies the result.
pub const ToolOutput = struct {
    content: []const message.Content,
};

/// The outcome of one tool invocation. `.failure` is shown to the model as a
/// tool error result; only ToolFatalError aborts the run.
pub const ToolExecution = union(enum) {
    success: ToolOutput,
    failure: []const u8,
};

pub const Tool = struct {
    definition: message.ToolDefinition,
    context: *anyopaque,
    executeFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: RunContext,
        arguments_json: []const u8,
    ) ToolFatalError!ToolExecution,

    /// Run-wide cooperative control forwarded to every executor call. The
    /// agent races tool work against cancellation and the run deadline.
    pub const RunContext = struct {
        cancellation: ?*const model.CancellationToken = null,
        deadline: ?std.Io.Clock.Timestamp = null,
    };

    /// Erases a concrete implementation's execute method behind the runtime
    /// seam. The implementation must outlive every tool view over it.
    pub fn from(implementation: anytype, definition: message.ToolDefinition) Tool {
        const Implementation = @TypeOf(implementation.*);
        const Adapter = struct {
            // Context leads because this adapter implements the erased tool ABI.
            // ziglint-ignore: Z023
            fn executeImpl(
                context: *anyopaque,
                allocator: std.mem.Allocator, // ziglint-ignore: Z023
                io: std.Io, // ziglint-ignore: Z023
                run_context: RunContext,
                arguments_json: []const u8,
            ) ToolFatalError!ToolExecution {
                const instance: *Implementation = @ptrCast(@alignCast(context));
                return instance.execute(allocator, io, run_context, arguments_json);
            }
        };
        return .{
            .definition = definition,
            .context = implementation,
            .executeFn = Adapter.executeImpl,
        };
    }

    /// Rejects arguments that are not a syntactically valid JSON object.
    /// Semantic validation of the arguments is owned by the executor.
    pub fn validateArguments(allocator: std.mem.Allocator, arguments_json: []const u8) Error!void {
        return validateJsonObject(allocator, arguments_json, error.InvalidToolArguments);
    }

    pub fn execute(
        self: Tool,
        allocator: std.mem.Allocator,
        io: std.Io,
        run_context: RunContext,
        arguments_json: []const u8,
    ) ToolFatalError!ToolExecution {
        return self.executeFn(self.context, allocator, io, run_context, arguments_json);
    }

    /// Reports whether `tool` already exists under the same name.
    pub fn hasName(self: Tool, name: []const u8) bool {
        return std.mem.eql(u8, self.definition.name, name);
    }
};

/// Owns the admitted tools for one agent. Definitions are deep-copied into an
/// arena; executor contexts stay borrowed and must outlive the catalog. One
/// allocator, one deinit boundary.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tools: std.ArrayList(Tool) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn admit(self: *Catalog, tool: Tool) Error!void {
        if (tool.definition.name.len == 0) return error.InvalidToolDefinition;
        try validateJsonObject(
            self.allocator,
            tool.definition.parameters_json_schema,
            error.InvalidToolDefinition,
        );
        for (self.tools.items) |existing| {
            if (existing.hasName(tool.definition.name)) return error.DuplicateToolName;
        }
        const memory = self.arena.allocator();
        // Failed copies stay owned by the arena; admission either completes or
        // leaves the catalog unchanged.
        const definition: message.ToolDefinition = .{
            .name = try memory.dupe(u8, tool.definition.name),
            .description = try memory.dupe(u8, tool.definition.description),
            .parameters_json_schema = try memory.dupe(u8, tool.definition.parameters_json_schema),
        };
        try self.tools.append(self.arena.allocator(), .{
            .definition = definition,
            .context = tool.context,
            .executeFn = tool.executeFn,
        });
    }

    pub fn lookup(self: *const Catalog, name: []const u8) ?Tool {
        for (self.tools.items) |tool| {
            if (tool.hasName(name)) return tool;
        }
        return null;
    }
};

fn validateJsonObject(
    allocator: std.mem.Allocator,
    source: []const u8,
    invalid: Error,
) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |failure| {
        return if (failure == error.OutOfMemory) error.OutOfMemory else invalid;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return invalid;
}

const FakeEcho = struct {
    fatal: bool = false,
    recover_with: ?[]const u8 = null,
    expect_control: bool = false,

    fn execute(
        self: *FakeEcho,
        allocator: std.mem.Allocator,
        _: std.Io,
        run_context: Tool.RunContext,
        arguments_json: []const u8,
    ) ToolFatalError!ToolExecution {
        if (self.expect_control) std.debug.assert(run_context.cancellation != null);
        if (self.fatal) return error.Cancelled;
        if (self.recover_with) |failure| return .{ .failure = failure };
        const text = try allocator.dupe(u8, arguments_json);
        const content = try allocator.alloc(message.Content, 1);
        content[0] = .{ .text = text };
        return .{ .success = .{ .content = content } };
    }
};

const echo_definition: message.ToolDefinition = .{
    .name = "echo",
    .description = "Returns its arguments",
    .parameters_json_schema = "{\"type\":\"object\"}",
};

test "catalog rejects empty tool names" {
    var echo: FakeEcho = .{};
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    const tool = Tool.from(&echo, .{ .name = "", .description = "", .parameters_json_schema = "{}" });
    try std.testing.expectError(error.InvalidToolDefinition, catalog.admit(tool));
}

test "catalog rejects duplicate tool names" {
    var first: FakeEcho = .{};
    var second: FakeEcho = .{};
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog.admit(Tool.from(&first, echo_definition));
    try std.testing.expectError(error.DuplicateToolName, catalog.admit(Tool.from(&second, echo_definition)));
}

test "catalog rejects malformed and non-object parameter schemas" {
    var echo: FakeEcho = .{};
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    const schema_variants = [_][]const u8{ "{invalid", "[]", "\"type\"", "42" };
    for (schema_variants, 0..) |schema, index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "tool{d}", .{index});
        defer std.testing.allocator.free(name);
        const definition: message.ToolDefinition = .{
            .name = name,
            .description = "",
            .parameters_json_schema = schema,
        };
        try std.testing.expectError(error.InvalidToolDefinition, catalog.admit(Tool.from(&echo, definition)));
    }
}

test "catalog owns deep copies of admitted definitions" {
    var echo: FakeEcho = .{};
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    var stack_definition = echo_definition;
    try catalog.admit(Tool.from(&echo, stack_definition));
    stack_definition.name = "mutated";
    try std.testing.expectEqualStrings("echo", catalog.lookup("echo").?.definition.name);
    try std.testing.expect(catalog.lookup("mutated") == null);
    try std.testing.expect(catalog.lookup("echo").?.context == @as(*anyopaque, @ptrCast(&echo)));
}

test "catalog lookup resolves names and returns null for unknown tools" {
    var alpha: FakeEcho = .{};
    var beta: FakeEcho = .{};
    var catalog = Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog.admit(Tool.from(&alpha, .{ .name = "alpha", .description = "", .parameters_json_schema = "{}" }));
    try catalog.admit(Tool.from(&beta, .{ .name = "beta", .description = "", .parameters_json_schema = "{}" }));
    try std.testing.expectEqualStrings("beta", catalog.lookup("beta").?.definition.name);
    try std.testing.expect(catalog.lookup("gamma") == null);
}

test "validateArguments accepts JSON objects and rejects everything else" {
    try Tool.validateArguments(std.testing.allocator, "{\"path\":\"/tmp/x\"}");
    try std.testing.expectError(error.InvalidToolArguments, Tool.validateArguments(std.testing.allocator, "[1,2]"));
    try std.testing.expectError(error.InvalidToolArguments, Tool.validateArguments(std.testing.allocator, "\"text\""));
    try std.testing.expectError(error.InvalidToolArguments, Tool.validateArguments(std.testing.allocator, "{invalid"));
}

test "erased executor returns success output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var echo: FakeEcho = .{};
    const tool = Tool.from(&echo, echo_definition);
    const execution = try tool.execute(arena.allocator(), std.testing.io, .{}, "{\"value\":\"hi\"}");
    try std.testing.expectEqualStrings("{\"value\":\"hi\"}", execution.success.content[0].text);
}

test "executor recoverable failure stays model-visible" {
    var echo: FakeEcho = .{ .recover_with = "cannot open file" };
    const tool = Tool.from(&echo, echo_definition);
    const execution = try tool.execute(std.testing.allocator, std.testing.io, .{}, "{}");
    try std.testing.expectEqualStrings("cannot open file", execution.failure);
}

test "fatal executor failure aborts the call" {
    var echo: FakeEcho = .{ .fatal = true };
    const tool = Tool.from(&echo, echo_definition);
    try std.testing.expectError(error.Cancelled, tool.execute(std.testing.allocator, std.testing.io, .{}, "{}"));
}

test "run context carries the cancellation token to the executor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token: model.CancellationToken = .{};
    var echo: FakeEcho = .{ .expect_control = true };
    const tool = Tool.from(&echo, echo_definition);
    _ = try tool.execute(arena.allocator(), std.testing.io, .{ .cancellation = &token }, "{}");
}
