const std = @import("std");
const json_value = @import("../json/value.zig");

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
    stream_options: protocol.StreamOptions,
    decorators: []const Decorator = &.{},
};

pub fn transformJsonPayload(
    allocator: std.mem.Allocator,
    canonical: []const u8,
    options: TransformOptions,
) !?[]u8 {
    if (options.decorators.len == 0 and options.stream_options.request_transform == null) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var payload = try std.json.parseFromSliceLeaky(std.json.Value, temp, canonical, .{ .allocate = .alloc_always });
    if (payload != .object) return error.NonObjectPayload;

    var changed = false;
    for (options.decorators) |decorator| {
        changed = try decorator.call(temp, &payload, options.model) or changed;
    }

    var replacement: ?json_value.OwnedValue = null;
    defer if (replacement) |*value| value.deinit();

    const final_payload = blk: {
        if (options.stream_options.request_transform) |transform| {
            if (try transform.apply(temp, payload, options.model)) |next| {
                replacement = try json_value.OwnedValue.clone(allocator, next.borrowed());
                changed = true;
                break :blk replacement.?.borrowed();
            }
        }
        break :blk payload;
    };

    if (!changed) return null;

    _ = final_payload;
    return error.UnsupportedTransformSerialization;
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
            payload: *json_value.OwnedValue,
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

test "request transform clones replacements before stringifying" {
    const model = testModel();
    const Replace = struct {
        fn replace(allocator: std.mem.Allocator, payload: json_value.BorrowedValue, _: *const protocol.Model, _: ?*anyopaque) error{OutOfMemory}!?json_value.OwnedValue {
            _ = payload;
            return .{ .string = try allocator.dupe(u8, "replacement") };
        }
    };

    const transformed = try transformJsonPayload(testing.allocator, "{\"model\":\"a\"}", .{
        .model = &model,
        .stream_options = .{ .request_transform = .{ .func = Replace.replace } },
    });
    defer testing.allocator.free(transformed.?);

    try testing.expectEqualStrings("\"replacement\"", transformed.?);
}

test "request transform reports transform allocation failure" {
    const model = testModel();
    const Fails = struct {
        fn replace(_: std.mem.Allocator, _: json_value.BorrowedValue, _: *const protocol.Model, _: ?*anyopaque) error{OutOfMemory}!?json_value.OwnedValue {
            return error.OutOfMemory;
        }
    };

    try testing.expectError(error.OutOfMemory, transformJsonPayload(testing.allocator, "{\"model\":\"a\"}", .{
        .model = &model,
        .stream_options = .{ .request_transform = .{ .func = Fails.replace } },
    }));
}
