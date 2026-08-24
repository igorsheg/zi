const std = @import("std");

pub const slug_max_bytes: usize = 79;
pub const bucket_max_bytes: usize = slug_max_bytes + 1 + 16;
pub const canonical_name_bytes: usize = 63;
pub const timestamp_bytes: usize = 20;
pub const default_max_cwd_bytes: usize = 4096;
pub const default_max_path_bytes: usize = 4096;
pub const hard_max_bytes: usize = 1024 * 1024;

pub const Limits = struct {
    max_cwd_bytes: usize = default_max_cwd_bytes,
    max_path_bytes: usize = default_max_path_bytes,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidCwd,
    CwdTooLong,
    InvalidPath,
    PathTooLong,
    InvalidTimestamp,
    InvalidUuid,
};

pub const UtcDateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Timestamp = union(enum) {
    epoch_seconds: i64,
    utc: UtcDateTime,
};

/// Returns the hax cwd bucket. The hash covers every input byte, while the
/// readable slug is the first 79 bytes after leading slashes are removed.
/// Consequently, as in hax, truncation can split a UTF-8 sequence.
pub fn bucket(allocator: std.mem.Allocator, cwd: []const u8) Error![]u8 {
    return bucketWithLimits(allocator, cwd, .{});
}

pub fn bucketWithLimits(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    limits: Limits,
) Error![]u8 {
    try validateLimits(limits);
    try validateCwd(cwd, limits);

    var hash: u64 = 1469598103934665603;
    for (cwd) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }

    var relative_start: usize = 0;
    while (relative_start < cwd.len and cwd[relative_start] == '/') relative_start += 1;
    const relative = if (relative_start == cwd.len) "root" else cwd[relative_start..];
    const slug_length = @min(relative.len, slug_max_bytes);
    const result = try allocator.alloc(u8, slug_length + 17);
    errdefer allocator.free(result);
    for (relative[0..slug_length], result[0..slug_length]) |byte, *output| {
        output.* = if (byte == '/') '-' else byte;
    }
    result[slug_length] = '.';
    writeHex64(result[slug_length + 1 ..], hash);
    return result;
}

/// Builds `<state_root>/sessions/<bucket>` without consulting process state.
/// The returned path is owned by the caller.
pub fn sessionDirectory(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    cwd: []const u8,
    limits: Limits,
) Error![]u8 {
    try validateLimits(limits);
    try validateRoot(state_root, limits);
    const encoded = try bucketWithLimits(allocator, cwd, limits);
    defer allocator.free(encoded);

    var root_length = state_root.len;
    while (root_length > 1 and state_root[root_length - 1] == '/') root_length -= 1;
    const separator_length: usize = if (root_length == 1) 0 else 1;
    const prefix_length = std.math.add(usize, root_length, separator_length + "sessions/".len) catch
        return error.PathTooLong;
    const path_length = std.math.add(usize, prefix_length, encoded.len) catch return error.PathTooLong;
    if (path_length > limits.max_path_bytes) return error.PathTooLong;

    const result = try allocator.alloc(u8, path_length);
    errdefer allocator.free(result);
    var cursor: usize = 0;
    @memcpy(result[cursor..][0..root_length], state_root[0..root_length]);
    cursor += root_length;
    if (separator_length != 0) {
        result[cursor] = '/';
        cursor += 1;
    }
    @memcpy(result[cursor..][0.."sessions/".len], "sessions/");
    cursor += "sessions/".len;
    @memcpy(result[cursor..][0..encoded.len], encoded);
    return result;
}

pub fn canonicalName(timestamp: Timestamp, uuid: [16]u8) Error![canonical_name_bytes]u8 {
    if (!validUuid(uuid)) return error.InvalidUuid;
    const date_time = try resolveTimestamp(timestamp);
    var result: [canonical_name_bytes]u8 = undefined;
    writeTimestamp(result[0..timestamp_bytes], date_time, '-');
    result[20] = '_';
    writeUuid(result[21..57], uuid);
    @memcpy(result[57..], ".jsonl");
    return result;
}

pub fn canonicalNameFromEpoch(epoch_seconds: i64, uuid: [16]u8) Error![canonical_name_bytes]u8 {
    return canonicalName(.{ .epoch_seconds = epoch_seconds }, uuid);
}

pub fn headerTimestamp(timestamp: Timestamp) Error![timestamp_bytes]u8 {
    const date_time = try resolveTimestamp(timestamp);
    var result: [timestamp_bytes]u8 = undefined;
    writeTimestamp(&result, date_time, ':');
    return result;
}

pub fn headerTimestampFromEpoch(epoch_seconds: i64) Error![timestamp_bytes]u8 {
    return headerTimestamp(.{ .epoch_seconds = epoch_seconds });
}

pub fn isCanonicalName(name: []const u8) bool {
    if (name.len != canonical_name_bytes) return false;
    if (!timestampShape(name[0..timestamp_bytes], '-')) return false;
    if (name[20] != '_' or !std.mem.eql(u8, name[57..], ".jsonl")) return false;
    const date_time = parseTimestamp(name[0..timestamp_bytes]) orelse return false;
    if (!validDateTime(date_time)) return false;
    const uuid = parseUuid(name[21..57]) orelse return false;
    return validUuid(uuid);
}

pub fn validUuid(uuid: [16]u8) bool {
    return uuid[6] & 0xf0 == 0x40 and uuid[8] & 0xc0 == 0x80;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_cwd_bytes == 0 or limits.max_cwd_bytes > hard_max_bytes or
        limits.max_path_bytes == 0 or limits.max_path_bytes > hard_max_bytes)
    {
        return error.InvalidLimits;
    }
}

fn validateCwd(cwd: []const u8, limits: Limits) Error!void {
    if (cwd.len > limits.max_cwd_bytes) return error.CwdTooLong;
    if (cwd.len == 0 or cwd[0] != '/' or std.mem.findScalar(u8, cwd, 0) != null or
        !std.unicode.utf8ValidateSlice(cwd))
    {
        return error.InvalidCwd;
    }
}

fn validateRoot(root: []const u8, limits: Limits) Error!void {
    if (root.len > limits.max_path_bytes) return error.PathTooLong;
    if (root.len == 0 or root[0] != '/' or std.mem.findScalar(u8, root, 0) != null or
        !std.unicode.utf8ValidateSlice(root))
    {
        return error.InvalidPath;
    }
}

fn resolveTimestamp(timestamp: Timestamp) Error!UtcDateTime {
    const value = switch (timestamp) {
        .epoch_seconds => |seconds| try dateTimeFromEpoch(seconds),
        .utc => |date_time| date_time,
    };
    if (!validDateTime(value)) return error.InvalidTimestamp;
    return value;
}

fn dateTimeFromEpoch(seconds: i64) Error!UtcDateTime {
    const seconds_per_day: i64 = 86_400;
    const days = @divFloor(seconds, seconds_per_day);
    const day_seconds: u32 = @intCast(@mod(seconds, seconds_per_day));

    // Howard Hinnant's inverse civil-date algorithm, with 1970-01-01 as day zero.
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divTrunc(
        day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36_524) -
            @divTrunc(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    const month_prime = @divTrunc(5 * day_of_year + 2, 153);
    const day = day_of_year - @divTrunc(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;
    if (year < 0 or year > 9999) return error.InvalidTimestamp;

    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(day_seconds / 3600),
        .minute = @intCast(day_seconds % 3600 / 60),
        .second = @intCast(day_seconds % 60),
    };
}

fn validDateTime(value: UtcDateTime) bool {
    if (value.year > 9999 or value.month < 1 or value.month > 12 or value.hour > 23 or
        value.minute > 59 or value.second > 59)
    {
        return false;
    }
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var maximum = days[value.month - 1];
    if (value.month == 2 and isLeapYear(value.year)) maximum = 29;
    return value.day >= 1 and value.day <= maximum;
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn writeTimestamp(output: []u8, value: UtcDateTime, time_separator: u8) void {
    std.debug.assert(output.len == timestamp_bytes);
    writeDecimal(output[0..4], value.year);
    output[4] = '-';
    writeDecimal(output[5..7], value.month);
    output[7] = '-';
    writeDecimal(output[8..10], value.day);
    output[10] = 'T';
    writeDecimal(output[11..13], value.hour);
    output[13] = time_separator;
    writeDecimal(output[14..16], value.minute);
    output[16] = time_separator;
    writeDecimal(output[17..19], value.second);
    output[19] = 'Z';
}

fn timestampShape(value: []const u8, time_separator: u8) bool {
    if (value.len != timestamp_bytes or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != time_separator or value[16] != time_separator or value[19] != 'Z')
    {
        return false;
    }
    for (value, 0..) |byte, index| switch (index) {
        4, 7, 10, 13, 16, 19 => {},
        else => if (!std.ascii.isDigit(byte)) return false,
    };
    return true;
}

fn parseTimestamp(value: []const u8) ?UtcDateTime {
    return .{
        .year = parseDecimal(value[0..4]) orelse return null,
        .month = @intCast(parseDecimal(value[5..7]) orelse return null),
        .day = @intCast(parseDecimal(value[8..10]) orelse return null),
        .hour = @intCast(parseDecimal(value[11..13]) orelse return null),
        .minute = @intCast(parseDecimal(value[14..16]) orelse return null),
        .second = @intCast(parseDecimal(value[17..19]) orelse return null),
    };
}

fn writeDecimal(output: []u8, input: anytype) void {
    var value: usize = @intCast(input);
    var index = output.len;
    while (index != 0) {
        index -= 1;
        output[index] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }
    std.debug.assert(value == 0);
}

fn parseDecimal(input: []const u8) ?u16 {
    var result: u16 = 0;
    for (input) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        result = result * 10 + byte - '0';
    }
    return result;
}

fn writeUuid(output: []u8, uuid: [16]u8) void {
    std.debug.assert(output.len == 36);
    var source_index: usize = 0;
    var output_index: usize = 0;
    while (source_index < uuid.len) : (source_index += 1) {
        if (source_index == 4 or source_index == 6 or source_index == 8 or source_index == 10) {
            output[output_index] = '-';
            output_index += 1;
        }
        output[output_index] = hexDigit(uuid[source_index] >> 4);
        output[output_index + 1] = hexDigit(uuid[source_index] & 0x0f);
        output_index += 2;
    }
}

fn parseUuid(input: []const u8) ?[16]u8 {
    if (input.len != 36) return null;
    var result: [16]u8 = undefined;
    var source_index: usize = 0;
    var output_index: usize = 0;
    while (source_index < input.len) {
        if (source_index == 8 or source_index == 13 or source_index == 18 or source_index == 23) {
            if (input[source_index] != '-') return null;
            source_index += 1;
        }
        const high = parseLowerHex(input[source_index]) orelse return null;
        const low = parseLowerHex(input[source_index + 1]) orelse return null;
        result[output_index] = high << 4 | low;
        output_index += 1;
        source_index += 2;
    }
    return result;
}

fn writeHex64(output: []u8, value: u64) void {
    std.debug.assert(output.len == 16);
    for (output, 0..) |*byte, index| {
        const shift: u6 = @intCast((15 - index) * 4);
        byte.* = hexDigit(@intCast(value >> shift & 0x0f));
    }
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn parseLowerHex(value: u8) ?u8 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    return null;
}

test "bucket matches hax root and known vectors" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { cwd: []const u8, expected: []const u8 }{
        .{ .cwd = "/", .expected = "root.44bd54d473cd3d44" },
        .{ .cwd = "/tmp", .expected = "tmp.24ae55f5f457af95" },
        .{ .cwd = "/home/user/project", .expected = "home-user-project.cf83f8d017fec02d" },
        .{ .cwd = "/é", .expected = "é.0d4d1150047c3ea4" },
    };
    for (cases) |case| {
        const actual = try bucket(allocator, case.cwd);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "bucket truncates the hax slug by bytes, including within UTF-8" {
    const allocator = std.testing.allocator;
    const cwd = "/" ++ "a" ** 78 ++ "€";
    const actual = try bucket(allocator, cwd);
    defer allocator.free(actual);
    try std.testing.expectEqual(@as(usize, bucket_max_bytes), actual.len);
    try std.testing.expectEqual(@as(u8, 0xe2), actual[78]);
    try std.testing.expect(!std.unicode.utf8ValidateSlice(actual));
}

test "path rules and exact state-root join are bounded" {
    const allocator = std.testing.allocator;
    const actual = try sessionDirectory(allocator, "/state/zi/", "/tmp", .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("/state/zi/sessions/tmp.24ae55f5f457af95", actual);
    try std.testing.expectError(error.InvalidCwd, bucket(allocator, "tmp"));
    try std.testing.expectError(error.InvalidCwd, bucket(allocator, "/bad\x00cwd"));
    try std.testing.expectError(error.InvalidPath, sessionDirectory(allocator, "state", "/tmp", .{}));
    try std.testing.expectError(
        error.CwdTooLong,
        bucketWithLimits(allocator, "/ab", .{ .max_cwd_bytes = 2 }),
    );
    try std.testing.expectError(
        error.PathTooLong,
        sessionDirectory(allocator, "/state", "/tmp", .{ .max_path_bytes = 20 }),
    );
}

test "canonical names and header timestamp match hax" {
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const name = try canonicalNameFromEpoch(0, uuid);
    try std.testing.expectEqualStrings(
        "1970-01-01T00-00-00Z_550e8400-e29b-41d4-a716-446655440000.jsonl",
        &name,
    );
    try std.testing.expect(isCanonicalName(&name));
    const header = try headerTimestampFromEpoch(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &header);
}

test "dates validate Gregorian leap years and UUID v4 bits" {
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const leap = try canonicalName(.{ .utc = .{
        .year = 2000,
        .month = 2,
        .day = 29,
        .hour = 23,
        .minute = 59,
        .second = 59,
    } }, uuid);
    try std.testing.expect(isCanonicalName(&leap));
    var invalid_date = leap;
    invalid_date[8] = '3';
    try std.testing.expect(!isCanonicalName(&invalid_date));
    var uppercase = leap;
    uppercase[21] = 'A';
    try std.testing.expect(!isCanonicalName(&uppercase));
    var wrong_version = uuid;
    wrong_version[6] = 0x51;
    try std.testing.expectError(
        error.InvalidUuid,
        canonicalName(.{ .epoch_seconds = 0 }, wrong_version),
    );
    try std.testing.expectError(error.InvalidTimestamp, canonicalName(.{ .utc = .{
        .year = 1900,
        .month = 2,
        .day = 29,
        .hour = 0,
        .minute = 0,
        .second = 0,
    } }, uuid));
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const encoded = try bucket(allocator, "/home/user/project");
    defer allocator.free(encoded);
    const directory = try sessionDirectory(allocator, "/state/zi", "/home/user/project", .{});
    defer allocator.free(directory);
}

test "allocation failure is reported without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}
