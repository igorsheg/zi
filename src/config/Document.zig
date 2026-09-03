const std = @import("std");
const PromptValue = @import("PromptValue.zig");

const Document = @This();

pub const maximum_input_bytes: usize = 1024 * 1024;
pub const maximum_depth: usize = 64;
pub const maximum_fields: usize = 8192;
pub const maximum_tokens: usize = 262_144;
pub const maximum_string_bytes: usize = 64 * 1024;
pub const maximum_runtime_string_bytes: usize = PromptValue.maximum_file_bytes * 3;

/// Defensive limits applied before the dynamic JSON tree is allocated.
pub const Limits = struct {
    max_input_bytes: usize = maximum_input_bytes,
    max_depth: usize = maximum_depth,
    max_fields: usize = maximum_fields,
    max_tokens: usize = maximum_tokens,
    max_string_bytes: usize = maximum_string_bytes,
};

/// Writable startup overlays may contain a UTF-8-sanitized prompt expanded to
/// three replacement bytes per input byte. File documents keep Limits{}'s
/// narrower 64 KiB string bound.
pub const runtime_limits: Limits = .{
    .max_string_bytes = maximum_runtime_string_bytes,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidJson,
    InputTooLarge,
    NestingTooDeep,
    TooManyFields,
    TooManyTokens,
    StringTooLong,
    NumberOutOfRange,
    RootNotObject,
};

pub const WipingAllocator = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = context;
        _ = alignment;
        _ = ret_addr;
        // Refuse in-place size changes. Allocator.realloc will allocate, copy,
        // then call free(), which wipes the complete old allocation.
        return new_len == memory.len;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        // Force Allocator.realloc to allocate/copy/free so free() observes and
        // wipes the complete old allocation before the backing allocator does.
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        secureZero(memory);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

parsed: std.json.Parsed(std.json.Value),
wiping_allocator: *WipingAllocator,

/// Parses and owns a JSON object. All values returned by lookup/getRaw borrow
/// from this Document and become invalid at deinit.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Document {
    try validateLimits(limits);
    if (bytes.len > limits.max_input_bytes) return error.InputTooLarge;
    const wiping = allocator.create(WipingAllocator) catch return error.OutOfMemory;
    wiping.* = .{ .backing = allocator };
    errdefer allocator.destroy(wiping);
    const secret_allocator = wiping.allocator();
    try validateBounds(secret_allocator, bytes, limits);

    var parsed = std.json.parseFromSlice(std.json.Value, secret_allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
        .max_value_len = limits.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.RootNotObject;
    return .{ .parsed = parsed, .wiping_allocator = wiping };
}

pub fn deinit(self: *Document) void {
    const wiping = self.wiping_allocator;
    const backing = wiping.backing;
    self.parsed.deinit();
    backing.destroy(wiping);
    self.* = undefined;
}

/// Returns a borrowed value. An exact root member wins over dotted traversal.
pub fn lookup(self: *const Document, key: []const u8) ?*const std.json.Value {
    const root = &self.parsed.value.object;
    if (root.getPtr(key)) |value| return value;

    var object = root;
    var segments = std.mem.splitScalar(u8, key, '.');
    while (segments.next()) |segment| {
        const is_final = segments.peek() == null;
        if (!is_final and segment.len > 63) return null;
        const value = object.getPtr(segment) orelse return null;
        if (is_final) return value;
        object = switch (value.*) {
            .object => |*nested| nested,
            else => return null,
        };
    }
    return null;
}

/// Alias used by callers that pass raw JSON through to provider request bodies.
/// The result is owned by this Document.
pub fn getRaw(self: *const Document, key: []const u8) ?*const std.json.Value {
    return self.lookup(key);
}

/// Returns a borrowed string or a scalar formatted into `buffer`.
/// null, arrays, objects, and unrepresentable numbers return null.
pub fn scalarText(value: *const std.json.Value, buffer: *[64]u8) ?[]const u8 {
    return switch (value.*) {
        .string => |text| text,
        .integer => |number| std.fmt.bufPrint(buffer, "{d}", .{number}) catch unreachable,
        .float => |number| if (std.math.isFinite(number))
            formatGeneralBuffer(buffer[0..32], number)
        else
            null,
        .bool => |boolean| if (boolean) "1" else "0",
        else => null,
    };
}

/// Converts a string, integer, finite real, or boolean to an owned string.
/// null, arrays, objects, and unrepresentable numbers return null.
pub fn scalarString(
    allocator: std.mem.Allocator,
    value: *const std.json.Value,
) !?[]u8 {
    var buffer: [64]u8 = undefined;
    const text = scalarText(value, &buffer) orelse return null;
    const owned = try allocator.dupe(u8, text);
    return owned;
}

/// Returns an owned scalar string, or null for missing/non-scalar values.
pub fn getString(
    self: *const Document,
    allocator: std.mem.Allocator,
    key: []const u8,
) !?[]u8 {
    const value = self.lookup(key) orelse return null;
    return scalarString(allocator, value);
}

/// Reads a non-negative decimal integer in [minimum, maximum]. Invalid or
/// missing values return default_value. Numeric JSON reals are not integers.
pub fn getInt(
    self: *const Document,
    key: []const u8,
    minimum: u64,
    maximum: u64,
    default_value: u64,
) u64 {
    if (minimum > maximum) return default_value;
    const value = self.lookup(key) orelse return default_value;
    const parsed_value = configInteger(value) orelse return default_value;
    if (parsed_value < minimum or parsed_value > maximum) return default_value;
    return parsed_value;
}

/// Reads 1/0, true/false, yes/no, or on/off (words are ASCII case-insensitive).
pub fn getBool(self: *const Document, key: []const u8, default_value: bool) bool {
    const value = self.lookup(key) orelse return default_value;
    return switch (value.*) {
        .bool => |boolean| boolean,
        .integer => |number| if (number == 1) true else if (number == 0) false else default_value,
        .float => |number| if (generalBoolean(number)) |boolean| boolean else default_value,
        .string => |text| parseBool(text) orelse default_value,
        else => default_value,
    };
}

/// Returns owned immediate child names in source order. Nested names come
/// first, followed by flat dotted names. Duplicates keep the first encounter.
/// The caller frees every name and then the returned slice.
pub fn objectKeys(
    self: *const Document,
    allocator: std.mem.Allocator,
    prefix: []const u8,
) ![][]u8 {
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        freeKeys(allocator, keys.items);
        keys.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    if (self.lookup(prefix)) |value| switch (value.*) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try appendUnique(allocator, &keys, &seen, entry.key_ptr.*);
            }
        },
        else => {},
    };

    const root = self.parsed.value.object;
    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len <= prefix.len or !std.mem.eql(u8, name[0..prefix.len], prefix)) continue;
        if (name[prefix.len] != '.') continue;
        const remainder = name[prefix.len + 1 ..];
        const child_end = std.mem.indexOfScalar(u8, remainder, '.') orelse remainder.len;
        if (child_end != 0) try appendUnique(allocator, &keys, &seen, remainder[0..child_end]);
    }
    return keys.toOwnedSlice(allocator);
}

pub fn freeObjectKeys(allocator: std.mem.Allocator, keys: [][]u8) void {
    freeKeys(allocator, keys);
    allocator.free(keys);
}

fn configInteger(value: *const std.json.Value) ?u64 {
    const signed: i64 = switch (value.*) {
        .integer => |number| number,
        .bool => |boolean| if (boolean) 1 else 0,
        .string => |text| parseCInteger(text) orelse return null,
        .float => |number| float_value: {
            if (!std.math.isFinite(number)) return null;
            var buffer: [32]u8 = undefined;
            break :float_value parseCInteger(formatGeneralBuffer(&buffer, number)) orelse
                return null;
        },
        else => return null,
    };
    if (signed < 0 or signed > std.math.maxInt(i32)) return null;
    return @intCast(signed);
}

fn parseCInteger(text: []const u8) ?i64 {
    var start: usize = 0;
    while (start < text.len and isCWhitespace(text[start])) start += 1;
    if (start == text.len) return null;
    const candidate = text[start..];
    const parsed = std.fmt.parseInt(i64, candidate, 10) catch return null;
    if (parsed < std.math.minInt(i32) or parsed > std.math.maxInt(i32)) return null;
    return parsed;
}

fn isCWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or
        byte == 0x0b or byte == 0x0c;
}

fn generalBoolean(number: f64) ?bool {
    if (!std.math.isFinite(number)) return null;
    var buffer: [32]u8 = undefined;
    return parseBool(formatGeneralBuffer(&buffer, number));
}

fn formatGeneral(allocator: std.mem.Allocator, number: f64) error{OutOfMemory}![]u8 {
    var buffer: [32]u8 = undefined;
    return allocator.dupe(u8, formatGeneralBuffer(&buffer, number));
}

/// Reproduces C `%g`'s default six significant digits under round-to-nearest,
/// ties-to-even. f128 preserves the f64 input exactly and leaves 60 guard bits
/// while scaling the six-digit result, including for subnormals.
fn formatGeneralBuffer(buffer: []u8, number: f64) []const u8 {
    var cursor: usize = 0;
    const negative = std.math.signbit(number);
    if (negative) {
        buffer[cursor] = '-';
        cursor += 1;
    }
    if (number == 0) {
        buffer[cursor] = '0';
        return buffer[0 .. cursor + 1];
    }

    const value: f128 = @abs(@as(f128, number));
    var exponent: i32 = @intFromFloat(@floor(@log10(value)));
    var decade = powerOfTen(exponent);
    while (value < decade) {
        exponent -= 1;
        decade /= 10;
    }
    while (value >= decade * 10) {
        exponent += 1;
        decade *= 10;
    }

    const scale_exponent = exponent - 5;
    const scaled = if (scale_exponent >= 0)
        value / powerOfTen(scale_exponent)
    else
        value * powerOfTen(-scale_exponent);
    const lower = @floor(scaled);
    var significand: u64 = @intFromFloat(lower);
    const fraction = scaled - lower;
    const exact_even_tie = fraction == 0.5 and significand & 1 == 0;
    if (fraction > 0.5 or (fraction == 0.5 and !exact_even_tie)) significand += 1;
    if (significand == 1_000_000) {
        significand = 100_000;
        exponent += 1;
    }

    var digits: [6]u8 = undefined;
    var remaining = significand;
    var index: usize = digits.len;
    while (index != 0) {
        index -= 1;
        digits[index] = @intCast('0' + remaining % 10);
        remaining /= 10;
    }

    if (exponent < -4 or exponent >= 6) {
        var digit_end: usize = digits.len;
        // Darwin libc preserves six digits for exact even-half scientific
        // rounding through exponent 14, then trims them from exponent 15.
        const preserve_even_tie_zeros = exact_even_tie and exponent <= 14;
        if (!preserve_even_tie_zeros) {
            while (digit_end > 1 and digits[digit_end - 1] == '0') digit_end -= 1;
        }
        buffer[cursor] = digits[0];
        cursor += 1;
        if (digit_end > 1) {
            buffer[cursor] = '.';
            cursor += 1;
            @memcpy(buffer[cursor..][0 .. digit_end - 1], digits[1..digit_end]);
            cursor += digit_end - 1;
        }
        buffer[cursor] = 'e';
        cursor += 1;
        buffer[cursor] = if (exponent < 0) '-' else '+';
        cursor += 1;
        var magnitude: u32 = @intCast(@abs(exponent));
        if (magnitude >= 100) {
            buffer[cursor] = @intCast('0' + magnitude / 100);
            cursor += 1;
            magnitude %= 100;
        }
        buffer[cursor] = @intCast('0' + magnitude / 10);
        buffer[cursor + 1] = @intCast('0' + magnitude % 10);
        return buffer[0 .. cursor + 2];
    }

    const point: i32 = exponent + 1;
    if (point <= 0) {
        buffer[cursor] = '0';
        buffer[cursor + 1] = '.';
        cursor += 2;
        var zeros: i32 = -point;
        while (zeros > 0) : (zeros -= 1) {
            buffer[cursor] = '0';
            cursor += 1;
        }
        var digit_end: usize = digits.len;
        while (digit_end > 1 and digits[digit_end - 1] == '0') digit_end -= 1;
        @memcpy(buffer[cursor..][0..digit_end], digits[0..digit_end]);
        return buffer[0 .. cursor + digit_end];
    }
    const whole: usize = @intCast(point);
    @memcpy(buffer[cursor..][0..whole], digits[0..whole]);
    cursor += whole;
    if (whole == digits.len) return buffer[0..cursor];
    var digit_end: usize = digits.len;
    while (digit_end > whole and digits[digit_end - 1] == '0') digit_end -= 1;
    if (digit_end == whole) return buffer[0..cursor];
    buffer[cursor] = '.';
    cursor += 1;
    @memcpy(buffer[cursor..][0 .. digit_end - whole], digits[whole..digit_end]);
    return buffer[0 .. cursor + digit_end - whole];
}

fn powerOfTen(exponent: i32) f128 {
    var value: f128 = 1;
    var count: u32 = @intCast(@abs(exponent));
    if (exponent >= 0) {
        while (count != 0) : (count -= 1) value *= 10;
    } else {
        while (count != 0) : (count -= 1) value /= 10;
    }
    return value;
}

fn parseBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on")) return true;
    if (std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return false;
    return null;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]u8),
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (seen.contains(name)) return;
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try seen.put(allocator, owned, {});
    errdefer _ = seen.remove(owned);
    try keys.append(allocator, owned);
}

fn freeKeys(allocator: std.mem.Allocator, keys: []const []u8) void {
    for (keys) |key| allocator.free(key);
}

fn secureZero(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_input_bytes == 0 or limits.max_input_bytes > maximum_input_bytes or
        limits.max_depth == 0 or limits.max_depth > maximum_depth or
        limits.max_fields == 0 or limits.max_fields > maximum_fields or
        limits.max_tokens == 0 or limits.max_tokens > maximum_tokens or
        limits.max_string_bytes == 0 or limits.max_string_bytes > maximum_runtime_string_bytes)
    {
        return error.InvalidLimits;
    }
}

fn validateBounds(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();

    var depth: usize = 0;
    var fields: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token_type = scanner.peekNextTokenType() catch return error.InvalidJson;
        const max_value_len = if (token_type == .string)
            limits.max_string_bytes
        else
            bytes.len;
        const token = scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.StringTooLong,
            else => return error.InvalidJson,
        };
        defer switch (token) {
            .allocated_string => |text| {
                secureZero(text);
                allocator.free(text);
            },
            .allocated_number => |text| {
                secureZero(text);
                allocator.free(text);
            },
            else => {},
        };
        if (token == .end_of_document) {
            if (depth != 0) return error.InvalidJson;
            break;
        }
        tokens += 1;
        if (tokens > limits.max_tokens) return error.TooManyTokens;

        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_depth) return error.NestingTooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .string => |text| {
                if (text.len > limits.max_string_bytes) return error.StringTooLong;
                if (scanner.string_is_object_key) {
                    fields += 1;
                    if (fields > limits.max_fields) return error.TooManyFields;
                }
            },
            .allocated_string => |text| {
                if (text.len > limits.max_string_bytes) return error.StringTooLong;
                if (scanner.string_is_object_key) {
                    fields += 1;
                    if (fields > limits.max_fields) return error.TooManyFields;
                }
            },
            .number => |text| try validateNumber(text),
            .allocated_number => |text| try validateNumber(text),
            else => {},
        }
    }
}

fn validateNumber(text: []const u8) Error!void {
    if (std.json.isNumberFormattedLikeAnInteger(text)) {
        _ = std.fmt.parseInt(i64, text, 10) catch return error.NumberOutOfRange;
    } else {
        const number = std.fmt.parseFloat(f64, text) catch return error.NumberOutOfRange;
        if (!std.math.isFinite(number)) return error.NumberOutOfRange;
    }
}

test "lookup exact dotted key wins and nested fallback works" {
    const json =
        "{\"a.b\":\"flat\",\"a\":{\"b\":\"nested\",\"escaped\":\"a\\nb\"}}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    const exact = (try document.getString(std.testing.allocator, "a.b")).?;
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("flat", exact);
    const escaped = (try document.getString(std.testing.allocator, "a.escaped")).?;
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a\nb", escaped);
}

test "scalar coercion and defaults" {
    const json =
        "{\"i\":12,\"r\":1.5,\"t\":true,\"f\":\"OFF\",\"n\":null,\"bad\":-2}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 12), document.getInt("i", 1, 20, 9));
    try std.testing.expectEqual(@as(u64, 9), document.getInt("bad", 0, 20, 9));
    try std.testing.expect(document.getBool("t", false));
    try std.testing.expect(!document.getBool("f", true));
    try std.testing.expect((try document.getString(std.testing.allocator, "n")) == null);
}

test "duplicates use last and object keys merge in source order" {
    const json =
        "{\"x\":1,\"x\":2,\"providers\":{\"one\":{}}," ++
        "\"providers.two.url\":\"x\",\"providers.one.k\":1}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(u64, 2), document.getInt("x", 0, 3, 0));
    const keys = try document.objectKeys(std.testing.allocator, "providers");
    defer Document.freeObjectKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("one", keys[0]);
    try std.testing.expectEqualStrings("two", keys[1]);
}

test "validation bounds and root" {
    try std.testing.expectError(
        error.RootNotObject,
        Document.parse(std.testing.allocator, "[]", .{}),
    );
    try std.testing.expectError(
        error.InputTooLarge,
        Document.parse(std.testing.allocator, "{}", .{ .max_input_bytes = 1 }),
    );
    try std.testing.expectError(
        error.NestingTooDeep,
        Document.parse(std.testing.allocator, "{\"a\":{}}", .{ .max_depth = 1 }),
    );
    try std.testing.expectError(
        error.TooManyFields,
        Document.parse(std.testing.allocator, "{\"a\":1,\"b\":2}", .{ .max_fields = 1 }),
    );
    try std.testing.expectError(
        error.TooManyTokens,
        Document.parse(std.testing.allocator, "{\"a\":1}", .{ .max_tokens = 2 }),
    );
    try std.testing.expectError(
        error.StringTooLong,
        Document.parse(std.testing.allocator, "{\"a\":\"abcd\"}", .{ .max_string_bytes = 3 }),
    );
    try std.testing.expectError(
        error.NumberOutOfRange,
        Document.parse(std.testing.allocator, "{\"a\":1e999}", .{}),
    );
}

test "long traversal segment is absent but an exact flat key still works" {
    const key = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl.value";
    const json = "{\"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl.value\":1}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    try std.testing.expect(document.lookup(key) != null);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var document = try Document.parse(
        allocator,
        "{\"s\":\"x\",\"a\":{\"one\":1,\"two\":2}}",
        .{},
    );
    defer document.deinit();

    const text = (try document.getString(allocator, "s")).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("x", text);

    const keys = try document.objectKeys(allocator, "a");
    defer Document.freeObjectKeys(allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
}

test "parse and owned results handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "real and integer scalar coercion matches hax percent-g and strtol" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"real\":1.23456789,\"scientific\":10000000.0,\"near\":0.9999996," ++
            "\"zero\":0.0,\"lead\":\" \\t+12\",\"trail\":\"12 \"," ++
            "\"negative_zero\":\"-0\",\"large\":2147483648," ++
            "\"real_int\":12.0,\"exp_int\":1000000.0}",
        .{},
    );
    defer document.deinit();
    const real = (try document.getString(std.testing.allocator, "real")).?;
    defer std.testing.allocator.free(real);
    try std.testing.expectEqualStrings("1.23457", real);
    const scientific = (try document.getString(std.testing.allocator, "scientific")).?;
    defer std.testing.allocator.free(scientific);
    try std.testing.expectEqualStrings("1e+07", scientific);
    try std.testing.expect(document.getBool("near", false));
    try std.testing.expect(!document.getBool("zero", true));
    try std.testing.expectEqual(@as(u64, 12), document.getInt("lead", 0, 20, 9));
    try std.testing.expectEqual(@as(u64, 9), document.getInt("trail", 0, 20, 9));
    try std.testing.expectEqual(@as(u64, 0), document.getInt("negative_zero", 0, 20, 9));
    try std.testing.expectEqual(@as(u64, 9), document.getInt("large", 0, std.math.maxInt(u64), 9));
    try std.testing.expectEqual(@as(u64, 12), document.getInt("real_int", 0, 20, 9));
    try std.testing.expectEqual(@as(u64, 9), document.getInt("exp_int", 0, 2_000_000, 9));

    var edge = try Document.parse(
        std.testing.allocator,
        "{\"subnormal\":5e-324,\"negative_subnormal\":-5e-324," ++
            "\"tie_low\":1.000005,\"tie_decimal\":99999.95," ++
            "\"tie_scientific\":1000005.0," ++
            "\"tie_scientific_large\":1000005000000000.0}",
        .{},
    );
    defer edge.deinit();
    const subnormal = (try edge.getString(std.testing.allocator, "subnormal")).?;
    defer std.testing.allocator.free(subnormal);
    try std.testing.expectEqualStrings("4.94066e-324", subnormal);
    const negative_subnormal = (try edge.getString(std.testing.allocator, "negative_subnormal")).?;
    defer std.testing.allocator.free(negative_subnormal);
    try std.testing.expectEqualStrings("-4.94066e-324", negative_subnormal);
    const tie_low = (try edge.getString(std.testing.allocator, "tie_low")).?;
    defer std.testing.allocator.free(tie_low);
    try std.testing.expectEqualStrings("1.00001", tie_low);
    try std.testing.expect(!edge.getBool("tie_low", false));
    try std.testing.expectEqual(@as(u64, 9), edge.getInt("tie_low", 0, 2, 9));
    const tie_decimal = (try edge.getString(std.testing.allocator, "tie_decimal")).?;
    defer std.testing.allocator.free(tie_decimal);
    try std.testing.expectEqualStrings("99999.9", tie_decimal);
    try std.testing.expectEqual(@as(u64, 9), edge.getInt("tie_decimal", 0, 200_000, 9));
    const tie_scientific = (try edge.getString(std.testing.allocator, "tie_scientific")).?;
    defer std.testing.allocator.free(tie_scientific);
    try std.testing.expectEqualStrings("1.00000e+06", tie_scientific);
    const tie_scientific_large =
        (try edge.getString(std.testing.allocator, "tie_scientific_large")).?;
    defer std.testing.allocator.free(tie_scientific_large);
    try std.testing.expectEqualStrings("1e+15", tie_scientific_large);
}

test "dotted traversal permits an unbounded final leaf under bounded input" {
    const leaf = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl";
    const key = "a." ++ leaf;
    const json = "{\"a\":{\"" ++ leaf ++ "\":1}}";
    var document = try Document.parse(std.testing.allocator, json, .{});
    defer document.deinit();
    try std.testing.expect(document.lookup(key) != null);
}

test "runtime limits admit sanitized prompt expansion without widening file defaults" {
    const payload = try std.testing.allocator.alloc(u8, maximum_string_bytes + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"prompt\":\"{s}\"}}", .{payload});
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.StringTooLong, Document.parse(std.testing.allocator, json, .{}));
    var runtime = try Document.parse(std.testing.allocator, json, runtime_limits);
    defer runtime.deinit();
}
