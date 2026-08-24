const std = @import("std");
const ai = @import("../ai/root.zig");
const ToolContract = @import("Tool.zig");
const Utf8 = @import("../text/Utf8.zig");

pub const default_maximum_tools: usize = 128;
pub const default_maximum_name_bytes: usize = 1024;
pub const default_maximum_result_bytes: usize = 16 * 1024 * 1024;

pub const Options = struct {
    maximum_tools: usize = default_maximum_tools,
    maximum_name_bytes: usize = default_maximum_name_bytes,
    maximum_result_bytes: usize = default_maximum_result_bytes,
};

pub const InitError = error{InvalidRegistry};
pub const Error = error{ OutOfMemory, InvalidResult };

/// A prepared call borrows its recorded call and selected tool. Only a rewritten
/// argument buffer, when present, is owned. The recorded call is never changed.
pub const Prepared = struct {
    original: *const ai.Item.ToolCall,
    tool: ?ToolContract.Tool,
    effective_arguments_json: []const u8,
    owned_arguments_json: ?[]u8 = null,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        if (self.owned_arguments_json) |arguments| allocator.free(arguments);
        self.* = undefined;
    }
};

/// Provider-neutral view over a fixed tool registry. The tool slice and every
/// object and definition reachable through it remain borrowed for this value's
/// lifetime. Registry validation makes all later scans explicitly bounded.
pub const Dispatch = struct {
    tools: []const ToolContract.Tool,
    options: Options,

    pub fn init(tools: []const ToolContract.Tool, options: Options) InitError!Dispatch {
        if (options.maximum_tools == 0 or options.maximum_name_bytes == 0 or
            options.maximum_result_bytes == 0 or tools.len > options.maximum_tools)
        {
            return error.InvalidRegistry;
        }
        for (tools, 0..) |tool, index| {
            if (tool.definition.name.len == 0 or
                tool.definition.name.len > options.maximum_name_bytes)
            {
                return error.InvalidRegistry;
            }
            for (tools[0..index]) |previous| {
                if (std.mem.eql(u8, previous.definition.name, tool.definition.name))
                    return error.InvalidRegistry;
            }
        }
        return .{ .tools = tools, .options = options };
    }

    pub fn lookup(self: Dispatch, name: []const u8) ?ToolContract.Tool {
        if (name.len == 0 or name.len > self.options.maximum_name_bytes) return null;
        for (self.tools) |tool| {
            if (std.mem.eql(u8, tool.definition.name, name)) return tool;
        }
        return null;
    }

    /// Returns an owned slice of definition values. All strings and parameter
    /// slices in those values remain borrowed from the registry.
    pub fn advertisedDefinitions(
        self: Dispatch,
        allocator: std.mem.Allocator,
    ) Error![]ToolContract.Definition {
        const definitions = try allocator.alloc(ToolContract.Definition, self.tools.len);
        errdefer allocator.free(definitions);
        var count: usize = 0;
        for (self.tools) |tool| {
            if (tool.advertised()) |definition| {
                // A capability hook may vary a schema, but changing its registry
                // key would make the advertised call impossible to dispatch.
                if (!std.mem.eql(u8, definition.name, tool.definition.name))
                    return error.InvalidResult;
                definitions[count] = definition;
                count += 1;
            }
        }
        if (count == definitions.len) return definitions;
        return allocator.realloc(definitions, count);
    }

    pub fn prepare(
        self: Dispatch,
        allocator: std.mem.Allocator,
        io: std.Io,
        call: *const ai.Item.ToolCall,
    ) error{OutOfMemory}!Prepared {
        const tool = self.lookup(call.name);
        const rewritten = if (tool) |selected|
            try selected.preprocess(allocator, io, call.arguments_json)
        else
            null;
        return .{
            .original = call,
            .tool = tool,
            .effective_arguments_json = rewritten orelse call.arguments_json,
            .owned_arguments_json = rewritten,
        };
    }

    pub fn run(
        self: Dispatch,
        allocator: std.mem.Allocator,
        io: std.Io,
        call: *const ai.Item.ToolCall,
        run_context: ToolContract.RunContext,
    ) Error!ai.Item.Item {
        var prepared = try self.prepare(allocator, io, call);
        defer prepared.deinit(allocator);
        return self.runPrepared(allocator, io, &prepared, run_context);
    }

    pub fn runPrepared(
        self: Dispatch,
        allocator: std.mem.Allocator,
        io: std.Io,
        prepared: *const Prepared,
        run_context: ToolContract.RunContext,
    ) Error!ai.Item.Item {
        const selected = prepared.tool orelse return self.unknownResult(allocator, prepared.original);
        var result = selected.run(
            allocator,
            io,
            prepared.effective_arguments_json,
            run_context,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResult => return error.InvalidResult,
        };
        defer result.deinit(allocator);
        if (result.output.len > self.options.maximum_result_bytes)
            return error.InvalidResult;

        const sanitized = try stripControls(
            allocator,
            result.output,
            result.hidden_tail_bytes,
            self.options.maximum_result_bytes,
        );
        errdefer allocator.free(sanitized.output);
        const call_id = try allocator.dupe(u8, prepared.original.id);
        const images = result.images;
        result.images = &.{};
        return .{ .tool_result = .{
            .call_id = call_id,
            .output = sanitized.output,
            .hidden_tail_bytes = sanitized.hidden_tail_bytes,
            .images = images,
            .origin = if (result.summarizes_display) .summarized else .external,
        } };
    }

    pub fn skipped(
        self: Dispatch,
        allocator: std.mem.Allocator,
        call: *const ai.Item.ToolCall,
    ) Error!ai.Item.Item {
        return self.syntheticResult(allocator, call, "[interrupted]", .skipped);
    }

    pub fn refused(
        self: Dispatch,
        allocator: std.mem.Allocator,
        call: *const ai.Item.ToolCall,
    ) Error!ai.Item.Item {
        return self.syntheticResult(
            allocator,
            call,
            "error: tool calls are disabled in this session",
            .refused,
        );
    }

    fn unknownResult(
        self: Dispatch,
        allocator: std.mem.Allocator,
        call: *const ai.Item.ToolCall,
    ) Error!ai.Item.Item {
        const prefix = "unknown tool: ";
        const name = if (call.name.len <= self.options.maximum_name_bytes) call.name else "?";
        if (prefix.len + name.len > self.options.maximum_result_bytes)
            return error.InvalidResult;
        const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
        defer allocator.free(raw);
        return self.syntheticResult(allocator, call, raw, .external);
    }

    fn syntheticResult(
        self: Dispatch,
        allocator: std.mem.Allocator,
        call: *const ai.Item.ToolCall,
        raw_output: []const u8,
        origin: ai.Item.ToolResultOrigin,
    ) Error!ai.Item.Item {
        if (raw_output.len > self.options.maximum_result_bytes) return error.InvalidResult;
        const sanitized = try stripControls(
            allocator,
            raw_output,
            0,
            self.options.maximum_result_bytes,
        );
        errdefer allocator.free(sanitized.output);
        return .{ .tool_result = .{
            .call_id = try allocator.dupe(u8, call.id),
            .output = sanitized.output,
            .origin = origin,
        } };
    }
};

const StripResult = struct {
    output: []u8,
    hidden_tail_bytes: usize,
};

const StripState = enum {
    text,
    escape,
    csi,
    osc,
    osc_escape,
    control_string,
    control_string_escape,
    escape_intermediate,
};

const ByteAction = enum { consume, emit, reprocess };

/// Implements hax's ECMA-48 control stripping. The hidden boundary is measured
/// in the sanitized stream, including when a control sequence crosses it.
fn stripControls(
    allocator: std.mem.Allocator,
    input: []const u8,
    hidden_tail_bytes: usize,
    maximum_result_bytes: usize,
) Error!StripResult {
    if (hidden_tail_bytes > input.len or input.len > maximum_result_bytes)
        return error.InvalidResult;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len);
    const hidden_start = input.len - hidden_tail_bytes;
    var emitted_at_hidden_start: usize = 0;
    var state: StripState = .text;
    for (input, 0..) |byte, index| {
        if (index == hidden_start) emitted_at_hidden_start = output.items.len;
        var action = stripStep(&state, byte);
        while (action == .reprocess) action = stripStep(&state, byte);
        if (action == .emit) output.appendAssumeCapacity(byte);
    }
    if (hidden_start == input.len) emitted_at_hidden_start = output.items.len;
    const stripped = try output.toOwnedSlice(allocator);
    defer allocator.free(stripped);
    const visible = Utf8.sanitize(
        allocator,
        stripped[0..emitted_at_hidden_start],
        maximum_result_bytes,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidResult,
    };
    defer allocator.free(visible);
    const hidden = Utf8.sanitize(
        allocator,
        stripped[emitted_at_hidden_start..],
        maximum_result_bytes - visible.len,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidResult,
    };
    defer allocator.free(hidden);
    const sanitized = try std.mem.concat(allocator, u8, &.{ visible, hidden });
    return .{
        .output = sanitized,
        .hidden_tail_bytes = hidden.len,
    };
}

fn stripStep(state: *StripState, byte: u8) ByteAction {
    return switch (state.*) {
        .text => if (byte == 0x1b) text: {
            state.* = .escape;
            break :text .consume;
        } else if (isTextByte(byte)) .emit else .consume,
        .escape => if (byte == '[') escape: {
            state.* = .csi;
            break :escape .consume;
        } else if (byte == ']') escape: {
            state.* = .osc;
            break :escape .consume;
        } else if (byte == 'P' or byte == '^' or byte == '_') escape: {
            state.* = .control_string;
            break :escape .consume;
        } else if (byte >= 0x20 and byte <= 0x2f) escape: {
            state.* = .escape_intermediate;
            break :escape .consume;
        } else if (byte >= 0x30 and byte <= 0x7e) escape: {
            state.* = .text;
            break :escape .consume;
        } else escape: {
            state.* = .text;
            break :escape .reprocess;
        },
        .csi => sequence: {
            if (cancelsSequence(byte)) {
                state.* = .text;
                break :sequence .reprocess;
            }
            if (byte >= 0x40 and byte <= 0x7e) state.* = .text;
            break :sequence .consume;
        },
        .osc => sequence: {
            if (cancelsSequence(byte)) {
                state.* = .text;
                break :sequence .reprocess;
            }
            if (byte == 0x07) state.* = .text else if (byte == 0x1b) state.* = .osc_escape;
            break :sequence .consume;
        },
        .osc_escape => sequence: {
            if (byte == '\\') {
                state.* = .text;
                break :sequence .consume;
            }
            state.* = if (cancelsSequence(byte)) .text else .osc;
            break :sequence .reprocess;
        },
        .control_string => sequence: {
            if (cancelsSequence(byte)) {
                state.* = .text;
                break :sequence .reprocess;
            }
            if (byte == 0x1b) state.* = .control_string_escape;
            break :sequence .consume;
        },
        .control_string_escape => sequence: {
            if (byte == '\\') {
                state.* = .text;
                break :sequence .consume;
            }
            state.* = if (cancelsSequence(byte)) .text else .control_string;
            break :sequence .reprocess;
        },
        .escape_intermediate => sequence: {
            if (cancelsSequence(byte)) {
                state.* = .text;
                break :sequence .reprocess;
            }
            if (byte >= 0x30 and byte <= 0x7e) state.* = .text;
            break :sequence .consume;
        },
    };
}

fn isTextByte(byte: u8) bool {
    return byte == '\t' or byte == '\n' or (byte >= 0x20 and byte != 0x7f);
}

fn cancelsSequence(byte: u8) bool {
    return byte == '\n' or byte == 0x18 or byte == 0x1a;
}

test "central result sanitation repairs malformed UTF-8 and preserves hidden boundary" {
    const input = [_]u8{ 'a', 0x1b, '[', '3', '1', 'm', 0xff, 'b' };
    const result = try stripControls(std.testing.allocator, &input, 2, 64);
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", result.output);
    try std.testing.expectEqual(@as(usize, 4), result.hidden_tail_bytes);
}
