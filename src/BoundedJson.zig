const std = @import("std");

pub const Limits = struct {
    document_bytes: usize,
    value_bytes: usize,
    depth: usize,
    collection_items: usize,
};

pub const Error = error{
    OutOfMemory,
    DocumentTooLarge,
    ValueTooLarge,
    NestingTooDeep,
    CollectionTooLarge,
    InvalidJson,
};

const ContainerKind = enum { array, object };

const Frame = struct {
    kind: ContainerKind,
    item_count: usize = 0,
    object_expects_value: bool = false,
};

pub fn validate(allocator: std.mem.Allocator, source: []const u8, limits: Limits) Error!void {
    if (source.len > limits.document_bytes) return error.DocumentTooLarge;

    var scanner = std.json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);

    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.value_bytes,
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.ValueTooLarge,
            else => return error.InvalidJson,
        };
        defer freeToken(allocator, token);

        switch (token) {
            .object_begin => {
                try consumeValue(&frames, limits.collection_items);
                if (frames.items.len >= limits.depth) return error.NestingTooDeep;
                try frames.append(allocator, .{ .kind = .object });
            },
            .array_begin => {
                try consumeValue(&frames, limits.collection_items);
                if (frames.items.len >= limits.depth) return error.NestingTooDeep;
                try frames.append(allocator, .{ .kind = .array });
            },
            .object_end => {
                const frame = frames.pop().?;
                std.debug.assert(frame.kind == .object);
                std.debug.assert(!frame.object_expects_value);
            },
            .array_end => {
                const frame = frames.pop().?;
                std.debug.assert(frame.kind == .array);
            },
            .string, .allocated_string => |value| {
                if (value.len > limits.value_bytes) return error.ValueTooLarge;
                try consumeString(&frames, limits.collection_items);
            },
            .number, .allocated_number => |value| {
                if (value.len > limits.value_bytes) return error.ValueTooLarge;
                try consumeValue(&frames, limits.collection_items);
            },
            .true, .false, .null => try consumeValue(&frames, limits.collection_items),
            .end_of_document => return,
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => unreachable,
        }
    }
}

fn consumeString(frames: *std.ArrayList(Frame), maximum_items: usize) Error!void {
    if (frames.items.len == 0) return;
    const frame = &frames.items[frames.items.len - 1];
    if (frame.kind == .object and !frame.object_expects_value) {
        try incrementCollection(frame, maximum_items);
        frame.object_expects_value = true;
        return;
    }
    try consumeValue(frames, maximum_items);
}

fn consumeValue(frames: *std.ArrayList(Frame), maximum_items: usize) Error!void {
    if (frames.items.len == 0) return;
    const frame = &frames.items[frames.items.len - 1];
    switch (frame.kind) {
        .array => try incrementCollection(frame, maximum_items),
        .object => {
            std.debug.assert(frame.object_expects_value);
            frame.object_expects_value = false;
        },
    }
}

fn incrementCollection(frame: *Frame, maximum_items: usize) Error!void {
    if (frame.item_count >= maximum_items) return error.CollectionTooLarge;
    frame.item_count += 1;
}

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |value| allocator.free(value),
        else => {},
    }
}

test "bounded JSON rejects independent allocation dimensions" {
    const limits: Limits = .{
        .document_bytes = 32,
        .value_bytes = 4,
        .depth = 2,
        .collection_items = 2,
    };
    try validate(std.testing.allocator, "{\"a\":1}", limits);
    try std.testing.expectError(
        error.DocumentTooLarge,
        validate(std.testing.allocator, "{\"a\":\"01234567890123456789012345678901\"}", limits),
    );
    try std.testing.expectError(
        error.ValueTooLarge,
        validate(std.testing.allocator, "{\"a\":\"12345\"}", limits),
    );
    try std.testing.expectError(
        error.NestingTooDeep,
        validate(std.testing.allocator, "[[[]]]", limits),
    );
    try std.testing.expectError(
        error.CollectionTooLarge,
        validate(std.testing.allocator, "[1,2,3]", limits),
    );
    try std.testing.expectError(
        error.InvalidJson,
        validate(std.testing.allocator, "{", limits),
    );
}

test "bounded JSON settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validate,
        .{
            "{\"items\":[\"one\",\"two\"]}",
            Limits{
                .document_bytes = 128,
                .value_bytes = 16,
                .depth = 4,
                .collection_items = 4,
            },
        },
    );
}
