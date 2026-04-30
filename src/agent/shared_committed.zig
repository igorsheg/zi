const std = @import("std");
const protocol = @import("types.zig");
const message_memory = @import("message_memory.zig");

/// A single committed chunk of messages. Owns its string data in an
/// arena. Immutable once constructed. Refcounted.
pub const CommittedSegment = struct {
    refs: std.atomic.Value(u32),
    arena: std.heap.ArenaAllocator,
    messages: []protocol.AgentMessage,
    parent_allocator: std.mem.Allocator,

    fn init(
        parent_allocator: std.mem.Allocator,
        source: []const protocol.AgentMessage,
    ) !*CommittedSegment {
        const self = try parent_allocator.create(CommittedSegment);
        errdefer parent_allocator.destroy(self);

        self.* = .{
            .refs = .init(1),
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .messages = &.{},
            .parent_allocator = parent_allocator,
        };
        errdefer self.arena.deinit();

        const aa = self.arena.allocator();
        const owned = try aa.alloc(protocol.AgentMessage, source.len);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) message_memory.freeMessage(aa, &owned[i]);
        }
        for (source, 0..) |message, i| {
            owned[i] = try message_memory.cloneMessage(aa, message);
            initialized += 1;
        }
        self.messages = owned;
        return self;
    }

    pub fn retain(self: *CommittedSegment) *CommittedSegment {
        _ = self.refs.fetchAdd(1, .acq_rel);
        return self;
    }

    pub fn release(self: *CommittedSegment) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.arena.deinit();
            const parent = self.parent_allocator;
            parent.destroy(self);
        }
    }
};

/// A refcounted snapshot of the committed conversation. Cross-thread
/// payload shape: each publish is a single retain() of the current
/// SharedCommitted, with no deep copy.
///
/// Layout:
/// - segments: refcounted chunks. Each commit appends one segment.
///   Segments are immutable once created and live until every
///   SharedCommitted that references them releases.
/// - flat: shallow struct copies of every message across all segments,
///   in order. Strings inside these structs still point into the
///   respective segments' arenas — flat does NOT own the string data,
///   segments do. Rebuilt on every construction (O(N) pointer-level
///   copies, one-time per commit — dramatically cheaper than deep clone
///   per publish).
pub const SharedCommitted = struct {
    refs: std.atomic.Value(u32),
    segments: []*CommittedSegment,
    flat: []protocol.AgentMessage,
    parent_allocator: std.mem.Allocator,

    pub fn empty(parent_allocator: std.mem.Allocator) !*SharedCommitted {
        return try constructFromSegments(parent_allocator, &.{});
    }

    /// Build SharedCommitted from a flat slice of messages. Used on the
    /// cold rebuild paths (truncateCommitted / setMessages / reset /
    /// Agent.init with seed messages). Deep-copies messages into one
    /// new segment.
    pub fn fromMessages(
        parent_allocator: std.mem.Allocator,
        messages: []const protocol.AgentMessage,
    ) !*SharedCommitted {
        if (messages.len == 0) return empty(parent_allocator);

        const seg = try CommittedSegment.init(parent_allocator, messages);
        errdefer seg.release();
        const segs = try parent_allocator.alloc(*CommittedSegment, 1);
        segs[0] = seg;
        errdefer parent_allocator.free(segs);

        return constructFromSegments(parent_allocator, segs);
    }

    /// Hot path: produce a new SharedCommitted that extends `old` with
    /// the supplied message (deep-copied into a fresh segment). Caller
    /// is responsible for releasing `old` after swapping.
    pub fn appendMessage(
        parent_allocator: std.mem.Allocator,
        old: *SharedCommitted,
        message: protocol.AgentMessage,
    ) !*SharedCommitted {
        const new_seg = try CommittedSegment.init(parent_allocator, &[_]protocol.AgentMessage{message});
        errdefer new_seg.release();

        const seg_count = old.segments.len + 1;
        const segs = try parent_allocator.alloc(*CommittedSegment, seg_count);
        errdefer parent_allocator.free(segs);
        for (old.segments, 0..) |seg, i| segs[i] = seg.retain();
        errdefer {
            for (segs[0..old.segments.len]) |seg| seg.release();
        }
        segs[old.segments.len] = new_seg;

        return constructFromSegments(parent_allocator, segs);
    }

    pub fn retain(self: *SharedCommitted) *SharedCommitted {
        _ = self.refs.fetchAdd(1, .acq_rel);
        return self;
    }

    pub fn release(self: *SharedCommitted) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            for (self.segments) |seg| seg.release();
            self.parent_allocator.free(self.segments);
            self.parent_allocator.free(self.flat);
            const parent = self.parent_allocator;
            parent.destroy(self);
        }
    }

    fn constructFromSegments(
        parent_allocator: std.mem.Allocator,
        segments: []*CommittedSegment,
    ) !*SharedCommitted {
        const self = try parent_allocator.create(SharedCommitted);
        errdefer parent_allocator.destroy(self);

        var total: usize = 0;
        for (segments) |seg| total += seg.messages.len;

        const flat = try parent_allocator.alloc(protocol.AgentMessage, total);
        errdefer parent_allocator.free(flat);

        var offset: usize = 0;
        for (segments) |seg| {
            @memcpy(flat[offset .. offset + seg.messages.len], seg.messages);
            offset += seg.messages.len;
        }

        self.* = .{
            .refs = .init(1),
            .segments = segments,
            .flat = flat,
            .parent_allocator = parent_allocator,
        };
        return self;
    }
};

const testing = std.testing;

fn makeUserMessage(alloc: std.mem.Allocator, text: []const u8) !protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = try alloc.dupe(u8, text) },
        .timestamp = 0,
    } };
}

test "empty SharedCommitted has no messages" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const sc = try SharedCommitted.empty(alloc);
    defer sc.release();
    try testing.expectEqual(@as(usize, 0), sc.flat.len);
    try testing.expectEqual(@as(usize, 0), sc.segments.len);
}

test "fromMessages builds one segment" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const msgs = try sa.alloc(protocol.AgentMessage, 2);
    msgs[0] = try makeUserMessage(sa, "hello");
    msgs[1] = try makeUserMessage(sa, "world");

    const sc = try SharedCommitted.fromMessages(alloc, msgs);
    defer sc.release();
    try testing.expectEqual(@as(usize, 2), sc.flat.len);
    try testing.expectEqual(@as(usize, 1), sc.segments.len);
    try testing.expectEqualStrings("hello", sc.flat[0].user.content.text);
    try testing.expectEqualStrings("world", sc.flat[1].user.content.text);
}

test "appendMessage chains segments and releases old" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const first = try makeUserMessage(sa, "first");
    const sc0 = try SharedCommitted.fromMessages(alloc, &[_]protocol.AgentMessage{first});

    const second = try makeUserMessage(sa, "second");
    const sc1 = try SharedCommitted.appendMessage(alloc, sc0, second);
    sc0.release();

    try testing.expectEqual(@as(usize, 2), sc1.flat.len);
    try testing.expectEqual(@as(usize, 2), sc1.segments.len);
    try testing.expectEqualStrings("first", sc1.flat[0].user.content.text);
    try testing.expectEqualStrings("second", sc1.flat[1].user.content.text);
    sc1.release();
}

test "retain keeps shared alive after one release" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const msg = try makeUserMessage(sa, "stay");
    const sc = try SharedCommitted.fromMessages(alloc, &[_]protocol.AgentMessage{msg});
    const also = sc.retain();
    sc.release();
    try testing.expectEqualStrings("stay", also.flat[0].user.content.text);
    also.release();
}
