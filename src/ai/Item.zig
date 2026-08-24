const std = @import("std");
const Usage = @import("Usage.zig");

pub const UserOrigin = enum {
    external,
    compact_seed,
    continuation,
    task_note,
};

pub const AssistantOrigin = enum {
    external,
    interrupted,
};

pub const ToolResultOrigin = enum {
    external,
    skipped,
    refused,
    summarized,
};

pub const Image = struct {
    mime: []u8,
    data_base64: []u8,
    width: ?u32 = null,
    height: ?u32 = null,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.mime);
        allocator.free(self.data_base64);
        self.* = undefined;
    }
};

pub const UserMessage = struct {
    text: []u8,
    images: []Image = &.{},
    origin: UserOrigin = .external,
};

pub const AssistantMessage = struct {
    text: []u8,
    origin: AssistantOrigin = .external,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,
};

pub const ToolResult = struct {
    call_id: []u8,
    output: []u8,
    hidden_tail_bytes: usize = 0,
    images: []Image = &.{},
    origin: ToolResultOrigin = .external,
};

pub const OwnedModelIdentity = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const Reasoning = struct {
    opaque_json: ?[]u8 = null,
    text: ?[]u8 = null,
    source: ?OwnedModelIdentity = null,
};

pub const TurnUsageRecord = struct {
    value: Usage.TurnUsage,
    source: ?OwnedModelIdentity = null,
};

/// One owned provider-independent conversation record.
/// Every byte slice belongs to the item and is released by `deinit`.
pub const Item = union(enum) {
    user_message: UserMessage,
    assistant_message: AssistantMessage,
    tool_call: ToolCall,
    tool_result: ToolResult,
    reasoning: Reasoning,
    turn_boundary,
    turn_usage: TurnUsageRecord,

    pub fn clone(self: Item, allocator: std.mem.Allocator) error{OutOfMemory}!Item {
        return switch (self) {
            .user_message => |value| user: {
                const text = try allocator.dupe(u8, value.text);
                errdefer allocator.free(text);
                break :user .{ .user_message = .{
                    .text = text,
                    .images = try cloneImages(allocator, value.images),
                    .origin = value.origin,
                } };
            },
            .assistant_message => |value| .{ .assistant_message = .{
                .text = try allocator.dupe(u8, value.text),
                .origin = value.origin,
            } },
            .tool_call => |value| call: {
                const id = try allocator.dupe(u8, value.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, value.name);
                errdefer allocator.free(name);
                const arguments_json = try allocator.dupe(u8, value.arguments_json);
                break :call .{ .tool_call = .{
                    .id = id,
                    .name = name,
                    .arguments_json = arguments_json,
                } };
            },
            .tool_result => |value| result: {
                const call_id = try allocator.dupe(u8, value.call_id);
                errdefer allocator.free(call_id);
                const output = try allocator.dupe(u8, value.output);
                errdefer allocator.free(output);
                const images = try cloneImages(allocator, value.images);
                break :result .{ .tool_result = .{
                    .call_id = call_id,
                    .output = output,
                    .hidden_tail_bytes = value.hidden_tail_bytes,
                    .images = images,
                    .origin = value.origin,
                } };
            },
            .reasoning => |value| .{ .reasoning = try cloneReasoning(allocator, value) },
            .turn_boundary => .turn_boundary,
            .turn_usage => |value| usage: {
                const cloned_usage = try value.value.clone(allocator);
                errdefer {
                    var cleanup = cloned_usage;
                    cleanup.deinit(allocator);
                }
                break :usage .{ .turn_usage = .{
                    .value = cloned_usage,
                    .source = try cloneIdentity(allocator, value.source),
                } };
            },
        };
    }

    /// Clones one item and replaces reasoning provenance in the cloned owner.
    pub fn cloneWithReasoningSource(
        self: Item,
        allocator: std.mem.Allocator,
        provider: ?[]const u8,
        model: ?[]const u8,
    ) error{OutOfMemory}!Item {
        var result = try self.clone(allocator);
        errdefer result.deinit(allocator);
        if (result != .reasoning) return result;
        const source = try cloneIdentity(allocator, if (provider != null or model != null)
            OwnedModelIdentity{ .provider = provider, .model = model }
        else
            null);
        if (result.reasoning.source) |old_source| deinitIdentity(allocator, old_source);
        result.reasoning.source = source;
        return result;
    }

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .user_message => |value| {
                allocator.free(value.text);
                deinitImages(allocator, value.images);
            },
            .assistant_message => |value| allocator.free(value.text),
            .tool_call => |value| {
                allocator.free(value.id);
                allocator.free(value.name);
                allocator.free(value.arguments_json);
            },
            .tool_result => |value| {
                allocator.free(value.call_id);
                allocator.free(value.output);
                deinitImages(allocator, value.images);
            },
            .reasoning => |value| {
                if (value.opaque_json) |opaque_json| allocator.free(opaque_json);
                if (value.text) |text| allocator.free(text);
                if (value.source) |source| deinitIdentity(allocator, source);
            },
            .turn_boundary => {},
            .turn_usage => |*value| {
                value.value.deinit(allocator);
                if (value.source) |source| deinitIdentity(allocator, source);
            },
        }
        self.* = undefined;
    }
};

fn cloneImages(allocator: std.mem.Allocator, images: []const Image) error{OutOfMemory}![]Image {
    if (images.len == 0) return &.{};
    const result = try allocator.alloc(Image, images.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*image| image.deinit(allocator);
        allocator.free(result);
    }
    for (images, 0..) |image, index| {
        const mime = try allocator.dupe(u8, image.mime);
        errdefer allocator.free(mime);
        result[index] = .{
            .mime = mime,
            .data_base64 = try allocator.dupe(u8, image.data_base64),
            .width = image.width,
            .height = image.height,
        };
        initialized += 1;
    }
    return result;
}

fn cloneIdentity(
    allocator: std.mem.Allocator,
    source: ?OwnedModelIdentity,
) error{OutOfMemory}!?OwnedModelIdentity {
    const value = source orelse return null;
    const provider = if (value.provider) |provider| try allocator.dupe(u8, provider) else null;
    errdefer if (provider) |owned| allocator.free(owned);
    const model = if (value.model) |model| try allocator.dupe(u8, model) else null;
    return .{ .provider = provider, .model = model };
}

fn deinitIdentity(allocator: std.mem.Allocator, identity: OwnedModelIdentity) void {
    if (identity.provider) |provider| allocator.free(provider);
    if (identity.model) |model| allocator.free(model);
}

fn cloneReasoning(allocator: std.mem.Allocator, value: Reasoning) error{OutOfMemory}!Reasoning {
    var result: Reasoning = .{};
    errdefer {
        if (result.opaque_json) |opaque_json| allocator.free(opaque_json);
        if (result.text) |text| allocator.free(text);
        if (result.source) |source| deinitIdentity(allocator, source);
    }
    if (value.opaque_json) |opaque_json| result.opaque_json = try allocator.dupe(u8, opaque_json);
    if (value.text) |text| result.text = try allocator.dupe(u8, text);
    result.source = try cloneIdentity(allocator, value.source);
    return result;
}

fn deinitImages(allocator: std.mem.Allocator, images: []Image) void {
    for (images) |*image| image.deinit(allocator);
    if (images.len != 0) allocator.free(images);
}

pub fn deinitSlice(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn retainedBytes(item: Item) usize {
    return switch (item) {
        .user_message => |value| value.text.len +| imageRetainedBytes(value.images),
        .assistant_message => |value| value.text.len,
        .tool_call => |value| value.id.len +| value.name.len +| value.arguments_json.len,
        .tool_result => |value| value.call_id.len +| value.output.len +| imageRetainedBytes(value.images),
        .reasoning => |value| optionalBytes(value.opaque_json) +|
            optionalBytes(value.text) +| identityBytes(value.source),
        .turn_boundary => 0,
        .turn_usage => |value| usageRetainedBytes(value),
    };
}

fn imageRetainedBytes(images: []const Image) usize {
    var total: usize = 0;
    for (images) |image| total +|= image.mime.len +| image.data_base64.len;
    return total;
}

fn usageRetainedBytes(record: TurnUsageRecord) usize {
    const provenance = record.value.provenance;
    return optionalBytes(provenance.provider_label) +|
        optionalBytes(provenance.model_label) +|
        optionalBytes(provenance.effort) +|
        optionalBytes(provenance.served_model) +|
        optionalBytes(provenance.route) +|
        optionalBytes(provenance.response_id) +|
        identityBytes(record.source);
}

fn identityBytes(identity: ?OwnedModelIdentity) usize {
    const value = identity orelse return 0;
    return optionalBytes(value.provider) +| optionalBytes(value.model);
}

fn optionalBytes(value: anytype) usize {
    return if (value) |bytes| bytes.len else 0;
}

pub fn imageBase64Bytes(items: []const Item) usize {
    var total: usize = 0;
    for (items) |item| {
        const images: []const Image = switch (item) {
            .user_message => |value| value.images,
            .tool_result => |value| value.images,
            else => continue,
        };
        for (images) |image| total +|= image.data_base64.len;
    }
    return total;
}

pub fn imageCount(items: []const Item) usize {
    var total: usize = 0;
    for (items) |item| total +|= switch (item) {
        .user_message => |value| value.images.len,
        .tool_result => |value| value.images.len,
        else => 0,
    };
    return total;
}

/// Returns the newest compaction seed index, or zero when none exists.
pub fn contextFloor(items: []const Item) usize {
    var floor: usize = 0;
    for (items, 0..) |item, index| switch (item) {
        .user_message => |value| if (value.origin == .compact_seed) {
            floor = index;
        },
        else => {},
    };
    return floor;
}

test "item variants own record-specific payloads" {
    const allocator = std.testing.allocator;
    const images = try allocator.alloc(Image, 1);
    images[0] = .{
        .mime = try allocator.dupe(u8, "image/png"),
        .data_base64 = try allocator.dupe(u8, "AAAA"),
        .width = 1,
        .height = 1,
    };
    var result: Item = .{ .tool_result = .{
        .call_id = try allocator.dupe(u8, "call"),
        .output = try allocator.dupe(u8, "output"),
        .hidden_tail_bytes = 2,
        .images = images,
        .origin = .summarized,
    } };
    defer result.deinit(allocator);

    try std.testing.expectEqual(ToolResultOrigin.summarized, result.tool_result.origin);
    try std.testing.expectEqualStrings("image/png", result.tool_result.images[0].mime);
}

test "assistant origin cannot be confused with user or tool-result origins" {
    const allocator = std.testing.allocator;
    var item: Item = .{ .assistant_message = .{
        .text = try allocator.dupe(u8, "partial"),
        .origin = .interrupted,
    } };
    defer item.deinit(allocator);

    try std.testing.expectEqual(AssistantOrigin.interrupted, item.assistant_message.origin);
    try std.testing.expectEqualStrings("partial", item.assistant_message.text);
}

test "image accounting covers user and tool-result items" {
    var user_data = [_]u8{ '1', '2', '3' };
    var result_data = [_]u8{ '4', '5', '6', '7' };
    var user_images = [_]Image{.{ .mime = undefined, .data_base64 = &user_data }};
    var result_images = [_]Image{.{ .mime = undefined, .data_base64 = &result_data }};
    const items = [_]Item{
        .{ .user_message = .{ .text = undefined, .images = &user_images } },
        .{ .assistant_message = .{ .text = undefined } },
        .{ .tool_result = .{
            .call_id = undefined,
            .output = undefined,
            .images = &result_images,
        } },
    };

    try std.testing.expectEqual(@as(usize, 2), imageCount(&items));
    try std.testing.expectEqual(@as(usize, 7), imageBase64Bytes(&items));
}

test "context floor selects the newest compact seed" {
    const items = [_]Item{
        .turn_boundary,
        .{ .user_message = .{ .text = undefined, .origin = .compact_seed } },
        .{ .assistant_message = .{ .text = undefined } },
        .{ .user_message = .{ .text = undefined, .origin = .compact_seed } },
    };
    try std.testing.expectEqual(@as(usize, 3), contextFloor(&items));
    try std.testing.expectEqual(@as(usize, 0), contextFloor(items[0..1]));
}

fn exerciseCloneAllocationPaths(allocator: std.mem.Allocator) !void {
    var mime = [_]u8{ 'i', 'm', 'a', 'g', 'e', '/', 'p', 'n', 'g' };
    var data = [_]u8{ 'A', 'A', 'A', 'A' };
    var images = [_]Image{.{ .mime = &mime, .data_base64 = &data, .width = 1, .height = 1 }};
    var call_id = [_]u8{ 'c', 'a', 'l', 'l' };
    var output = [_]u8{ 'o', 'u', 't' };
    const result: Item = .{ .tool_result = .{
        .call_id = &call_id,
        .output = &output,
        .images = &images,
    } };
    var cloned_result = try result.clone(allocator);
    cloned_result.deinit(allocator);

    var opaque_json = [_]u8{ '{', '}' };
    var text = [_]u8{ 'w', 'h', 'y' };
    var provider = [_]u8{'p'};
    var model = [_]u8{'m'};
    const reasoning: Item = .{ .reasoning = .{
        .opaque_json = &opaque_json,
        .text = &text,
        .source = .{ .provider = &provider, .model = &model },
    } };
    var cloned_reasoning = try reasoning.clone(allocator);
    cloned_reasoning.deinit(allocator);

    var label = [_]u8{ 'l', 'a', 'b', 'e', 'l' };
    const usage: Item = .{ .turn_usage = .{
        .value = .{ .provenance = .{ .provider_label = &label } },
        .source = .{ .provider = &provider, .model = &model },
    } };
    var cloned_usage = try usage.clone(allocator);
    cloned_usage.deinit(allocator);
}

test "item clone frees every partial nested allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCloneAllocationPaths,
        .{},
    );
}
