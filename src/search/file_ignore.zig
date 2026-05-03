const std = @import("std");

pub const Stack = struct {
    layers: std.ArrayList(Layer) = .empty,

    const Layer = struct {
        rel_root: []const u8,
        owns_rel_root: bool,
        patterns: std.ArrayList(Pattern),

        fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
            if (self.owns_rel_root) allocator.free(self.rel_root);
            for (self.patterns.items) |pattern| allocator.free(pattern.text);
            self.patterns.deinit(allocator);
        }
    };

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        for (self.layers.items) |*layer| layer.deinit(allocator);
        self.layers.deinit(allocator);
        self.* = .{};
    }

    pub fn mark(self: *const Stack) usize {
        return self.layers.items.len;
    }

    pub fn popTo(self: *Stack, allocator: std.mem.Allocator, len: usize) void {
        while (self.layers.items.len > len) {
            var layer = self.layers.pop().?;
            layer.deinit(allocator);
        }
    }

    pub fn tryPushDir(self: *Stack, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel_dir: []const u8) !bool {
        var patterns = std.ArrayList(Pattern).empty;
        errdefer patterns.deinit(allocator);

        var found = false;
        for ([_][]const u8{ ".gitignore", ".ignore", ".fdignore" }) |name| {
            const content = dir.readFileAlloc(io, name, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.StreamTooLong => continue,
                else => return err,
            };
            defer allocator.free(content);
            try parseInto(allocator, content, &patterns);
            found = true;
        }
        if (!found) return false;

        const rel_root = if (rel_dir.len == 0) rel_dir else try allocator.dupe(u8, rel_dir);
        errdefer if (rel_dir.len != 0) allocator.free(rel_root);
        try self.layers.append(allocator, .{
            .rel_root = rel_root,
            .owns_rel_root = rel_dir.len != 0,
            .patterns = patterns,
        });
        return true;
    }

    pub fn shouldIgnore(self: *const Stack, rel_path: []const u8, is_dir: bool) bool {
        if (isGitDir(rel_path, is_dir)) return true;

        var ignored = false;
        for (self.layers.items) |layer| {
            const local_path = localPath(layer.rel_root, rel_path) orelse continue;
            for (layer.patterns.items) |pattern| {
                if (pattern.matches(local_path, is_dir)) ignored = !pattern.negated;
            }
        }
        return ignored;
    }
};

const Pattern = struct {
    text: []const u8,
    negated: bool,
    anchored: bool,
    dir_only: bool,
    has_slash: bool,

    fn init(allocator: std.mem.Allocator, line_raw: []const u8) !?Pattern {
        var line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') return null;

        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
        }
        if (line.len == 0) return null;

        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
        }
        if (line.len == 0) return null;

        var dir_only = false;
        if (line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0) return null;

        return .{
            .text = try allocator.dupe(u8, line),
            .negated = negated,
            .anchored = anchored,
            .dir_only = dir_only,
            .has_slash = std.mem.indexOfScalar(u8, line, '/') != null,
        };
    }

    fn matches(self: Pattern, path: []const u8, is_dir: bool) bool {
        if (self.dir_only and !is_dir and !pathHasDirPrefix(path, self.text)) return false;

        if (self.anchored or self.has_slash) {
            return matchPathPattern(self.text, path);
        }

        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |component| {
            if (globMatch(self.text, component)) return true;
        }
        return false;
    }
};

fn parseInto(allocator: std.mem.Allocator, content: []const u8, patterns: *std.ArrayList(Pattern)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (try Pattern.init(allocator, line)) |pattern| {
            try patterns.append(allocator, pattern);
        }
    }
}

fn isGitDir(rel_path: []const u8, is_dir: bool) bool {
    if (!is_dir) return false;
    const base = std.fs.path.basename(rel_path);
    return std.mem.eql(u8, base, ".git");
}

fn localPath(rel_root: []const u8, rel_path: []const u8) ?[]const u8 {
    if (rel_root.len == 0) return rel_path;
    if (std.mem.eql(u8, rel_root, rel_path)) return "";
    if (rel_path.len <= rel_root.len) return null;
    if (!std.mem.startsWith(u8, rel_path, rel_root)) return null;
    if (rel_path[rel_root.len] != '/') return null;
    return rel_path[rel_root.len + 1 ..];
}

fn pathHasDirPrefix(path: []const u8, dir: []const u8) bool {
    return std.mem.eql(u8, path, dir) or
        (std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/');
}

fn matchPathPattern(pattern: []const u8, path: []const u8) bool {
    if (globMatch(pattern, path)) return true;
    return pathHasDirPrefix(path, pattern);
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchAt(pattern, text, 0, 0);
}

fn globMatchAt(pattern: []const u8, text: []const u8, pi_start: usize, ti_start: usize) bool {
    var pi = pi_start;
    var ti = ti_start;
    while (true) {
        if (pi == pattern.len) return ti == text.len;

        if (pattern[pi] == '*') {
            if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                var next_pi = pi + 2;
                if (next_pi < pattern.len and pattern[next_pi] == '/') next_pi += 1;
                var scan = ti;
                while (scan <= text.len) : (scan += 1) {
                    if (globMatchAt(pattern, text, next_pi, scan)) return true;
                }
                return false;
            }

            var scan = ti;
            while (scan <= text.len) : (scan += 1) {
                if (globMatchAt(pattern, text, pi + 1, scan)) return true;
                if (scan == text.len or text[scan] == '/') break;
            }
            return false;
        }

        if (ti == text.len) return false;
        switch (pattern[pi]) {
            '?' => if (text[ti] == '/') return false,
            '\\' => {
                pi += 1;
                if (pi == pattern.len or pattern[pi] != text[ti]) return false;
            },
            else => |c| if (c != text[ti]) return false,
        }
        pi += 1;
        ti += 1;
    }
}

test "ignore stack supports negation and layered rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "serverless\n!/serverless\n*.log\n" });

    var stack = Stack{};
    defer stack.deinit(std.testing.allocator);
    try std.testing.expect(try stack.tryPushDir(std.testing.allocator, io, tmp.dir, ""));
    try std.testing.expect(!stack.shouldIgnore("serverless", true));
    try std.testing.expect(!stack.shouldIgnore("serverless/p3-portal", true));
    try std.testing.expect(stack.shouldIgnore("debug.log", false));
}
