//! Partial JSON parser — parses possibly-incomplete JSON generated
//! by LLMs during streaming. Port of promplate/partial-json-parser-js
//! (the npm `partial-json` package pi-mono uses for tool-argument
//! streaming), targeting `std.json.Value` as the output type.
//!
//! Design notes in zi-wub.N / oracle review:
//!   - Output is `std.json.Value` so every existing consumer works
//!     unchanged (cloneJsonValue, freeJsonValue, lua render hooks).
//!   - `Allow` is a packed-struct bitmask; `toInt`/`fromInt` lock
//!     wire order for fixture compatibility with pi-mono's numeric
//!     Allow values.
//!   - Escape decoding is delegated to `std.json.parseFromSliceLeaky`
//!     via a synthesized `"..."` slice — correct by construction
//!     (handles `\uXXXX`, surrogate pairs, all C escapes).
//!   - Numbers round-trip through `Value.parseFromNumberSlice` to
//!     match stdlib's .integer / .float / .number_string discipline.
//!   - Arena lifetime model: caller passes an allocator (typically
//!     a short-lived scratch arena). Returned Value's nested strings
//!     / keys / children all live there. No deinit walker.
//!   - `parseStreaming` mirrors pi-mono's parseStreamingJson:
//!     strict-first, fall back to partial with Allow.all, swallow
//!     syntax failures into `{}`. OOM is propagated, not hidden.
//!   - Recursion depth is capped to protect against adversarial
//!     nesting; stdlib's dynamic parser uses an explicit stack,
//!     we use recursion bounded by `max_depth`.

const std = @import("std");

/// Bit flags controlling which value kinds may remain partial
/// without erroring. Matches promplate's `Allow` enum semantics;
/// bit layout is stable — `toInt` produces values compatible with
/// pi-mono fixtures captured via the npm package.
pub const Allow = packed struct(u8) {
    str: bool = false,
    num: bool = false,
    arr: bool = false,
    obj: bool = false,
    nul: bool = false,
    boolean: bool = false,
    nan: bool = false,
    infinity: bool = false,

    pub const none: Allow = .{};
    pub const all: Allow = @bitCast(@as(u8, 0xff));
    /// What `parseStreaming` uses internally — matches pi-mono's
    /// `parseStreamingJson`, which passes `Allow.ALL`.
    pub const streaming: Allow = all;

    pub fn fromInt(bits: u8) Allow {
        return @bitCast(bits);
    }
    pub fn toInt(self: Allow) u8 {
        return @bitCast(self);
    }
};

pub const ParseError = error{
    /// Input was truncated at a position where the current `Allow`
    /// flags did not permit a partial return.
    Partial,
    /// Input was syntactically invalid (not merely truncated).
    Malformed,
    /// Recursion depth exceeded `max_depth`. Guards against
    /// adversarial deeply-nested JSON blowing the call stack.
    TooDeep,
    OutOfMemory,
};

const max_depth: u16 = 256;

/// Parse possibly-incomplete JSON with explicit allowance flags.
/// Returns whatever structure is complete so far; partial kinds
/// selected by `allow` are completed best-effort.
///
/// All nested allocations (object keys, string payloads, child
/// containers) live in `allocator`. Caller owns the tree — free it
/// by dropping the arena, or via a structural walker if using a
/// general-purpose allocator.
pub fn parse(
    allocator: std.mem.Allocator,
    src: []const u8,
    allow: Allow,
) ParseError!std.json.Value {
    if (isBlank(src)) return ParseError.Partial;
    var p: Parser = .{
        .src = src,
        .index = 0,
        .allow = allow,
        .arena = allocator,
        .depth = 0,
    };
    p.skipBlank();
    const value = try p.parseAny();
    return value;
}

/// Strict-first streaming wrapper. Mirrors pi-mono's
/// `parseStreamingJson`:
///
///   - blank input            → `{}`
///   - strict parse success   → the value
///   - strict syntax failure  → retry as partial with `Allow.all`
///   - partial parse failure  → `{}`
///   - OutOfMemory anywhere   → propagated
///
/// OOM is intentionally NOT hidden behind `{}` — swallowing it
/// would turn a real allocator failure into bogus tool arguments,
/// which is strictly worse than failing loud.
pub fn parseStreaming(
    allocator: std.mem.Allocator,
    src: []const u8,
) error{OutOfMemory}!std.json.Value {
    if (isBlank(src)) return emptyObject(allocator);

    if (std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        src,
        .{},
    )) |value| {
        return value;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    if (parse(allocator, src, .all)) |value| {
        return value;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return emptyObject(allocator),
    }
}

fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    _ = allocator;
    return .{ .object = .{} };
}

fn isBlank(src: []const u8) bool {
    for (src) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}

// =================================================================
// Parser
// =================================================================

const Parser = struct {
    src: []const u8,
    index: usize,
    allow: Allow,
    arena: std.mem.Allocator,
    depth: u16,

    fn skipBlank(self: *Parser) void {
        while (self.index < self.src.len) {
            const c = self.src[self.index];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.index += 1;
        }
    }

    fn parseAny(self: *Parser) ParseError!std.json.Value {
        self.skipBlank();
        if (self.index >= self.src.len) return ParseError.Partial;

        const c = self.src[self.index];
        switch (c) {
            '"' => return .{ .string = try self.parseStr() },
            '{' => return try self.parseObj(),
            '[' => return try self.parseArr(),
            't' => return try self.parseLiteral("true", .{ .bool = true }, self.allow.boolean),
            'f' => return try self.parseLiteral("false", .{ .bool = false }, self.allow.boolean),
            'n' => return try self.parseLiteral("null", .null, self.allow.nul),
            '-', '0'...'9' => return try self.parseNum(),
            'I' => return try self.parseLiteral("Infinity", .{ .float = std.math.inf(f64) }, self.allow.infinity),
            'N' => return try self.parseLiteral("NaN", .{ .float = std.math.nan(f64) }, self.allow.nan),
            else => return ParseError.Malformed,
        }
    }

    /// Matches a fixed literal or, if truncated and `allow_bit` is
    /// set, treats a valid prefix as the full literal.
    fn parseLiteral(
        self: *Parser,
        lit: []const u8,
        value: std.json.Value,
        allow_bit: bool,
    ) ParseError!std.json.Value {
        const remaining = self.src[self.index..];
        if (remaining.len >= lit.len and std.mem.eql(u8, remaining[0..lit.len], lit)) {
            self.index += lit.len;
            return value;
        }
        // Partial: remaining is a strict prefix of lit.
        if (allow_bit and remaining.len < lit.len and std.mem.startsWith(u8, lit, remaining)) {
            self.index = self.src.len;
            return value;
        }
        return ParseError.Malformed;
    }

    /// Parse a JSON string. Returns an owned slice in `self.arena`.
    ///
    /// Strategy: scan the raw source to find either the closing
    /// quote or the last position where the content forms a valid
    /// decoded prefix, then synthesize a `"..."` document and
    /// delegate to `std.json.parseFromSliceLeaky`. This inherits
    /// stdlib's escape handling (`\uXXXX`, surrogate pairs, all C
    /// escapes) correctly by construction.
    fn parseStr(self: *Parser) ParseError![]const u8 {
        std.debug.assert(self.src[self.index] == '"');
        const body_start = self.index + 1;
        var i = body_start;
        // `safe_end` = exclusive end of the last prefix of the body
        // that forms a valid JSON string when re-quoted. Advanced
        // only after completing a full escape or safe literal byte.
        var safe_end: usize = body_start;
        // Tracks an orphan high-surrogate `\uD8xx-\uDBxx` awaiting
        // its low surrogate half. While pending, `safe_end` must
        // NOT advance past the high surrogate because a re-quote
        // truncated there would be an unpaired surrogate.
        var pending_high_surrogate: bool = false;

        while (i < self.src.len) {
            const c = self.src[i];
            if (c == '"') {
                // Complete string. Delegate full decode to stdlib.
                const decoded = try self.decodeStringBody(self.src[body_start..i]);
                self.index = i + 1;
                return decoded;
            }
            if (c == '\\') {
                // Need at least one more byte to know the escape.
                if (i + 1 >= self.src.len) break;
                const nxt = self.src[i + 1];
                switch (nxt) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        i += 2;
                        if (!pending_high_surrogate) safe_end = i;
                    },
                    'u' => {
                        if (i + 6 > self.src.len) break;
                        var h: usize = 0;
                        while (h < 4) : (h += 1) {
                            if (!isHex(self.src[i + 2 + h])) return ParseError.Malformed;
                        }
                        const cp = parseHex4(self.src[i + 2 .. i + 6]);
                        i += 6;
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            // High surrogate — do NOT advance
                            // safe_end; wait for the low half.
                            pending_high_surrogate = true;
                        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                            if (!pending_high_surrogate) {
                                // Unpaired low surrogate. stdlib
                                // will reject; surface as Malformed.
                                return ParseError.Malformed;
                            }
                            pending_high_surrogate = false;
                            safe_end = i;
                        } else {
                            safe_end = i;
                        }
                    },
                    else => return ParseError.Malformed,
                }
                continue;
            }
            if (c < 0x20) return ParseError.Malformed;
            if (pending_high_surrogate) {
                // High surrogate must be immediately followed by a
                // `\u` low-surrogate escape; any other byte is an
                // unpaired high surrogate.
                return ParseError.Malformed;
            }
            i += 1;
            safe_end = i;
        }

        // EOF inside string.
        if (!self.allow.str) return ParseError.Partial;
        const decoded = try self.decodeStringBody(self.src[body_start..safe_end]);
        self.index = self.src.len;
        return decoded;
    }

    /// Decode a raw string body (WITHOUT surrounding quotes) into
    /// an owned slice via stdlib's string parser.
    fn decodeStringBody(self: *Parser, body: []const u8) ParseError![]const u8 {
        var buf = try self.arena.alloc(u8, body.len + 2);
        buf[0] = '"';
        @memcpy(buf[1 .. 1 + body.len], body);
        buf[1 + body.len] = '"';
        const val = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.arena,
            buf,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return ParseError.OutOfMemory,
            else => return ParseError.Malformed,
        };
        return switch (val) {
            .string => |s| s,
            else => ParseError.Malformed,
        };
    }

    fn parseObj(self: *Parser) ParseError!std.json.Value {
        if (self.depth >= max_depth) return ParseError.TooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        std.debug.assert(self.src[self.index] == '{');
        self.index += 1;

        var obj: std.json.ObjectMap = .{};

        while (true) {
            self.skipBlank();
            if (self.index >= self.src.len) {
                if (self.allow.obj) return .{ .object = obj };
                return ParseError.Partial;
            }
            if (self.src[self.index] == '}') {
                self.index += 1;
                return .{ .object = obj };
            }

            // Key must be a string; a bare key is malformed.
            if (self.src[self.index] != '"') {
                if (self.allow.obj) return .{ .object = obj };
                return ParseError.Malformed;
            }

            const key = self.parseStr() catch |err| switch (err) {
                error.Partial, error.OutOfMemory, error.TooDeep => return err,
                error.Malformed => {
                    if (self.allow.obj) return .{ .object = obj };
                    return err;
                },
            };
            // Key is already owned by `self.arena` via decodeStringBody.

            self.skipBlank();
            if (self.index >= self.src.len or self.src[self.index] != ':') {
                if (self.allow.obj) return .{ .object = obj };
                return ParseError.Partial;
            }
            self.index += 1;

            const value = self.parseAny() catch |err| switch (err) {
                error.OutOfMemory, error.TooDeep => return err,
                error.Partial, error.Malformed => {
                    if (self.allow.obj) return .{ .object = obj };
                    return err;
                },
            };

            try obj.put(self.arena, key, value);

            self.skipBlank();
            if (self.index < self.src.len and self.src[self.index] == ',') {
                self.index += 1;
                continue;
            }
        }
    }

    fn parseArr(self: *Parser) ParseError!std.json.Value {
        if (self.depth >= max_depth) return ParseError.TooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        std.debug.assert(self.src[self.index] == '[');
        self.index += 1;

        var arr = std.json.Array.init(self.arena);

        while (true) {
            self.skipBlank();
            if (self.index >= self.src.len) {
                if (self.allow.arr) return .{ .array = arr };
                return ParseError.Partial;
            }
            if (self.src[self.index] == ']') {
                self.index += 1;
                return .{ .array = arr };
            }

            const value = self.parseAny() catch |err| switch (err) {
                error.OutOfMemory, error.TooDeep => return err,
                error.Partial, error.Malformed => {
                    if (self.allow.arr) return .{ .array = arr };
                    return err;
                },
            };
            try arr.append(value);

            self.skipBlank();
            if (self.index < self.src.len and self.src[self.index] == ',') {
                self.index += 1;
                continue;
            }
        }
    }

    fn parseNum(self: *Parser) ParseError!std.json.Value {
        const start = self.index;
        if (self.src[self.index] == '-') self.index += 1;
        while (self.index < self.src.len) {
            const c = self.src[self.index];
            if (c == ',' or c == ']' or c == '}' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.index += 1;
        }
        const raw = self.src[start..self.index];
        const at_eof = self.index == self.src.len;

        if (validateNumberSlice(raw)) {
            return std.json.Value.parseFromNumberSlice(raw);
        }

        if (!at_eof or !self.allow.num) return ParseError.Malformed;

        // Partial: progressively trim trailing junk characters
        // until the remainder is a valid number. Matches the broad
        // heuristic decision: trim `e`, `E`, `+`, `-`, `.` — these
        // are the only chars stdlib accepts mid-number that can
        // also appear truncated. Works for every provider, not just
        // Anthropic.
        var s = raw;
        while (s.len > 0) {
            const last = s[s.len - 1];
            if (last != 'e' and last != 'E' and last != '+' and last != '-' and last != '.') break;
            s = s[0 .. s.len - 1];
            if (s.len > 0 and validateNumberSlice(s)) {
                return std.json.Value.parseFromNumberSlice(s);
            }
        }
        return ParseError.Malformed;
    }
};

fn validateNumberSlice(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.json.Scanner.isNumberFormattedLikeAnInteger(s)) {
        _ = std.fmt.parseInt(i64, s, 10) catch |e| switch (e) {
            // Overflow still parses (→ .number_string), but InvalidCharacter doesn't.
            error.Overflow => return true,
            error.InvalidCharacter => return false,
        };
        return true;
    }
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn parseHex4(s: []const u8) u32 {
    var r: u32 = 0;
    for (s[0..4]) |c| {
        r = (r << 4) | @as(u32, switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => unreachable,
        });
    }
    return r;
}

// =================================================================
// Tests
// =================================================================

const testing = std.testing;

/// Canonicalize a `std.json.Value` to a byte string for structural
/// equality comparison. Deterministic regardless of internal map
/// insertion order — key order is preserved from the source because
/// `ObjectMap` is an ArrayHashMap, so this also doubles as an
/// order-sensitive check, which is what we want for LLM streaming
/// (key-emission order matters).
fn canonicalize(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn expectEqualJson(a: std.json.Value, b: std.json.Value) !void {
    const ca = try canonicalize(testing.allocator, a);
    defer testing.allocator.free(ca);
    const cb = try canonicalize(testing.allocator, b);
    defer testing.allocator.free(cb);
    try testing.expectEqualStrings(ca, cb);
}

test "Allow bit order: toInt / fromInt round-trip matches documented layout" {
    try testing.expectEqual(@as(u8, 0x00), Allow.none.toInt());
    try testing.expectEqual(@as(u8, 0xff), Allow.all.toInt());
    try testing.expectEqual(@as(u8, 0x01), (Allow{ .str = true }).toInt());
    try testing.expectEqual(@as(u8, 0x02), (Allow{ .num = true }).toInt());
    try testing.expectEqual(@as(u8, 0x04), (Allow{ .arr = true }).toInt());
    try testing.expectEqual(@as(u8, 0x08), (Allow{ .obj = true }).toInt());
    try testing.expectEqual(@as(u8, 0x10), (Allow{ .nul = true }).toInt());
    try testing.expectEqual(@as(u8, 0x20), (Allow{ .boolean = true }).toInt());
    const rt = Allow.fromInt(0b10101010);
    try testing.expectEqual(@as(u8, 0b10101010), rt.toInt());
}

test "strict equivalence: complete JSON matches std.json.parseFromSliceLeaky across a small corpus" {
    const corpus = [_][]const u8{
        \\{"a":1,"b":2.5,"c":"hello","d":true,"e":null,"f":[1,2,3],"g":{"nested":"yes"}}
        ,
        \\[1,"two",3.14,false,null,[],{}]
        ,
        \\{"unicode":"caf\u00e9 \u00e4\u00f6\u00fc","emoji":"\ud83d\ude00","escapes":"a\nb\tc\"d\\e"}
        ,
        \\{"ints":[0,-1,42,9223372036854775807],"floats":[0.0,-1.5,1e10,-2.3e-4]}
        ,
        \\"just a string"
        ,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (corpus) |src| {
        const strict = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), src, .{});
        const ours = try parse(arena.allocator(), src, .none);
        try expectEqualJson(strict, ours);
    }
}

test "cut points: every truncation of a real tool-call payload yields a usable Value under Allow.all" {
    const full =
        \\{"path":"/foo/bar.zig","old_str":"a {b} c","count":42,"flags":[true,false,null],"meta":{"k":"v"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Every non-empty prefix must parse to an object under Allow.all.
    // The final full parse must structurally match the strict parse.
    var i: usize = 1;
    while (i <= full.len) : (i += 1) {
        const prefix = full[0..i];
        const value = parse(arena.allocator(), prefix, .all) catch |err| {
            std.debug.print("prefix[0..{d}] = `{s}` failed: {s}\n", .{ i, prefix, @errorName(err) });
            return err;
        };
        // Top level must remain an object for every prefix of an object literal.
        try testing.expect(value == .object);
    }
    const full_strict = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), full, .{});
    const full_ours = try parse(arena.allocator(), full, .all);
    try expectEqualJson(full_strict, full_ours);
}

test "cut points: specific hot spots (mid-string, mid-escape, mid-number, mid-literal, after :, after ,)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Mid-string body.
    {
        const v = try parse(alloc, "{\"path\":\"/foo/ba", .all);
        try testing.expect(v == .object);
        const got = v.object.get("path").?;
        try testing.expectEqualStrings("/foo/ba", got.string);
    }
    // Mid escape: backslash at end (string is truncated; safe_end
    // doesn't advance past the orphan backslash).
    {
        const v = try parse(alloc, "{\"s\":\"hello\\", .all);
        try testing.expect(v == .object);
        try testing.expectEqualStrings("hello", v.object.get("s").?.string);
    }
    // Mid \uXXXX escape.
    {
        const v = try parse(alloc, "{\"s\":\"ab\\u00", .all);
        try testing.expect(v == .object);
        try testing.expectEqualStrings("ab", v.object.get("s").?.string);
    }
    // Mid number (trailing exponent marker).
    {
        const v = try parse(alloc, "{\"n\":1.5e", .all);
        try testing.expect(v == .object);
        const n = v.object.get("n").?;
        try testing.expectApproxEqAbs(@as(f64, 1.5), n.float, 1e-9);
    }
    // Mid literal ("tru").
    {
        const v = try parse(alloc, "{\"ok\":tru", .all);
        try testing.expect(v == .object);
        try testing.expect(v.object.get("ok").?.bool == true);
    }
    // After colon with no value yet.
    {
        const v = try parse(alloc, "{\"k\":", .all);
        try testing.expect(v == .object);
        // No key committed — parseAny raised Partial before put().
        try testing.expectEqual(@as(usize, 0), v.object.count());
    }
    // After comma with no next key — container closes without that entry.
    {
        const v = try parse(alloc, "{\"a\":1,", .all);
        try testing.expect(v == .object);
        try testing.expectEqual(@as(usize, 1), v.object.count());
        try testing.expectEqual(@as(i64, 1), v.object.get("a").?.integer);
    }
    // Mid-key (key string itself truncated) — with Allow.all the
    // partial-key str is materialized but no `:` follows, so the
    // object closes without a committed entry.
    {
        const v = try parse(alloc, "{\"par", .all);
        try testing.expect(v == .object);
        try testing.expectEqual(@as(usize, 0), v.object.count());
    }
}

test "parseStreaming: blank and total-failure both return empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const blank = try parseStreaming(arena.allocator(), "   \n\t");
    try testing.expect(blank == .object);
    try testing.expectEqual(@as(usize, 0), blank.object.count());

    const garbage = try parseStreaming(arena.allocator(), "@@@not json@@@");
    try testing.expect(garbage == .object);
    try testing.expectEqual(@as(usize, 0), garbage.object.count());

    const ok = try parseStreaming(arena.allocator(), "{\"a\":1}");
    try testing.expect(ok == .object);
    try testing.expectEqual(@as(i64, 1), ok.object.get("a").?.integer);

    const partial = try parseStreaming(arena.allocator(), "{\"a\":1,\"b\":\"hel");
    try testing.expect(partial == .object);
    try testing.expectEqualStrings("hel", partial.object.get("b").?.string);
}

test "malformed input returns Malformed, not Partial" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Invalid escape mid-string.
    try testing.expectError(ParseError.Malformed, parse(arena.allocator(), "{\"s\":\"\\x\"}", .none));
    // Bare identifier where a value is expected. Under Allow.none
    // the object cannot swallow the inner error.
    try testing.expectError(ParseError.Malformed, parse(arena.allocator(), "{\"k\":@}", .none));
}

test "depth guard: deeply nested arrays trip TooDeep instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < max_depth + 16) : (i += 1) try buf.append(testing.allocator, '[');
    try testing.expectError(ParseError.TooDeep, parse(arena.allocator(), buf.items, .all));
}
