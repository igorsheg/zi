const std = @import("std");

pub const max_tokens = 32;
pub const max_ors = 8;

pub const CaseMode = enum { ignore, respect, smart };

pub const Options = struct {
    case_mode: CaseMode = .smart,
};

pub const Mode = enum {
    fuzzy,
    exact,
    word,
    prefix,
    suffix,
};

pub const Token = struct {
    text: []const u8,
    mode: Mode = .fuzzy,
    inverse: bool = false,
    field: ?[]const u8 = null,
    ignore_case: bool = true,
};

pub const Clause = struct {
    alts: [max_ors]Token = undefined,
    len: usize = 0,

    pub fn slice(self: *const Clause) []const Token {
        return self.alts[0..self.len];
    }
};

pub const Query = struct {
    clauses: [max_tokens]Clause = undefined,
    len: usize = 0,
    empty: bool = true,

    pub fn slice(self: *const Query) []const Clause {
        return self.clauses[0..self.len];
    }
};

pub fn parse(pattern: []const u8, opts: Options) Query {
    const trimmed = std.mem.trim(u8, pattern, " \t\r\n");
    var q = Query{};
    if (trimmed.len == 0) return q;
    q.empty = false;

    var pending_or = false;
    var iter = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (iter.next()) |raw_part| {
        if (std.mem.eql(u8, raw_part, "|")) {
            pending_or = true;
            continue;
        }
        const tok = prepareToken(raw_part, opts) orelse continue;
        if (pending_or and q.len > 0 and q.clauses[q.len - 1].len < max_ors) {
            q.clauses[q.len - 1].alts[q.clauses[q.len - 1].len] = tok;
            q.clauses[q.len - 1].len += 1;
        } else if (q.len < max_tokens) {
            q.clauses[q.len] = Clause{};
            q.clauses[q.len].alts[0] = tok;
            q.clauses[q.len].len = 1;
            q.len += 1;
        }
        pending_or = false;
    }

    sortClauses(&q);
    return q;
}

fn prepareToken(raw: []const u8, opts: Options) ?Token {
    var text = raw;
    if (text.len == 0) return null;

    var inverse = false;
    if (text[0] == '!') {
        inverse = true;
        text = text[1..];
    }
    if (text.len == 0) return null;

    var field: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        if (colon > 0 and isFieldName(text[0..colon])) {
            field = text[0..colon];
            text = text[colon + 1 ..];
        }
    }
    if (text.len == 0) return null;

    var mode: Mode = .fuzzy;
    if (text[0] == '\'') {
        mode = .exact;
        text = text[1..];
        if (text.len >= 1 and text[text.len - 1] == '\'') {
            mode = .word;
            text = text[0 .. text.len - 1];
        }
    } else if (text[0] == '^') {
        mode = .prefix;
        text = text[1..];
    } else if (text.len > 1 and text[text.len - 1] == '$') {
        mode = .suffix;
        text = text[0 .. text.len - 1];
    }
    if (text.len == 0) return null;

    return .{
        .text = text,
        .mode = mode,
        .inverse = inverse,
        .field = field,
        .ignore_case = switch (opts.case_mode) {
            .ignore => true,
            .respect => false,
            .smart => isAllLower(text),
        },
    };
}

fn isFieldName(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isAllLower(s: []const u8) bool {
    for (s) |c| if (std.ascii.isAlphabetic(c) and std.ascii.isUpper(c)) return false;
    return true;
}

fn tokenCost(t: Token) u32 {
    var cost: u32 = @intCast(@min(t.text.len, 255));
    cost += switch (t.mode) { .fuzzy => 0, .exact => 20, .word => 30, .prefix => 25, .suffix => 25 };
    if (t.inverse) cost += 40;
    return cost;
}

fn sortClauses(q: *Query) void {
    var i: usize = 1;
    while (i < q.len) : (i += 1) {
        const c = q.clauses[i];
        const cost = tokenCost(c.alts[0]);
        var j = i;
        while (j > 0 and cost > tokenCost(q.clauses[j - 1].alts[0])) : (j -= 1) {
            q.clauses[j] = q.clauses[j - 1];
        }
        q.clauses[j] = c;
    }
}

test "query parses AND OR inverse exact prefix suffix smartcase" {
    const q = parse("foo | bar !baz 'qux ^Pre end$", .{});
    try std.testing.expectEqual(@as(usize, 5), q.len);
    var saw_or = false;
    for (q.slice()) |clause| {
        if (clause.len == 2) saw_or = true;
    }
    try std.testing.expect(saw_or);
}
