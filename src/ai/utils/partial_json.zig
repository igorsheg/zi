const std = @import("std");
const mem = @import("../../runtime/root.zig");

const max_depth: u16 = 128;

pub const ParseError = error{
    DepthExceeded,
    OutOfMemory,
};

const InternalError = ParseError || error{Invalid};

pub const Result = struct {
    value: ?std.json.Value,
    complete: bool,
    consumed: usize,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Result {
    var parser: Parser = .{ .allocator = allocator, .input = input };
    parser.skipWhitespace();
    if (parser.index == input.len) return .{ .value = null, .complete = false, .consumed = 0 };

    const value = parser.parseValue() catch |err| switch (err) {
        error.DepthExceeded => return error.DepthExceeded,
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .value = null, .complete = false, .consumed = 0 },
    };

    const consumed = parser.index;
    parser.skipWhitespace();
    return .{
        .value = value,
        .complete = parser.index == input.len and !parser.incomplete,
        .consumed = consumed,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    depth: u16 = 0,
    incomplete: bool = false,

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.input.len) return null;
        return self.input[self.index];
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser) InternalError!std.json.Value {
        self.skipWhitespace();
        const byte = self.peek() orelse {
            self.incomplete = true;
            return .null;
        };
        return switch (byte) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => .{ .string = try self.parseString() },
            't' => self.parseTrue(),
            'f' => self.parseFalse(),
            'n' => self.parseNull(),
            '-', '0'...'9' => self.parseNumber(),
            else => error.Invalid,
        };
    }

    fn parseObject(self: *Parser) InternalError!std.json.Value {
        try self.enterContainer();
        defer self.depth -= 1;
        self.index += 1;

        var object: std.json.ObjectMap = .empty;
        errdefer object.deinit(self.allocator);

        self.skipWhitespace();
        if (self.peek() == null) return self.finishObject(object);
        if (self.peek().? == '}') {
            self.index += 1;
            return .{ .object = object };
        }

        while (true) {
            self.skipWhitespace();
            if (self.peek() == null) return self.finishObject(object);
            if (self.peek().? == '}') {
                self.index += 1;
                return .{ .object = object };
            }
            if (self.peek().? != '"') return self.finishObject(object);

            const key = self.parseString() catch return self.finishObject(object);
            self.skipWhitespace();
            if (self.peek() == null or self.peek().? != ':') {
                self.allocator.free(key);
                return self.finishObject(object);
            }
            self.index += 1;
            self.skipWhitespace();
            if (self.peek() == null) {
                self.allocator.free(key);
                return self.finishObject(object);
            }

            const value = self.parseValue() catch |err| switch (err) {
                error.Invalid => {
                    self.allocator.free(key);
                    return self.finishObject(object);
                },
                else => |other| return other,
            };
            try object.put(self.allocator, key, value);

            self.skipWhitespace();
            const next = self.peek() orelse return self.finishObject(object);
            if (next == '}') {
                self.index += 1;
                return .{ .object = object };
            }
            if (next != ',') return self.finishObject(object);
            self.index += 1;
        }
    }

    fn finishObject(self: *Parser, object: std.json.ObjectMap) std.json.Value {
        self.incomplete = true;
        return .{ .object = object };
    }

    fn parseArray(self: *Parser) InternalError!std.json.Value {
        try self.enterContainer();
        defer self.depth -= 1;
        self.index += 1;

        var array: std.json.Array = .init(self.allocator);
        errdefer array.deinit();

        self.skipWhitespace();
        if (self.peek() == null) return self.finishArray(array);
        if (self.peek().? == ']') {
            self.index += 1;
            return .{ .array = array };
        }

        while (true) {
            const value = self.parseValue() catch |err| switch (err) {
                error.Invalid => return self.finishArray(array),
                else => |other| return other,
            };
            try array.append(value);

            self.skipWhitespace();
            const next = self.peek() orelse return self.finishArray(array);
            if (next == ']') {
                self.index += 1;
                return .{ .array = array };
            }
            if (next != ',') return self.finishArray(array);
            self.index += 1;
            self.skipWhitespace();
            if (self.peek() == null) return self.finishArray(array);
            if (self.peek().? == ']') {
                self.index += 1;
                return .{ .array = array };
            }
        }
    }

    fn finishArray(self: *Parser, array: std.json.Array) std.json.Value {
        self.incomplete = true;
        return .{ .array = array };
    }

    fn parseString(self: *Parser) InternalError![]const u8 {
        std.debug.assert(self.input[self.index] == '"');
        self.index += 1;
        var out = mem.ByteBuilder.init(self.allocator);
        errdefer out.deinit();

        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (byte == '"') {
                self.index += 1;
                return out.toOwnedSlice();
            }
            if (byte == '\\') {
                try self.parseEscape(&out);
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(byte) catch return self.finishString(&out);
            if (self.index + len > self.input.len) return self.finishString(&out);
            try out.append(self.input[self.index .. self.index + len]);
            self.index += len;
        }

        return self.finishString(&out);
    }

    fn finishString(self: *Parser, out: *mem.ByteBuilder) InternalError![]const u8 {
        self.incomplete = true;
        return out.toOwnedSlice();
    }

    fn parseEscape(self: *Parser, out: *mem.ByteBuilder) InternalError!void {
        if (self.index + 1 >= self.input.len) return self.finishEscape();
        const escaped = self.input[self.index + 1];
        switch (escaped) {
            '"', '\\', '/' => try out.appendByte(escaped),
            'b' => try out.appendByte(0x08),
            'f' => try out.appendByte(0x0c),
            'n' => try out.appendByte('\n'),
            'r' => try out.appendByte('\r'),
            't' => try out.appendByte('\t'),
            'u' => {
                if (self.index + 6 > self.input.len) return self.finishEscape();
                const hex = self.input[self.index + 2 .. self.index + 6];
                const codepoint = std.fmt.parseInt(u21, hex, 16) catch return self.finishEscape();
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buffer) catch return self.finishEscape();
                try out.append(buffer[0..len]);
                self.index += 6;
                return;
            },
            else => return self.finishEscape(),
        }
        self.index += 2;
    }

    fn finishEscape(self: *Parser) InternalError!void {
        self.incomplete = true;
        self.index = self.input.len;
    }

    fn parseTrue(self: *Parser) InternalError!std.json.Value {
        return self.parseKeyword("true", .{ .bool = true });
    }

    fn parseFalse(self: *Parser) InternalError!std.json.Value {
        return self.parseKeyword("false", .{ .bool = false });
    }

    fn parseNull(self: *Parser) InternalError!std.json.Value {
        return self.parseKeyword("null", .null);
    }

    fn parseKeyword(self: *Parser, keyword: []const u8, value: std.json.Value) InternalError!std.json.Value {
        const remaining = self.input[self.index..];
        if (std.mem.startsWith(u8, remaining, keyword)) {
            self.index += keyword.len;
            return value;
        }
        if (remaining.len < keyword.len and std.mem.eql(u8, remaining, keyword[0..remaining.len])) {
            self.index = self.input.len;
            self.incomplete = true;
            return .null;
        }
        return error.Invalid;
    }

    fn parseNumber(self: *Parser) InternalError!std.json.Value {
        const start = self.index;
        if (self.input[self.index] == '-') self.index += 1;
        if (self.index >= self.input.len) return self.invalidNumber(start);

        if (self.input[self.index] == '0') {
            self.index += 1;
        } else if (isDigitNonZero(self.input[self.index])) {
            while (self.index < self.input.len and isDigit(self.input[self.index])) self.index += 1;
        } else return self.invalidNumber(start);

        var valid_end = self.index;
        if (self.index < self.input.len and self.input[self.index] == '.') {
            const dot = self.index;
            self.index += 1;
            const digits_start = self.index;
            while (self.index < self.input.len and isDigit(self.input[self.index])) self.index += 1;
            if (self.index > digits_start) valid_end = self.index else {
                self.index = dot;
                self.incomplete = true;
            }
        }

        if (self.index < self.input.len and (self.input[self.index] == 'e' or self.input[self.index] == 'E')) {
            const exponent = self.index;
            self.index += 1;
            if (self.index < self.input.len and
                (self.input[self.index] == '+' or self.input[self.index] == '-'))
            {
                self.index += 1;
            }
            const digits_start = self.index;
            while (self.index < self.input.len and isDigit(self.input[self.index])) self.index += 1;
            if (self.index > digits_start) valid_end = self.index else {
                self.index = exponent;
                self.incomplete = true;
            }
        }

        self.index = valid_end;
        return std.json.Value.parseFromNumberSlice(self.input[start..valid_end]);
    }

    fn invalidNumber(self: *Parser, start: usize) InternalError!std.json.Value {
        self.index = start;
        self.incomplete = true;
        return error.Invalid;
    }

    fn enterContainer(self: *Parser) ParseError!void {
        self.depth += 1;
        if (self.depth > max_depth) return error.DepthExceeded;
    }
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isDigitNonZero(byte: u8) bool {
    return byte >= '1' and byte <= '9';
}

test "partial parser returns null for empty input" {
    const result = try parse(std.testing.allocator, "  ");

    try std.testing.expectEqual(@as(?std.json.Value, null), result.value);
    try std.testing.expect(!result.complete);
}

test "partial parser closes truncated object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), "{\"a\": 1, \"b\":");

    try std.testing.expect(!result.complete);
    try std.testing.expectEqual(@as(i64, 1), result.value.?.object.get("a").?.integer);
    try std.testing.expectEqual(@as(?std.json.Value, null), result.value.?.object.get("b"));
}

test "partial parser preserves partial string value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), "{\"a\": \"hel");

    try std.testing.expect(!result.complete);
    try std.testing.expectEqualStrings("hel", result.value.?.object.get("a").?.string);
}

test "partial parser trims incomplete number suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decimal = try parse(arena.allocator(), "123.");
    const exponent = try parse(arena.allocator(), "1.5e");

    try std.testing.expectEqual(@as(i64, 123), decimal.value.?.integer);
    try std.testing.expectEqual(@as(f64, 1.5), exponent.value.?.float);
}

test "partial parser enforces maximum depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var input: [129]u8 = undefined;
    @memset(&input, '[');

    try std.testing.expectError(error.DepthExceeded, parse(arena.allocator(), &input));
}
