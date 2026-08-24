const std = @import("std");

pub const default_max_attempts: u16 = 5;
pub const default_base_delay_ms: u64 = 1_000;
pub const default_max_delay_ms: u64 = 30_000;
pub const default_idle_timeout_ms: u64 = 10 * 60 * 1_000;
pub const retry_after_max_ms: u64 = 2 * 60 * 1_000;
pub const sleep_slice_max_ms: u64 = 100;
pub const error_body_max_bytes: usize = 4_096;
pub const retry_after_max_bytes: usize = 1_024;

pub const Policy = struct {
    /// Includes the initial request. One disables retries.
    max_attempts: u16 = default_max_attempts,
    base_delay_ms: u64 = default_base_delay_ms,
    max_delay_ms: u64 = default_max_delay_ms,
};

pub const default_policy: Policy = .{};

/// Classifies only failures that happened before a completed provider stream.
/// A failed transport with a 2xx status is not retryable because output might
/// already have been delivered. Stream drivers may separately classify a 2xx
/// response whose protocol parser says that the stream is incomplete.
pub fn shouldAttempt(transport_succeeded: bool, status: u16, error_body: []const u8) bool {
    if (status >= 200 and status < 300) return false;
    if (status == 0) return true;
    if (status == 408) return true;
    if (status == 429) return !hasTerminalQuotaError(error_body);
    if (status >= 500 and status <= 599) return true;
    _ = transport_succeeded;
    return false;
}

/// Returns exponential backoff for a zero-based failed-attempt index. `entropy`
/// is injected by the caller. Every value maps deterministically to 75..125%.
pub fn delayMs(policy: Policy, attempt: u32, entropy: u64) u64 {
    if (policy.base_delay_ms == 0 or policy.max_delay_ms == 0) return 0;

    var delay = @min(policy.base_delay_ms, policy.max_delay_ms);
    var remaining = attempt;
    while (remaining > 0 and delay < policy.max_delay_ms) : (remaining -= 1) {
        if (delay > policy.max_delay_ms / 2) {
            delay = policy.max_delay_ms;
            break;
        }
        delay *= 2;
    }

    const jitter_percent: u64 = 75 + entropy % 51;
    const jittered: u128 = @as(u128, delay) * jitter_percent / 100;
    return @intCast(@min(@as(u128, policy.max_delay_ms), jittered));
}

/// Parses Retry-After as integer seconds or an RFC HTTP-date. `now_unix_s` is
/// injected to keep this policy deterministic. Invalid, zero, and past values
/// return null. Server-requested waits are capped at two minutes.
pub fn parseRetryAfter(value: []const u8, now_unix_s: i64) ?u64 {
    if (value.len > retry_after_max_bytes) return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    var seconds: u64 = 0;
    var all_digits = true;
    for (trimmed) |byte| {
        if (byte < '0' or byte > '9') {
            all_digits = false;
            break;
        }
        const digit: u64 = byte - '0';
        if (seconds > (retry_after_max_ms / 1_000 - digit) / 10) {
            return retry_after_max_ms;
        }
        seconds = seconds * 10 + digit;
    }
    if (all_digits) return if (seconds == 0) null else seconds * 1_000;

    const retry_at = parseHttpDate(trimmed, now_unix_s) orelse return null;
    const difference = @as(i128, retry_at) - @as(i128, now_unix_s);
    if (difference <= 0) return null;
    if (difference >= retry_after_max_ms / 1_000) return retry_after_max_ms;
    return @as(u64, @intCast(difference)) * 1_000;
}

/// Pure sleep plan. Callers poll cancellation before each returned slice, then
/// sleep for that slice. Even a zero delay requires one poll via `needsPoll`.
pub const SleepPlan = struct {
    remaining_ms: u64,
    poll_pending: bool = true,

    pub fn init(delay_ms: u64) SleepPlan {
        return .{ .remaining_ms = delay_ms };
    }

    pub fn needsPoll(self: SleepPlan) bool {
        return self.poll_pending;
    }

    /// Records a successful cancellation poll and returns the next bounded
    /// sleep slice. Null means the requested delay is complete.
    pub fn next(self: *SleepPlan) ?u64 {
        if (!self.poll_pending) return null;
        if (self.remaining_ms == 0) {
            self.poll_pending = false;
            return null;
        }
        const slice = @min(self.remaining_ms, sleep_slice_max_ms);
        self.remaining_ms -= slice;
        if (self.remaining_ms == 0) self.poll_pending = false;
        return slice;
    }
};

fn hasTerminalQuotaError(body: []const u8) bool {
    if (body.len == 0 or body.len > error_body_max_bytes) return false;

    // Scanner allocation is limited: JSON depth and decoded string storage
    // cannot turn a bounded error response into unbounded retained memory.
    var storage: [2_048]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), body);
    defer scanner.deinit();

    var depth: usize = 0;
    var error_depth: ?usize = null;
    var pending_error = false;
    var pending_marker = false;
    var terminal = false;

    while (true) {
        const token = scanner.nextAllocMax(fixed.allocator(), .alloc_if_needed, 128) catch return false;
        const is_key = scanner.string_is_object_key;
        switch (token) {
            .object_begin => {
                depth += 1;
                if (pending_error) error_depth = depth;
                pending_error = false;
                pending_marker = false;
            },
            .array_begin => {
                depth += 1;
                pending_error = false;
                pending_marker = false;
            },
            .object_end, .array_end => {
                if (error_depth != null and error_depth.? == depth) error_depth = null;
                if (depth == 0) return false;
                depth -= 1;
                pending_error = false;
                pending_marker = false;
            },
            .string, .allocated_string => {
                const string = tokenString(token);
                if (is_key) {
                    pending_error = depth == 1 and std.mem.eql(u8, string, "error");
                    pending_marker = error_depth != null and depth == error_depth.? and
                        (std.mem.eql(u8, string, "type") or std.mem.eql(u8, string, "code"));
                } else {
                    if (pending_marker and isTerminalMarker(string)) terminal = true;
                    pending_error = false;
                    pending_marker = false;
                }
            },
            .end_of_document => return terminal,
            else => {
                if (!is_key) {
                    pending_error = false;
                    pending_marker = false;
                }
            },
        }
    }
}

fn tokenString(token: std.json.Token) []const u8 {
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => unreachable,
    };
}

fn isTerminalMarker(value: []const u8) bool {
    inline for (.{
        "usage_limit_reached",
        "usage_not_included",
        "insufficient_quota",
        "quota_exceeded",
    }) |marker| {
        if (std.ascii.eqlIgnoreCase(value, marker)) return true;
    }
    return false;
}

fn parseHttpDate(value: []const u8, now_unix_s: i64) ?i64 {
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
    if (value.len == 29 and validShortWeekday(value[0..3]) and
        value[3] == ',' and value[4] == ' ' and
        value[7] == ' ' and value[11] == ' ' and value[16] == ' ' and
        value[19] == ':' and value[22] == ':' and value[25] == ' ' and
        std.ascii.eqlIgnoreCase(value[26..29], "GMT"))
    {
        return dateTimeToUnix(
            parseDigits(value[12..16]) orelse return null,
            parseMonth(value[8..11]) orelse return null,
            parseDigits(value[5..7]) orelse return null,
            parseDigits(value[17..19]) orelse return null,
            parseDigits(value[20..22]) orelse return null,
            parseDigits(value[23..25]) orelse return null,
        );
    }

    // Obsolete RFC 850 form: Sunday, 06-Nov-94 08:49:37 GMT
    const comma = std.mem.findScalar(u8, value, ',');
    if (comma) |comma_index| {
        if (!validLongWeekday(value[0..comma_index])) return null;
        const tail = value[comma_index + 1 ..];
        if (tail.len == 23 and tail[0] == ' ' and tail[3] == '-' and
            tail[7] == '-' and tail[10] == ' ' and tail[13] == ':' and
            tail[16] == ':' and tail[19] == ' ' and std.ascii.eqlIgnoreCase(tail[20..23], "GMT"))
        {
            const short_year = parseDigits(tail[8..10]) orelse return null;
            var year: u16 = 2000 + short_year;
            var candidate = dateTimeToUnix(
                year,
                parseMonth(tail[4..7]) orelse return null,
                parseDigits(tail[1..3]) orelse return null,
                parseDigits(tail[11..13]) orelse return null,
                parseDigits(tail[14..16]) orelse return null,
                parseDigits(tail[17..19]) orelse return null,
            ) orelse return null;
            if (moreThanFiftyYearsFuture(candidate, now_unix_s)) {
                year -= 100;
                candidate = dateTimeToUnix(
                    year,
                    parseMonth(tail[4..7]) orelse return null,
                    parseDigits(tail[1..3]) orelse return null,
                    parseDigits(tail[11..13]) orelse return null,
                    parseDigits(tail[14..16]) orelse return null,
                    parseDigits(tail[17..19]) orelse return null,
                ) orelse return null;
            }
            return candidate;
        }
    }

    // ANSI C asctime form: Sun Nov  6 08:49:37 1994
    if (value.len == 24 and validShortWeekday(value[0..3]) and
        value[3] == ' ' and value[7] == ' ' and
        value[10] == ' ' and value[13] == ':' and value[16] == ':' and value[19] == ' ')
    {
        const day = if (value[8] == ' ') parseDigits(value[9..10]) else parseDigits(value[8..10]);
        return dateTimeToUnix(
            parseDigits(value[20..24]) orelse return null,
            parseMonth(value[4..7]) orelse return null,
            day orelse return null,
            parseDigits(value[11..13]) orelse return null,
            parseDigits(value[14..16]) orelse return null,
            parseDigits(value[17..19]) orelse return null,
        );
    }
    return null;
}

fn validShortWeekday(value: []const u8) bool {
    inline for (.{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) |weekday| {
        if (std.ascii.eqlIgnoreCase(value, weekday)) return true;
    }
    return false;
}

fn validLongWeekday(value: []const u8) bool {
    inline for (.{
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    }) |weekday| {
        if (std.ascii.eqlIgnoreCase(value, weekday)) return true;
    }
    return false;
}

fn moreThanFiftyYearsFuture(candidate: i64, now_unix_s: i64) bool {
    if (candidate <= now_unix_s or now_unix_s < 0) return false;
    var year: u16 = 1970;
    while (year < 9999) : (year += 1) {
        const next = dateTimeToUnix(year + 1, 1, 1, 0, 0, 0) orelse return false;
        if (now_unix_s < next) {
            if (year > 9949) return false;
            const year_start = dateTimeToUnix(year, 1, 1, 0, 0, 0) orelse return false;
            const cutoff_start = dateTimeToUnix(year + 50, 1, 1, 0, 0, 0) orelse return false;
            const next_cutoff = dateTimeToUnix(year + 51, 1, 1, 0, 0, 0) orelse return false;
            const offset = now_unix_s - year_start;
            const cutoff = cutoff_start + @min(offset, next_cutoff - cutoff_start - 1);
            return candidate > cutoff;
        }
    }
    return false;
}

fn parseDigits(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    var result: u16 = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return null;
        result = result * 10 + (byte - '0');
    }
    return result;
}

fn parseMonth(value: []const u8) ?u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 1..) |month, number| {
        if (std.ascii.eqlIgnoreCase(value, month)) return @intCast(number);
    }
    return null;
}

fn dateTimeToUnix(year: u16, month: u8, day: u16, hour: u16, minute: u16, second: u16) ?i64 {
    if (year < 1970 or month < 1 or month > 12 or day < 1 or
        hour > 23 or minute > 59 or second > 59) return null;
    const month_lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var maximum_day: u16 = month_lengths[month - 1];
    if (month == 2 and isLeapYear(year)) maximum_day = 29;
    if (day > maximum_day) return null;

    var days: i64 = 0;
    var current_year: u16 = 1970;
    while (current_year < year) : (current_year += 1) {
        days += if (isLeapYear(current_year)) 366 else 365;
    }
    var current_month: u8 = 1;
    while (current_month < month) : (current_month += 1) {
        days += month_lengths[current_month - 1];
        if (current_month == 2 and isLeapYear(year)) days += 1;
    }
    days += day - 1;
    return days * 86_400 + @as(i64, hour) * 3_600 + @as(i64, minute) * 60 + second;
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

test "defaults and response classification" {
    try std.testing.expectEqual(@as(u16, 5), default_policy.max_attempts);
    try std.testing.expectEqual(@as(u64, 1_000), default_policy.base_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), default_policy.max_delay_ms);

    const cases = [_]struct { ok: bool, status: u16, expected: bool }{
        .{ .ok = true, .status = 200, .expected = false },
        .{ .ok = false, .status = 0, .expected = true },
        .{ .ok = false, .status = 408, .expected = true },
        .{ .ok = false, .status = 429, .expected = true },
        .{ .ok = false, .status = 500, .expected = true },
        .{ .ok = false, .status = 599, .expected = true },
        .{ .ok = false, .status = 400, .expected = false },
        .{ .ok = false, .status = 600, .expected = false },
        .{ .ok = false, .status = 204, .expected = false },
    };
    for (cases) |case| try std.testing.expectEqual(
        case.expected,
        shouldAttempt(case.ok, case.status, ""),
    );
}

test "terminal quota markers are valid JSON error fields and ASCII insensitive" {
    const cases = [_]struct { body: []const u8, retry: bool }{
        .{ .body = "{\"error\":{\"type\":\"usage_limit_reached\"}}", .retry = false },
        .{ .body = "{\"error\":{\"code\":\"INSUFFICIENT_QUOTA\"}}", .retry = false },
        .{ .body = "{\"error\":{\"type\":\"quota_exceeded\"}}", .retry = false },
        .{ .body = "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", .retry = true },
        .{ .body = "{\"code\":\"quota_exceeded\"}", .retry = true },
        .{ .body = "{\"error\":{\"nested\":{\"code\":\"quota_exceeded\"}}}", .retry = true },
        .{ .body = "not json", .retry = true },
    };
    for (cases) |case| try std.testing.expectEqual(
        case.retry,
        shouldAttempt(true, 429, case.body),
    );
    try std.testing.expect(shouldAttempt(false, 503, cases[0].body));
}

test "backoff is deterministic jittered saturated and capped" {
    const policy: Policy = .{ .base_delay_ms = 1_000, .max_delay_ms = 30_000 };
    try std.testing.expectEqual(@as(u64, 750), delayMs(policy, 0, 0));
    try std.testing.expectEqual(@as(u64, 1_250), delayMs(policy, 0, 50));
    try std.testing.expectEqual(@as(u64, 30_000), delayMs(policy, 50, 50));
    try std.testing.expectEqual(@as(u64, 0), delayMs(.{ .base_delay_ms = 0 }, 1, 1));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        delayMs(.{ .base_delay_ms = std.math.maxInt(u64), .max_delay_ms = std.math.maxInt(u64) }, 99, 50),
    );
}

test "Retry-After integer date bounds and invalid inputs" {
    const now: i64 = 784_111_777; // Sun, 06 Nov 1994 08:49:37 GMT
    try std.testing.expectEqual(@as(?u64, 2_000), parseRetryAfter(" 2\r\n", now));
    try std.testing.expectEqual(@as(?u64, 120_000), parseRetryAfter("99999999999999999999", now));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("0", now));
    try std.testing.expectEqual(@as(?u64, 60_000), parseRetryAfter("Sun, 06 Nov 1994 08:50:37 GMT", now));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("not a date", now));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("Sun, 31 Feb 1994 08:50:37 GMT", now));
}

test "sleep plan yields no slice over one hundred milliseconds" {
    var plan = SleepPlan.init(250);
    try std.testing.expect(plan.needsPoll());
    try std.testing.expectEqual(@as(?u64, 100), plan.next());
    try std.testing.expectEqual(@as(?u64, 100), plan.next());
    try std.testing.expectEqual(@as(?u64, 50), plan.next());
    try std.testing.expectEqual(@as(?u64, null), plan.next());
    try std.testing.expect(!plan.needsPoll());

    var zero = SleepPlan.init(0);
    try std.testing.expect(zero.needsPoll());
    try std.testing.expectEqual(@as(?u64, null), zero.next());
    try std.testing.expect(!zero.needsPoll());
}

test "retry after accepts legacy HTTP dates and extreme clocks safely" {
    const now: i64 = 784_111_770; // Sun, 06 Nov 1994 08:49:30 GMT
    try std.testing.expectEqual(@as(?u64, 7_000), parseRetryAfter(
        "Sunday, 06-Nov-94 08:49:37 GMT",
        now,
    ));
    try std.testing.expectEqual(@as(?u64, 7_000), parseRetryAfter(
        "Sun Nov  6 08:49:37 1994",
        now,
    ));
    try std.testing.expectEqual(@as(?u64, retry_after_max_ms), parseRetryAfter(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        std.math.minInt(i64),
    ));
    try std.testing.expect(parseRetryAfter(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        std.math.maxInt(i64),
    ) == null);
}

test "legacy HTTP date validates weekday grammar and uses the fifty year rule" {
    const now_2026 = dateTimeToUnix(2026, 8, 24, 0, 0, 0).?;
    try std.testing.expect(parseRetryAfter("Bad, 25 Aug 2026 00:00:00 GMT", now_2026) == null);
    try std.testing.expect(parseRetryAfter("Whatever, 25-Aug-26 00:00:00 GMT", now_2026) == null);
    try std.testing.expect(parseRetryAfter("Bad Aug 25 00:00:00 2026", now_2026) == null);
    try std.testing.expectEqual(@as(?u64, retry_after_max_ms), parseRetryAfter(
        "Sunday, 06-Nov-70 08:49:37 GMT",
        now_2026,
    ));
    try std.testing.expect(parseRetryAfter(
        "Sunday, 06-Nov-76 08:49:37 GMT",
        now_2026,
    ) == null);
}
