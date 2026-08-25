const std = @import("std");
const SecureAllocator = @import("SecureAllocator.zig");

/// Codex's configuration file is small in normal use. Oversized input is treated
/// like an unusable file, matching hax's silent handling of missing/bad settings.
pub const maximum_file_bytes: usize = 64 * 1024;
pub const maximum_string_bytes: usize = 8 * 1024;

/// Owned defaults copied from the top level of a Codex config. Move this value;
/// do not copy it. Deinitialization wipes both copied values before release.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    model: ?[]u8 = null,
    model_reasoning_effort: ?[]u8 = null,

    pub fn deinit(self: *Owned) void {
        if (self.model) |value| SecureAllocator.wipeFree(self.allocator, value);
        if (self.model_reasoning_effort) |value| SecureAllocator.wipeFree(self.allocator, value);
        self.* = undefined;
    }
};

const ParsedString = union(enum) {
    absent,
    empty,
    value: []u8,
};

/// Parse the bounded, borrowed contents of `~/.codex/config.toml`.
///
/// This intentionally implements hax's small Codex-written TOML subset rather
/// than general TOML. The first assignment for each key wins, malformed values
/// are absent, and scanning stops at the first table header. The input is never
/// retained or copied. Only returned values allocate.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!Owned {
    var result: Owned = .{ .allocator = allocator };
    errdefer result.deinit();
    if (bytes.len > maximum_file_bytes) return result;

    var tried_model = false;
    var tried_effort = false;
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const relative_end = std.mem.findScalar(u8, bytes[cursor..], '\n');
        const line_end = if (relative_end) |offset| cursor + offset else bytes.len;
        const line = bytes[cursor..line_end];
        const assignment = skipInlineWhitespace(line);
        if (assignment.len > 0 and assignment[0] == '[') break;

        if (!tried_model) {
            if (keyValue(assignment, "model")) |raw_value| {
                tried_model = true;
                switch (try parseString(allocator, raw_value)) {
                    .value => |value| result.model = value,
                    .absent, .empty => {},
                }
            }
        }
        if (!tried_effort) {
            if (keyValue(assignment, "model_reasoning_effort")) |raw_value| {
                tried_effort = true;
                switch (try parseString(allocator, raw_value)) {
                    .value => |value| result.model_reasoning_effort = value,
                    .absent, .empty => {},
                }
            }
        }
        if (tried_model and tried_effort) break;
        cursor = if (line_end < bytes.len) line_end + 1 else bytes.len;
    }
    return result;
}

fn skipInlineWhitespace(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return bytes[index..];
}

fn keyValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (line.len < key.len or !std.mem.eql(u8, line[0..key.len], key)) return null;
    if (line.len > key.len) {
        const boundary = line[key.len];
        if (boundary != '=' and boundary != ' ' and boundary != '\t') return null;
    }
    const remainder = skipInlineWhitespace(line[key.len..]);
    if (remainder.len == 0 or remainder[0] != '=') return null;
    return skipInlineWhitespace(remainder[1..]);
}

fn parseString(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!ParsedString {
    if (bytes.len == 0 or (bytes[0] != '"' and bytes[0] != '\'')) return .absent;
    const quote = bytes[0];
    var input_index: usize = 1;
    var output_len: usize = 0;
    while (input_index < bytes.len) {
        const byte = bytes[input_index];
        input_index += 1;
        if (byte == quote) {
            if (output_len == 0) return .empty;
            const output = try allocator.alloc(u8, output_len);
            errdefer SecureAllocator.wipeFree(allocator, output);
            decodeString(output, bytes[1 .. input_index - 1], quote);
            return .{ .value = output };
        }
        if (quote == '"' and byte == '\\' and input_index < bytes.len) input_index += 1;
        output_len += 1;
        if (output_len > maximum_string_bytes) return .absent;
    }
    return .absent;
}

fn decodeString(output: []u8, encoded: []const u8, quote: u8) void {
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < encoded.len) {
        var byte = encoded[input_index];
        input_index += 1;
        if (quote == '"' and byte == '\\' and input_index < encoded.len) {
            byte = encoded[input_index];
            input_index += 1;
            byte = switch (byte) {
                'b' => '\x08',
                't' => '\t',
                'n' => '\n',
                'f' => '\x0c',
                'r' => '\r',
                else => byte,
            };
        }
        output[output_index] = byte;
        output_index += 1;
    }
    std.debug.assert(output_index == output.len);
}

fn expectSettings(bytes: []const u8, model: ?[]const u8, effort: ?[]const u8) !void {
    var settings = try parse(std.testing.allocator, bytes);
    defer settings.deinit();
    if (model) |expected| {
        try std.testing.expectEqualStrings(expected, settings.model orelse return error.TestExpectedEqual);
    } else try std.testing.expect(settings.model == null);
    if (effort) |expected| {
        try std.testing.expectEqualStrings(
            expected,
            settings.model_reasoning_effort orelse return error.TestExpectedEqual,
        );
    } else try std.testing.expect(settings.model_reasoning_effort == null);
}

test "parses Codex top-level basic and literal strings" {
    try expectSettings(
        "model = \"gpt-5.3-codex\"\nmodel_reasoning_effort='high'\n",
        "gpt-5.3-codex",
        "high",
    );
    try expectSettings("   model   =   \"o3\" trailing text\n", "o3", null);
    try expectSettings("\tmodel\t=\t\"o3\" # ignored suffix\r\n", "o3", null);
    try expectSettings("model=\"hash#inside\"", "hash#inside", null);
}

test "matches exact keys and ignores comments and unrelated input" {
    try expectSettings(
        "# model = \"commented\"\nmod = \"short\"\nmodel.other = \"dotted\"\nother = 3\nmodel = \"real\"\n",
        "real",
        null,
    );
    try expectSettings("model_reasoning_effort = \"high\"\n", null, "high");
    try expectSettings("\n\n# nothing\n", null, null);
}

test "first assignment wins independently and first table stops scanning" {
    try expectSettings(
        "model = \"first\"\nmodel = \"second\"\nmodel_reasoning_effort = \"low\"\n",
        "first",
        "low",
    );
    try expectSettings("model = 3\nmodel = \"later\"\n", null, null);
    try expectSettings("model = \"top\"\n [profiles.work]\nmodel_reasoning_effort = \"nested\"\n", "top", null);
    try expectSettings("  [tui]\nmodel = \"nested\"\n", null, null);
}

test "basic string escapes match hax" {
    try expectSettings(
        "model = \"a\\tb\\nc\\\"d\\\\e\\bf\\fg\\rh\\zi\"\n",
        "a\tb\nc\"d\\e\x08f\x0cg\rhzi",
        null,
    );
}

test "literal strings preserve backslashes" {
    try expectSettings("model = 'a\\tb'\nmodel_reasoning_effort = 'a\\'\n", "a\\tb", "a\\");
}

test "empty malformed and non-string values are absent" {
    try expectSettings("model = \"\"\nmodel_reasoning_effort = ''\n", null, null);
    try expectSettings("model = \"unterminated\nmodel_reasoning_effort = 'unterminated\n", null, null);
    try expectSettings("model = true\nmodel_reasoning_effort =\n", null, null);
    try expectSettings("model\nmodel_reasoning_effort\n", null, null);
}

test "input and decoded strings are bounded" {
    const oversized_file = try std.testing.allocator.alloc(u8, maximum_file_bytes + 1);
    defer std.testing.allocator.free(oversized_file);
    @memset(oversized_file, '\n');
    try expectSettings(oversized_file, null, null);

    const prefix = "model = \"";
    const suffix = "\"\nmodel_reasoning_effort = \"high\"\n";
    const oversized_string = try std.testing.allocator.alloc(u8, prefix.len + maximum_string_bytes + 1 + suffix.len);
    defer std.testing.allocator.free(oversized_string);
    @memcpy(oversized_string[0..prefix.len], prefix);
    @memset(oversized_string[prefix.len .. prefix.len + maximum_string_bytes + 1], 'x');
    @memcpy(oversized_string[prefix.len + maximum_string_bytes + 1 ..], suffix);
    try expectSettings(oversized_string, null, "high");
}

test "deinit wipes copied settings" {
    var observer = SecureAllocator.FreeObserver.init(std.testing.allocator);
    var settings = try parse(observer.allocator(), "model='secret-model'\nmodel_reasoning_effort='secret-effort'\n");
    settings.deinit();
    try std.testing.expectEqual(@as(usize, 2), observer.zero_frees);
    try std.testing.expectEqual(@as(usize, 0), observer.other_frees);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var settings = try parse(allocator, "model=\"first\"\nmodel_reasoning_effort=\"high\"\n");
    settings.deinit();
}

test "allocation failures do not leak copied settings" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
