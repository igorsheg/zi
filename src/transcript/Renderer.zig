//! Bounded plain-text rendering of the provider-facing conversation view.
//!
//! Layout and ordering adapt hax v0.4.0's transcript renderer at the
//! revision recorded in THIRD_PARTY_NOTICES.md. Payloads remain borrowed.

const std = @import("std");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");

pub const default_max_file_bytes: usize = 256 * 1024 * 1024;
pub const default_max_segment_bytes: usize = 16 * 1024 * 1024;
pub const default_max_items: usize = 16 * 1024;
pub const default_max_tools: usize = tool.Dispatch.default_maximum_tools;

pub const Limits = struct {
    max_file_bytes: usize = default_max_file_bytes,
    max_segment_bytes: usize = default_max_segment_bytes,
    max_items: usize = default_max_items,
    max_tools: usize = default_max_tools,
};

/// Borrowed provider-facing state. Tool definitions are already advertised;
/// rendering never invokes tool capability hooks.
pub const View = struct {
    system_prompt: []const u8,
    tools: []const ai.Provider.ToolDefinition,
    items: []const ai.Item.Item,
};

pub const Cursor = struct {
    item_high_water: usize = 0,
    turn_number: u64 = 0,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    TooManyItems,
    TooManyTools,
    InvalidCursor,
    SegmentTooLarge,
    FileTooLarge,
};

pub fn preflightAll(
    allocator: std.mem.Allocator,
    view: View,
    limits: Limits,
) Error!usize {
    try validate(view, limits);
    const length = try measure(allocator, view, .{}, true, limits.max_segment_bytes);
    if (length > limits.max_file_bytes) return error.FileTooLarge;
    return length;
}

pub fn preflightSuffix(
    allocator: std.mem.Allocator,
    view: View,
    cursor: Cursor,
    remaining_bytes: usize,
    limits: Limits,
) Error!usize {
    try validate(view, limits);
    if (cursor.item_high_water > view.items.len) return error.InvalidCursor;
    const bound = @min(limits.max_segment_bytes, remaining_bytes);
    const length = measure(allocator, view, cursor, false, bound) catch |err| switch (err) {
        error.SegmentTooLarge => if (remaining_bytes < limits.max_segment_bytes)
            return error.FileTooLarge
        else
            return error.SegmentTooLarge,
        else => |other| return other,
    };
    return length;
}

pub fn renderAll(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    view: View,
    cursor: *Cursor,
    limits: Limits,
) (Error || std.Io.Writer.Error)!void {
    const length = try preflightAll(allocator, view, limits);
    var rebuilt: Cursor = .{};
    try renderSegment(allocator, writer, view, &rebuilt, true, length);
    cursor.* = rebuilt;
}

pub fn renderSuffix(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    view: View,
    cursor: *Cursor,
    limits: Limits,
) (Error || std.Io.Writer.Error)!void {
    try validate(view, limits);
    if (cursor.item_high_water > view.items.len) return error.InvalidCursor;
    const length = try measure(allocator, view, cursor.*, false, limits.max_segment_bytes);
    try renderSegment(allocator, writer, view, cursor, false, length);
}

fn validate(view: View, limits: Limits) Error!void {
    if (limits.max_file_bytes == 0 or limits.max_file_bytes > default_max_file_bytes or
        limits.max_segment_bytes == 0 or limits.max_segment_bytes > default_max_segment_bytes or
        limits.max_items == 0 or limits.max_items > default_max_items or
        limits.max_tools == 0 or limits.max_tools > default_max_tools)
    {
        return error.InvalidLimits;
    }
    if (view.items.len > limits.max_items) return error.TooManyItems;
    if (view.tools.len > limits.max_tools) return error.TooManyTools;
}

fn measure(
    allocator: std.mem.Allocator,
    view: View,
    cursor: Cursor,
    include_header: bool,
    limit: usize,
) Error!usize {
    var scratch: [256]u8 = undefined;
    const scratch_len = @min(scratch.len, limit +| 1);
    var counter: LimitedCounter = .init(scratch[0..scratch_len], limit);
    var turn_number = cursor.turn_number;
    renderRange(
        allocator,
        &counter.writer,
        view,
        cursor.item_high_water,
        include_header,
        &turn_number,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => if (counter.exceeded) return error.SegmentTooLarge else unreachable,
    };
    return counter.fullCount();
}

fn renderSegment(
    allocator: std.mem.Allocator,
    destination: *std.Io.Writer,
    view: View,
    cursor: *Cursor,
    include_header: bool,
    length: usize,
) (Error || std.Io.Writer.Error)!void {
    const segment = try allocator.alloc(u8, length);
    defer allocator.free(segment);
    var fixed: std.Io.Writer = .fixed(segment);
    var next_turn = cursor.turn_number;
    renderRange(
        allocator,
        &fixed,
        view,
        cursor.item_high_water,
        include_header,
        &next_turn,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => unreachable,
    };
    std.debug.assert(fixed.end == segment.len);
    try destination.writeAll(segment);
    cursor.* = .{ .item_high_water = view.items.len, .turn_number = next_turn };
}

const RenderError = error{ OutOfMemory, WriteFailed };

fn renderRange(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    view: View,
    first_item: usize,
    include_header: bool,
    turn_number: *u64,
) RenderError!void {
    if (include_header) try renderHeader(writer, view);
    if (first_item >= view.items.len) return;

    const rendered_results = allocator.alloc(bool, view.items.len - first_item) catch
        return error.OutOfMemory;
    defer allocator.free(rendered_results);
    @memset(rendered_results, false);

    for (view.items[first_item..], first_item..) |item, index| {
        if (item == .tool_result and rendered_results[index - first_item]) continue;
        switch (item) {
            .turn_boundary => {
                turn_number.* +|= 1;
                try renderTurnRule(writer, turn_number.*);
                continue;
            },
            .user_message => |value| try renderUser(writer, value),
            .assistant_message => |value| {
                try section(writer, "assistant");
                try textLine(writer, value.text);
            },
            .tool_call => |value| {
                try writer.print("[{s}]\n", .{if (value.name.len == 0) "?" else value.name});
                if (value.arguments_json.len != 0) {
                    try renderJsonOrText(allocator, writer, value.arguments_json);
                }
                if (findToolResult(view.items, index + 1, value.id)) |result_index| {
                    try writer.writeByte('\n');
                    try renderToolResult(writer, view.items[result_index].tool_result);
                    if (result_index >= first_item) rendered_results[result_index - first_item] = true;
                }
            },
            .tool_result => |value| try renderToolResult(writer, value),
            .reasoning => |value| try renderReasoning(allocator, writer, value),
            .turn_usage => |value| try renderUsage(writer, value),
        }
        try writer.writeByte('\n');
    }
}

fn renderHeader(writer: *std.Io.Writer, view: View) std.Io.Writer.Error!void {
    try writer.writeAll("┏");
    try repeat(writer, "━", 58);
    try writer.writeAll("┓\n");
    try writer.writeAll("┃                        TRANSCRIPT                        ┃\n");
    try writer.writeAll("┗");
    try repeat(writer, "━", 58);
    try writer.writeAll("┛\n\n");
    if (view.system_prompt.len != 0) {
        try section(writer, "system prompt");
        try textLine(writer, view.system_prompt);
        try writer.writeByte('\n');
    }
    if (view.tools.len == 0) return;
    try section(writer, "tools");
    for (view.tools, 0..) |definition, index| {
        try writer.print("[{s}]\n", .{if (definition.name.len == 0) "?" else definition.name});
        if (definition.description.len != 0) try textLine(writer, definition.description);
        try writer.writeByte('\n');
        try renderToolSchema(writer, definition);
        if (index + 1 < view.tools.len) try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn section(writer: *std.Io.Writer, label: []const u8) std.Io.Writer.Error!void {
    try writer.print("── {s} ──\n", .{label});
}

fn textLine(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try writer.writeByte('\n');
}

fn renderTurnRule(writer: *std.Io.Writer, turn_number: u64) std.Io.Writer.Error!void {
    var label_buffer: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, " # turn {d} ", .{turn_number}) catch unreachable;
    const rule_width = @max(4, 60 -| label.len);
    try repeat(writer, "─", rule_width / 2);
    try writer.writeAll(label);
    try repeat(writer, "─", rule_width - rule_width / 2);
    try writer.writeAll("\n\n");
}

fn repeat(writer: *std.Io.Writer, bytes: []const u8, count: usize) std.Io.Writer.Error!void {
    for (0..count) |_| try writer.writeAll(bytes);
}

fn renderUser(writer: *std.Io.Writer, value: ai.Item.UserMessage) std.Io.Writer.Error!void {
    try section(writer, switch (value.origin) {
        .external => "user",
        .compact_seed => "compaction seed",
        .continuation => "continuation",
        .task_note => "task update",
    });
    try textLine(writer, value.text);
}

fn renderJsonOrText(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
) RenderError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return textLine(writer, text),
    };
    defer parsed.deinit();
    std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, writer) catch
        return error.WriteFailed;
    try writer.writeByte('\n');
}

fn renderToolSchema(
    writer: *std.Io.Writer,
    definition: ai.Provider.ToolDefinition,
) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try jsonField(&json, "type", "object");
    try json.objectField("properties");
    try json.beginObject();
    for (definition.parameters) |parameter| {
        try json.objectField(parameter.name);
        try json.beginObject();
        try jsonField(&json, "type", @tagName(parameter.type));
        if (parameter.item_type) |item_type| {
            try json.objectField("items");
            try json.beginObject();
            try jsonField(&json, "type", @tagName(item_type));
            try json.endObject();
        }
        if (parameter.description.len != 0) try jsonField(&json, "description", parameter.description);
        if (parameter.minimum != 0) try jsonField(&json, "minimum", parameter.minimum);
        try json.endObject();
    }
    try json.endObject();
    var required_count: usize = 0;
    for (definition.parameters) |parameter| required_count += @intFromBool(parameter.required);
    if (required_count != 0) {
        try json.objectField("required");
        try json.beginArray();
        for (definition.parameters) |parameter| if (parameter.required) try json.write(parameter.name);
        try json.endArray();
    }
    try json.endObject();
    try writer.writeByte('\n');
}

fn jsonField(json: *std.json.Stringify, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    try json.objectField(name);
    try json.write(value);
}

fn findToolResult(items: []const ai.Item.Item, first: usize, call_id: []const u8) ?usize {
    if (call_id.len == 0) return null;
    for (items[first..], first..) |item, index| switch (item) {
        .tool_result => |value| if (std.mem.eql(u8, call_id, value.call_id)) return index,
        else => {},
    };
    return null;
}

fn renderToolResult(writer: *std.Io.Writer, value: ai.Item.ToolResult) std.Io.Writer.Error!void {
    try section(writer, "tool result");
    for (value.images) |image| try renderImage(writer, image);
    try textLine(writer, value.output);
}

fn renderImage(writer: *std.Io.Writer, image: ai.Item.Image) std.Io.Writer.Error!void {
    const decoded_bytes = image.data_base64.len / 4 * 3;
    try writer.print("[image: {s}, ", .{if (image.mime.len == 0) "image" else image.mime});
    if (image.width) |width| if (image.height) |height| if (width != 0 and height != 0) {
        try writer.print("{d}x{d}, ", .{ width, height });
    };
    if (decoded_bytes >= 1024 * 1024) {
        try writer.print("{d:.1} MiB", .{@as(f64, @floatFromInt(decoded_bytes)) / (1024.0 * 1024.0)});
    } else if (decoded_bytes >= 1024) {
        try writer.print("{d:.1} KiB", .{@as(f64, @floatFromInt(decoded_bytes)) / 1024.0});
    } else {
        try writer.print("{d} bytes", .{decoded_bytes});
    }
    try writer.writeAll("]\n");
}

fn renderReasoning(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: ai.Item.Reasoning,
) RenderError!void {
    if (value.text) |text| {
        try section(writer, "reasoning");
        try textLine(writer, text);
        return;
    }
    try writer.writeAll("[reasoning]");
    if (value.opaque_json) |opaque_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, opaque_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try writer.writeByte('\n');
                return;
            },
        };
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("id")) |id| if (id == .string) {
            try writer.print(" {s}", .{id.string});
        };
    }
    try writer.writeByte('\n');
}

fn renderUsage(writer: *std.Io.Writer, record: ai.Item.TurnUsageRecord) std.Io.Writer.Error!void {
    const usage = record.value;
    var first = true;
    if (usage.elapsed_ms) |elapsed_ms| {
        try separator(writer, &first);
        try formatDuration(writer, elapsed_ms);
    }
    if (validPositiveCost(usage.cost_total_usd)) |cost| {
        try separator(writer, &first);
        if (usage.cost_estimated) try writer.writeByte('~');
        try formatCost(writer, cost);
    }
    if (usage.stream.input_tokens != null) {
        try tokenUsage(writer, &first, "in", usage.uncached_input_tokens orelse 0, usage.cost_input_usd);
    }
    if (usage.stream.cached_tokens) |tokens| if (tokens > 0) {
        try tokenUsage(writer, &first, "cache", tokens, usage.cost_cache_read_usd);
    };
    if (usage.stream.cache_write_tokens) |tokens| if (tokens > 0) {
        try tokenUsage(writer, &first, "write", tokens, usage.cost_cache_write_usd);
    };
    if (usage.stream.output_tokens) |tokens| {
        try tokenUsage(writer, &first, "out", tokens, usage.cost_output_usd);
    }
    try writer.writeByte('\n');
    try renderProvenance(writer, record);
}

fn separator(writer: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    if (!first.*) try writer.writeAll(" · ");
    first.* = false;
}

fn tokenUsage(
    writer: *std.Io.Writer,
    first: *bool,
    label: []const u8,
    tokens: u64,
    cost_value: ?f64,
) std.Io.Writer.Error!void {
    try separator(writer, first);
    try writer.print("{s} ", .{label});
    try formatTokens(writer, tokens);
    if (cost_value) |cost| if (std.math.isFinite(cost) and cost >= 0.00005) {
        try writer.writeAll(" ~");
        try formatCost(writer, cost);
    };
}

fn renderProvenance(writer: *std.Io.Writer, record: ai.Item.TurnUsageRecord) std.Io.Writer.Error!void {
    const provenance = record.value.provenance;
    const source: ai.Item.OwnedModelIdentity = record.source orelse .{};
    const provider = nonEmpty(provenance.provider_label) orelse nonEmpty(source.provider);
    const model = nonEmpty(provenance.model_label) orelse nonEmpty(source.model);
    if (provider == null and model == null) return;
    if (provider) |value| try writer.writeAll(value);
    if (model) |value| {
        if (provider != null) try writer.writeAll(" · ");
        try writer.writeAll(value);
        if (nonEmpty(provenance.effort)) |effort| try writer.print(" · {s}", .{effort});
    }
    const served_model = nonEmpty(provenance.served_model);
    const route = nonEmpty(provenance.route);
    if (served_model != null or route != null) {
        try writer.writeAll(" → ");
        try writer.writeAll(served_model orelse route.?);
        if (served_model != null and route != null) try writer.print(" via {s}", .{route.?});
    }
    try writer.writeByte('\n');
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

fn validPositiveCost(value: ?f64) ?f64 {
    const cost = value orelse return null;
    return if (std.math.isFinite(cost) and cost > 0) cost else null;
}

fn formatTokens(writer: *std.Io.Writer, tokens: u64) std.Io.Writer.Error!void {
    const kilo: u64 = 1024;
    const mega: u64 = kilo * kilo;
    if (tokens < kilo) return writer.print("{d}", .{tokens});
    if (tokens < 10 * kilo) {
        return writer.print("{d:.1}k", .{@as(f64, @floatFromInt(tokens)) / 1024.0});
    }
    if (tokens < mega) return writer.print("{d}k", .{tokens / kilo + @intFromBool(tokens % kilo >= kilo / 2)});
    if (tokens < 10 * mega) {
        return writer.print("{d:.1}M", .{@as(f64, @floatFromInt(tokens)) / (1024.0 * 1024.0)});
    }
    return writer.print("{d}M", .{tokens / mega + @intFromBool(tokens % mega >= mega / 2)});
}

fn formatDuration(writer: *std.Io.Writer, elapsed_ms: u64) std.Io.Writer.Error!void {
    const seconds = elapsed_ms / 1000 + @intFromBool(elapsed_ms % 1000 >= 500);
    if (seconds < 60) return writer.print("{d}s", .{seconds});
    if (seconds < 3600 and seconds % 60 == 0) return writer.print("{d}m", .{seconds / 60});
    if (seconds < 3600) return writer.print("{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 });
    if (seconds % 3600 == 0) return writer.print("{d}h", .{seconds / 3600});
    return writer.print("{d}h {d:0>2}m", .{ seconds / 3600, seconds % 3600 / 60 });
}

fn formatCost(writer: *std.Io.Writer, cost: f64) std.Io.Writer.Error!void {
    if (cost <= 0) return writer.writeAll("$0.00");
    if (cost < 0.01) return writer.print("${d:.4}", .{cost});
    if (cost < 1) return writer.print("${d:.3}", .{cost});
    return writer.print("${d:.2}", .{cost});
}

const LimitedCounter = struct {
    count: usize = 0,
    limit: usize,
    exceeded: bool = false,
    writer: std.Io.Writer,

    fn init(buffer: []u8, limit: usize) LimitedCounter {
        return .{ .limit = limit, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn fullCount(self: *const LimitedCounter) usize {
        return self.count + self.writer.end;
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedCounter = @alignCast(@fieldParentPtr("writer", writer));
        var written = std.math.mul(usize, data[data.len - 1].len, splat) catch return self.fail();
        for (data[0 .. data.len - 1]) |bytes| {
            written = std.math.add(usize, written, bytes.len) catch return self.fail();
        }
        const buffered = std.math.add(usize, self.count, writer.end) catch return self.fail();
        const total = std.math.add(usize, buffered, written) catch return self.fail();
        if (total > self.limit) return self.fail();
        self.count = total;
        writer.end = 0;
        return written;
    }

    fn fail(self: *LimitedCounter) std.Io.Writer.Error {
        self.exceeded = true;
        return error.WriteFailed;
    }
};

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

fn renderAllForTest(view: View, limits: Limits) ![]u8 {
    const length = try preflightAll(std.testing.allocator, view, limits);
    const output = try std.testing.allocator.alloc(u8, length);
    errdefer std.testing.allocator.free(output);
    var writer: std.Io.Writer = .fixed(output);
    var cursor: Cursor = .{};
    try renderAll(std.testing.allocator, &writer, view, &cursor, limits);
    try std.testing.expectEqual(output.len, writer.end);
    try std.testing.expectEqual(view.items.len, cursor.item_high_water);
    return output;
}

test "plain transcript renders hax header, tools, roles, and paired results" {
    const parameters = [_]ai.Provider.ToolParameter{.{
        .name = "path",
        .type = .string,
        .description = "File path.",
        .required = true,
    }};
    const definitions = [_]ai.Provider.ToolDefinition{.{
        .name = "read",
        .description = "Read a file.",
        .parameters = &parameters,
    }};
    const items = [_]ai.Item.Item{
        .turn_boundary,
        .{ .user_message = .{ .text = mutable("inspect") } },
        .{ .tool_call = .{
            .id = mutable("secret-call"),
            .name = mutable("read"),
            .arguments_json = mutable("{\"path\":\"a.zig\"}"),
        } },
        .{ .tool_call = .{
            .id = mutable("other-call"),
            .name = mutable("read"),
            .arguments_json = mutable("{\"path\":\"b.zig\"}"),
        } },
        .{ .tool_result = .{ .call_id = mutable("secret-call"), .output = mutable("A") } },
        .{ .tool_result = .{ .call_id = mutable("other-call"), .output = mutable("B") } },
        .{ .assistant_message = .{ .text = mutable("done") } },
    };
    const output = try renderAllForTest(.{
        .system_prompt = "system",
        .tools = &definitions,
        .items = &items,
    }, .{});
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "┏"));
    try std.testing.expect(std.mem.find(u8, output, "# turn 1") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"required\": [\n    \"path\"") != null);
    const a_path = std.mem.find(u8, output, "a.zig").?;
    const a_body = std.mem.find(u8, output, "\nA\n").?;
    const b_path = std.mem.find(u8, output, "b.zig").?;
    const b_body = std.mem.find(u8, output, "\nB\n").?;
    try std.testing.expect(a_path < a_body);
    try std.testing.expect(a_body < b_path);
    try std.testing.expect(b_path < b_body);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\nA\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\nB\n"));
    try std.testing.expect(std.mem.find(u8, output, "secret-call") == null);
    try std.testing.expect(std.mem.find(u8, output, "\x1b[") == null);
}

test "reasoning and images omit opaque payloads and base64" {
    const images = [_]ai.Item.Image{.{
        .mime = mutable("image/png"),
        .data_base64 = mutable("QUJDRA=="),
        .width = 10,
        .height = 20,
    }};
    const items = [_]ai.Item.Item{
        .{ .reasoning = .{ .opaque_json = mutable(
            "{\"id\":\"rs_visible\",\"encrypted_content\":\"opaque-secret\"}",
        ) } },
        .{ .tool_result = .{
            .call_id = mutable("call-hidden"),
            .output = mutable("result"),
            .images = @constCast(&images),
        } },
    };
    const output = try renderAllForTest(.{ .system_prompt = "", .tools = &.{}, .items = &items }, .{});
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.find(u8, output, "[reasoning] rs_visible") != null);
    try std.testing.expect(std.mem.find(u8, output, "opaque-secret") == null);
    try std.testing.expect(std.mem.find(u8, output, "QUJDRA==") == null);
    try std.testing.expect(std.mem.find(u8, output, "[image: image/png, 10x20, 6 bytes]") != null);
    try std.testing.expect(std.mem.find(u8, output, "call-hidden") == null);
}

test "usage footer preserves accounting and provenance but omits response id" {
    const items = [_]ai.Item.Item{.{ .turn_usage = .{
        .value = .{
            .stream = .{
                .input_tokens = 3072,
                .output_tokens = 512,
                .cached_tokens = 1024,
            },
            .elapsed_ms = 42_000,
            .uncached_input_tokens = 2048,
            .cost_input_usd = 0.025,
            .cost_cache_read_usd = 0.048,
            .cost_output_usd = 0.084,
            .cost_total_usd = 0.157,
            .cost_estimated = true,
            .provenance = .{
                .provider_label = mutable("OpenRouter"),
                .model_label = mutable("model"),
                .effort = mutable("high"),
                .served_model = mutable("served"),
                .route = mutable("route"),
                .response_id = mutable("response-secret"),
            },
        },
    } }};
    const output = try renderAllForTest(.{ .system_prompt = "", .tools = &.{}, .items = &items }, .{});
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.find(
        u8,
        output,
        "42s · ~$0.157 · in 2.0k ~$0.025 · cache 1.0k ~$0.048 · out 512 ~$0.084",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        output,
        "OpenRouter · model · high → served via route",
    ) != null);
    try std.testing.expect(std.mem.find(u8, output, "response-secret") == null);
}

test "suffix is exact, advances only after write, and keeps turn numbering" {
    const first = [_]ai.Item.Item{
        .turn_boundary,
        .{ .user_message = .{ .text = mutable("one") } },
    };
    var cursor: Cursor = .{};
    var all_buffer: [1024]u8 = undefined;
    var all_writer: std.Io.Writer = .fixed(&all_buffer);
    try renderAll(std.testing.allocator, &all_writer, .{
        .system_prompt = "",
        .tools = &.{},
        .items = &first,
    }, &cursor, .{});
    try std.testing.expectEqual(@as(u64, 1), cursor.turn_number);

    const extended = [_]ai.Item.Item{
        first[0],
        first[1],
        .turn_boundary,
        .{ .assistant_message = .{ .text = mutable("two") } },
    };
    const suffix_view: View = .{ .system_prompt = "", .tools = &.{}, .items = &extended };
    const suffix_len = try preflightSuffix(std.testing.allocator, suffix_view, cursor, 512, .{});
    var suffix_buffer: [512]u8 = undefined;
    var suffix_writer: std.Io.Writer = .fixed(&suffix_buffer);
    try renderSuffix(std.testing.allocator, &suffix_writer, suffix_view, &cursor, .{});
    try std.testing.expectEqual(suffix_len, suffix_writer.end);
    try std.testing.expect(std.mem.find(u8, suffix_writer.buffered(), "# turn 2") != null);
    try std.testing.expect(std.mem.find(u8, suffix_writer.buffered(), "TRANSCRIPT") == null);
    try std.testing.expectEqual(@as(usize, 4), cursor.item_high_water);
    try std.testing.expectEqual(@as(u64, 2), cursor.turn_number);

    const saved = cursor;
    var tiny: [1]u8 = undefined;
    var failing_writer: std.Io.Writer = .fixed(&tiny);
    cursor.item_high_water = 2;
    cursor.turn_number = 1;
    try std.testing.expectError(
        error.WriteFailed,
        renderSuffix(std.testing.allocator, &failing_writer, suffix_view, &cursor, .{}),
    );
    try std.testing.expectEqual(@as(usize, 2), cursor.item_high_water);
    try std.testing.expectEqual(@as(u64, 1), cursor.turn_number);
    cursor = saved;
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const items = [_]ai.Item.Item{
        .{ .tool_call = .{
            .id = mutable("call"),
            .name = mutable("read"),
            .arguments_json = mutable("{\"path\":\"a.zig\"}"),
        } },
        .{ .tool_result = .{ .call_id = mutable("call"), .output = mutable("body") } },
        .{ .reasoning = .{ .opaque_json = mutable("{\"id\":\"reasoning-id\"}") } },
    };
    const view: View = .{ .system_prompt = "system", .tools = &.{}, .items = &items };
    _ = try preflightAll(allocator, view, .{});
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    var cursor: Cursor = .{};
    try renderAll(allocator, &writer, view, &cursor, .{});
}

test "renderer frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "preflight rejects every configured bound before output" {
    const item: ai.Item.Item = .{ .assistant_message = .{ .text = mutable("large body") } };
    const items = [_]ai.Item.Item{ item, item };
    const view: View = .{ .system_prompt = "", .tools = &.{}, .items = items[0..1] };
    try std.testing.expectError(error.SegmentTooLarge, preflightAll(
        std.testing.allocator,
        view,
        .{ .max_segment_bytes = 8 },
    ));
    try std.testing.expectError(error.FileTooLarge, preflightAll(
        std.testing.allocator,
        view,
        .{ .max_file_bytes = 8 },
    ));
    try std.testing.expectError(error.FileTooLarge, preflightSuffix(
        std.testing.allocator,
        view,
        .{},
        1,
        .{},
    ));
    try std.testing.expectError(error.TooManyItems, preflightAll(
        std.testing.allocator,
        .{ .system_prompt = "", .tools = &.{}, .items = &items },
        .{ .max_items = 1 },
    ));
}
