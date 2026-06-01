const std = @import("std");

pub const BlockId = enum(u64) {
    _,
};

pub const BlockState = enum {
    open,
    sealed,
};

pub const Block = struct {
    id: BlockId,
    sequence: u64,
    state: BlockState = .open,
    revision: u64 = 0,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }
};

pub const Options = struct {
    block_count_max: usize = 1024,
    resident_size_bytes_max: usize = 4 * 1024 * 1024,
    block_size_bytes_max: usize = 64 * 1024,
};

pub const Document = struct {
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    resident_size_bytes: usize = 0,
    next_id: u64 = 1,
    options: Options = .{},

    pub fn init(options: Options) Document {
        std.debug.assert(options.block_count_max > 0);
        std.debug.assert(options.block_size_bytes_max > 0);
        std.debug.assert(options.resident_size_bytes_max >= options.block_size_bytes_max);
        return .{ .options = options };
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*entry| entry.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendBlock(self: *Document, allocator: std.mem.Allocator) !BlockId {
        if (self.blocks.items.len == self.options.block_count_max) return error.DocumentBlockLimitReached;
        const id: BlockId = @enumFromInt(self.next_id);
        self.next_id += 1;
        try self.blocks.append(allocator, .{
            .id = id,
            .sequence = self.blocks.items.len,
        });
        return id;
    }

    pub fn removeTailBlock(self: *Document, allocator: std.mem.Allocator, expected_id: BlockId) !void {
        if (self.blocks.items.len == 0) return error.DocumentBlockNotFound;
        const tail_index = self.blocks.items.len - 1;
        if (self.blocks.items[tail_index].id != expected_id) return error.DocumentBlockNotTail;
        self.resident_size_bytes -= self.blocks.items[tail_index].bytes.items.len;
        self.blocks.items[tail_index].deinit(allocator);
        _ = self.blocks.pop();
    }

    pub fn appendText(self: *Document, allocator: std.mem.Allocator, id: BlockId, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const entry = self.blockPtr(id) orelse return error.DocumentBlockNotFound;
        if (entry.state != .open) return error.DocumentBlockSealed;

        const block_size_after_append = std.math.add(usize, entry.bytes.items.len, bytes.len) catch
            return error.DocumentBlockTooLarge;
        if (block_size_after_append > self.options.block_size_bytes_max) return error.DocumentBlockTooLarge;

        const resident_size_after_append = std.math.add(usize, self.resident_size_bytes, bytes.len) catch
            return error.DocumentResidentTooLarge;
        if (resident_size_after_append > self.options.resident_size_bytes_max) return error.DocumentResidentTooLarge;

        try entry.bytes.appendSlice(allocator, bytes);
        entry.revision += 1;
        self.resident_size_bytes = resident_size_after_append;
    }

    pub fn seal(self: *Document, id: BlockId) !void {
        const entry = self.blockPtr(id) orelse return error.DocumentBlockNotFound;
        entry.state = .sealed;
        entry.revision += 1;
    }

    pub fn block(self: *const Document, id: BlockId) ?*const Block {
        for (self.blocks.items) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }

    fn blockPtr(self: *Document, id: BlockId) ?*Block {
        for (self.blocks.items) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }
};

test "document appends text to one open block" {
    var document = Document.init(.{ .block_count_max = 2, .resident_size_bytes_max = 16, .block_size_bytes_max = 16 });
    defer document.deinit(std.testing.allocator);

    const id = try document.appendBlock(std.testing.allocator);
    try document.appendText(std.testing.allocator, id, "hello");
    try document.appendText(std.testing.allocator, id, " world");

    const block = document.block(id).?;
    try std.testing.expectEqualStrings("hello world", block.bytes.items);
    try std.testing.expectEqual(@as(u64, 2), block.revision);
}

test "document enforces stable bounds" {
    var document = Document.init(.{ .block_count_max = 1, .resident_size_bytes_max = 4, .block_size_bytes_max = 4 });
    defer document.deinit(std.testing.allocator);

    const id = try document.appendBlock(std.testing.allocator);
    try std.testing.expectError(error.DocumentBlockLimitReached, document.appendBlock(std.testing.allocator));
    try document.appendText(std.testing.allocator, id, "1234");
    try std.testing.expectError(error.DocumentBlockTooLarge, document.appendText(std.testing.allocator, id, "5"));
}

test "document rejects mutation after seal" {
    var document = Document.init(.{});
    defer document.deinit(std.testing.allocator);

    const id = try document.appendBlock(std.testing.allocator);
    try document.seal(id);
    try std.testing.expectError(error.DocumentBlockSealed, document.appendText(std.testing.allocator, id, "late"));
}

test "document removes only the expected tail block" {
    var document = Document.init(.{});
    defer document.deinit(std.testing.allocator);

    const first_id = try document.appendBlock(std.testing.allocator);
    const second_id = try document.appendBlock(std.testing.allocator);
    try document.appendText(std.testing.allocator, second_id, "tail");

    try std.testing.expectError(error.DocumentBlockNotTail, document.removeTailBlock(std.testing.allocator, first_id));
    try document.removeTailBlock(std.testing.allocator, second_id);

    try std.testing.expectEqual(@as(usize, 1), document.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), document.resident_size_bytes);
    try std.testing.expectEqual(first_id, document.blocks.items[0].id);
}
