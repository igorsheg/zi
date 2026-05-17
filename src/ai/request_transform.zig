const std = @import("std");
const json_value = @import("../json/value.zig");

const json_util = @import("json_util.zig");
const protocol = @import("protocol.zig");

pub const Decorator = struct {
    func: *const fn (
        allocator: std.mem.Allocator,
        payload: *std.json.Value,
        model: *const protocol.Model,
        ctx: ?*anyopaque,
    ) anyerror!bool,
    ctx: ?*anyopaque = null,

    pub fn call(
        self: Decorator,
        allocator: std.mem.Allocator,
        payload: *std.json.Value,
        model: *const protocol.Model,
    ) !bool {
        return self.func(allocator, payload, model, self.ctx);
    }
};

pub const TransformOptions = struct {
    model: *const protocol.Model,
    stream_options: protocol.StreamOptions = .{},
    decorators: []const Decorator = &.{},
};

pub fn transformJsonPayload(
    allocator: std.mem.Allocator,
    canonical: []const u8,
    options: TransformOptions,
) !?[]u8 {
    if (options.decorators.len == 0 and options.stream_options.on_payload == null) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var payload = try std.json.parseFromSliceLeaky(std.json.Value, temp, canonical, .{ .allocate = .alloc_always });
    if (payload != .object) return error.NonObjectPayload;

    var changed = false;
    for (options.decorators) |decorator| {
        changed = try decorator.call(temp, &payload, options.model) or changed;
    }

    var replacement: ?std.json.Value = null;
    defer if (replacement) |value| json_value.freeJsonValue(allocator, value);

    const final_payload = blk: {
        if (options.stream_options.on_payload) |hook| {
            if (hook(temp, payload, options.model, options.stream_options.on_payload_ctx)) |next| {
                replacement = try json_value.cloneJsonValue(allocator, next);
                changed = true;
                break :blk replacement.?;
            }
        }
        break :blk payload;
    };

    if (!changed) return null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(final_payload, .{}, &out.writer);
    return try allocator.dupe(u8, out.written());
}

const testing = std.testing;

fn testModel() protocol.Model {
    return .{
        .id = "test-model",
        .name = "test model",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    };
}

test "request transform skips parsing when no hooks are registered" {
    const model = testModel();
    const transformed = try transformJsonPayload(testing.allocator, "not json", .{ .model = &model });
    try testing.expect(transformed == null);
}

test "request transform applies provider decorators to canonical json" {
    const model = testModel();
    const AddMetadata = struct {
        fn decorate(
            allocator: std.mem.Allocator,
            payload: *std.json.Value,
            _: *const protocol.Model,
            _: ?*anyopaque,
        ) !bool {
            try payload.object.put(allocator, "metadata", .{ .object = .{} });
            return true;
        }
    };

    const transformed = try transformJsonPayload(testing.allocator, "{\"model\":\"a\"}", .{
        .model = &model,
        .decorators = &.{.{ .func = AddMetadata.decorate }},
    });
    defer testing.allocator.free(transformed.?);

    try testing.expect(std.mem.indexOf(u8, transformed.?, "\"metadata\":{") != null);
}

test "request transform clones on_payload replacements before stringifying" {
    const model = testModel();
    const Replace = struct {
        fn replace(allocator: std.mem.Allocator, payload: std.json.Value, _: *const protocol.Model, _: ?*anyopaque) ?std.json.Value {
            _ = payload;
            return .{ .string = allocator.dupe(u8, "replacement") catch return null };
        }
    };

    const transformed = try transformJsonPayload(testing.allocator, "{\"model\":\"a\"}", .{
        .model = &model,
        .stream_options = .{ .on_payload = Replace.replace },
    });
    defer testing.allocator.free(transformed.?);

    try testing.expectEqualStrings("\"replacement\"", transformed.?);
}
