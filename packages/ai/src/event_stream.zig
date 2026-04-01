const std = @import("std");
const types = @import("types.zig");

/// Generic event stream for async event processing.
/// T = event type, R = final result type
pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        queue: std.ArrayList(T),
        done: bool,
        final_result: ?R,
        result_available: bool,
        is_complete_fn: *const fn (T) bool,
        extract_result_fn: *const fn (T) R,

        pub fn init(
            allocator: std.mem.Allocator,
            is_complete: *const fn (T) bool,
            extract_result: *const fn (T) R,
        ) Self {
            return Self{
                .allocator = allocator,
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .queue = std.ArrayList(T).init(allocator),
                .done = false,
                .final_result = null,
                .result_available = false,
                .is_complete_fn = is_complete,
                .extract_result_fn = extract_result,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        /// Push an event to the stream.
        /// If the event is complete, the stream is marked as done.
        pub fn push(self: *Self, event: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.done) return;

            if (self.is_complete_fn(event)) {
                self.done = true;
                self.final_result = self.extract_result_fn(event);
                self.result_available = true;
            }

            self.queue.append(event) catch return;
            self.condition.signal();
        }

        /// End the stream with an optional final result.
        pub fn end(self: *Self, r: ?R) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.done = true;
            if (r) |res| {
                self.final_result = res;
                self.result_available = true;
            }
            self.condition.broadcast();
        }

        /// Get the next event from the stream.
        /// Blocks until an event is available or the stream ends.
        /// Returns null when the stream is done and queue is empty.
        pub fn next(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.queue.items.len > 0) {
                    return self.queue.orderedRemove(0);
                }

                if (self.done) {
                    return null;
                }

                self.condition.wait(&self.mutex);
            }
        }

        /// Get the final result.
        /// Blocks until the result is available.
        pub fn result(self: *Self) R {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.result_available) {
                self.condition.wait(&self.mutex);
            }

            return self.final_result.?;
        }
    };
}

/// Check if an AssistantMessageEvent indicates completion
fn isAssistantMessageEventComplete(event: types.AssistantMessageEvent) bool {
    return switch (event) {
        .done, .@"error" => true,
        else => false,
    };
}

/// Extract the final AssistantMessage from a complete event
fn extractAssistantMessageResult(event: types.AssistantMessageEvent) types.AssistantMessage {
    return switch (event) {
        .done => |done| done.message,
        .@"error" => |err| err.@"error",
        else => unreachable,
    };
}

/// Specialization for AssistantMessage events
pub const AssistantMessageEventStream = EventStream(types.AssistantMessageEvent, types.AssistantMessage);

/// Factory function for AssistantMessageEventStream
pub fn createAssistantMessageEventStream(allocator: std.mem.Allocator) AssistantMessageEventStream {
    return AssistantMessageEventStream.init(
        allocator,
        isAssistantMessageEventComplete,
        extractAssistantMessageResult,
    );
}
