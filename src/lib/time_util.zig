const std = @import("std");

const Error = error{NegativeEpoch};

const ParsedIsoTimestamp = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
};

const UtcParts = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn isoDateNow(allocator: std.mem.Allocator) ![]u8 {
    return formatIsoDate(allocator, std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds());
}

pub fn isoTimestampNow(allocator: std.mem.Allocator) ![]u8 {
    return formatIsoTimestamp(allocator, std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds());
}

pub fn formatIsoDate(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    const parts = try utcParts(epoch_seconds);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        parts.year,
        parts.month,
        parts.day,
    });
}

pub fn formatIsoTimestamp(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    const parts = try utcParts(epoch_seconds);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        parts.year,
        parts.month,
        parts.day,
        parts.hour,
        parts.minute,
        parts.second,
    });
}

pub fn isoToEpochMs(timestamp: []const u8) i64 {
    const secs = parseIsoToEpochSeconds(timestamp) orelse return 0;
    return secs * 1000;
}

pub fn relativeTimeLabel(iso_ts: []const u8) []const u8 {
    return relativeTimeLabelAt(iso_ts, std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds());
}

pub fn relativeTimeLabelAt(iso_ts: []const u8, now_epoch_s: i64) []const u8 {
    const ts_epoch = parseIsoToEpochSeconds(iso_ts) orelse return iso_ts;
    const diff = now_epoch_s - ts_epoch;
    if (diff < 0) return "now";

    const diff_u: u64 = @intCast(diff);
    if (diff_u < 60) return "now";
    if (diff_u < 3600) {
        const mins = diff_u / 60;
        return switch (mins) {
            1 => "1m",
            2 => "2m",
            3 => "3m",
            5 => "5m",
            10 => "10m",
            15 => "15m",
            30 => "30m",
            else => if (mins < 5) "few min" else if (mins < 30) "<30m" else "<1h",
        };
    }
    if (diff_u < 86400) {
        const hours = diff_u / 3600;
        return switch (hours) {
            1 => "1h",
            2 => "2h",
            3 => "3h",
            else => if (hours < 12) "<12h" else "<1d",
        };
    }
    const days = diff_u / 86400;
    if (days == 1) return "yesterday";
    if (days < 7) return if (days == 2) "2d" else if (days < 4) "few days" else "<1w";
    if (days < 30) return if (days < 14) "1w" else if (days < 21) "2w" else "3w";
    if (days < 365) {
        const months = days / 30;
        return if (months <= 1) "1mo" else if (months <= 2) "2mo" else if (months <= 6) "<6mo" else "<1y";
    }
    return ">1y";
}

fn utcParts(epoch_seconds: i64) Error!UtcParts {
    if (epoch_seconds < 0) return error.NegativeEpoch;

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_seconds) };
    const day = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = @intCast(year_day.year),
        .month = @intCast(@intFromEnum(month_day.month)),
        .day = @intCast(month_day.day_index + 1),
        .hour = @intCast(day.getHoursIntoDay()),
        .minute = @intCast(day.getMinutesIntoHour()),
        .second = @intCast(day.getSecondsIntoMinute()),
    };
}

fn parseIsoToEpochSeconds(timestamp: []const u8) ?i64 {
    const parts = parseIsoTimestamp(timestamp) orelse return null;
    const m_idx: usize = @intCast(parts.month - 1);
    const max_day = daysInMonth(parts.year, parts.month);
    if (parts.day < 1 or parts.day > max_day) return null;

    const y = parts.year - 1;
    const era_days = y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    const month_days = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    var days = era_days + month_days[m_idx] + parts.day;
    if (parts.month > 2 and isLeapYear(parts.year)) days += 1;

    const unix_days = days - 719163;
    return unix_days * 86400 + parts.hour * 3600 + parts.minute * 60 + parts.second;
}

fn parseIsoTimestamp(timestamp: []const u8) ?ParsedIsoTimestamp {
    if (timestamp.len < 19) return null;
    if (timestamp[4] != '-' or timestamp[7] != '-' or timestamp[10] != 'T' or timestamp[13] != ':' or timestamp[16] != ':') return null;

    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, timestamp[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, timestamp[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, timestamp[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (hour < 0 or hour > 23) return null;
    if (minute < 0 or minute > 59) return null;
    if (second < 0 or second > 59) return null;

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

test "formatIso helpers zero-pad UTC timestamps" {
    const allocator = std.testing.allocator;

    const date = try formatIsoDate(allocator, 0);
    defer allocator.free(date);
    try std.testing.expectEqualStrings("1970-01-01", date);

    const timestamp = try formatIsoTimestamp(allocator, 1709209845);
    defer allocator.free(timestamp);
    try std.testing.expectEqualStrings("2024-02-29T12:30:45.000Z", timestamp);
}

test "isoToEpochMs parses standard ISO timestamps" {
    try std.testing.expectEqual(@as(i64, 1735689600000), isoToEpochMs("2025-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), isoToEpochMs("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1709209845000), isoToEpochMs("2024-02-29T12:30:45.000Z"));
    try std.testing.expectEqual(@as(i64, 0), isoToEpochMs("2025"));
}

test "relativeTimeLabelAt buckets elapsed time" {
    try std.testing.expectEqualStrings("now", relativeTimeLabelAt("2024-02-29T12:30:45Z", 1709209845));
    try std.testing.expectEqualStrings("10m", relativeTimeLabelAt("2024-02-29T12:30:45Z", 1709210445));
    try std.testing.expectEqualStrings("3h", relativeTimeLabelAt("2024-02-29T12:30:45Z", 1709220645));
    try std.testing.expectEqualStrings("yesterday", relativeTimeLabelAt("2024-02-29T12:30:45Z", 1709296245));
}
