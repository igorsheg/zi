const std = @import("std");
const spec = @import("spec.zig");

pub const RawCommand = union(enum) {
    help,
    version,
    run: RawRun,

    pub fn deinit(self: *RawCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*run| run.deinit(allocator),
            .help, .version => {},
        }
        self.* = undefined;
    }
};

pub const RawRun = struct {
    prompt_parts: []const []const u8,
    print: bool = false,
    mode: ?[]const u8 = null,
    model: ?[]const u8 = null,
    no_tools: bool = false,

    fn deinit(self: *RawRun, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt_parts);
        self.* = undefined;
    }
};

pub const Diagnostic = union(enum) {
    unknown_flag: []const u8,
    missing_value: spec.FlagId,
    duplicate_flag: spec.FlagId,
};

pub const Result = union(enum) { ok: RawCommand, err: Diagnostic };

const Seen = struct {
    help: bool = false,
    version: bool = false,
    print: bool = false,
    mode: bool = false,
    model: bool = false,
    no_tools: bool = false,

    fn mark(self: *Seen, id: spec.FlagId) bool {
        const slot = switch (id) {
            .help => &self.help,
            .version => &self.version,
            .print => &self.print,
            .mode => &self.mode,
            .model => &self.model,
            .no_tools => &self.no_tools,
        };
        if (slot.*) return false;
        slot.* = true;
        return true;
    }
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!Result {
    var run = RawRun{ .prompt_parts = &.{} };
    errdefer run.deinit(allocator);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var seen = Seen{};
    var i: usize = 0;
    var flags_open = true;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (flags_open and std.mem.eql(u8, arg, "--")) {
            flags_open = false;
            continue;
        }
        if (flags_open and std.mem.startsWith(u8, arg, "-")) {
            const flag = spec.findFlag(arg) orelse return .{ .err = .{ .unknown_flag = arg } };
            if (!seen.mark(flag.id)) return .{ .err = .{ .duplicate_flag = flag.id } };
            switch (flag.value_kind) {
                .none => switch (flag.id) {
                    .help => run = run,
                    .version => run = run,
                    .print => run.print = true,
                    .no_tools => run.no_tools = true,
                    .mode, .model => unreachable,
                },
                .required => {
                    i += 1;
                    if (i >= args.len) return .{ .err = .{ .missing_value = flag.id } };
                    switch (flag.id) {
                        .mode => run.mode = args[i],
                        .model => run.model = args[i],
                        else => unreachable,
                    }
                },
            }
            continue;
        }
        try parts.append(allocator, arg);
    }
    if (seen.help) return .{ .ok = .help };
    if (seen.version) return .{ .ok = .version };
    run.prompt_parts = try parts.toOwnedSlice(allocator);
    return .{ .ok = .{ .run = run } };
}

test "parse maps print prompt" {
    var result = try parse(std.testing.allocator, &.{ "-p", "hello" });
    defer if (result == .ok) result.ok.deinit(std.testing.allocator);
    try std.testing.expect(result.ok == .run);
    try std.testing.expect(result.ok.run.print);
    try std.testing.expectEqualStrings("hello", result.ok.run.prompt_parts[0]);
}

test "parse rejects unknown flag" {
    const result = try parse(std.testing.allocator, &.{"--wat"});
    try std.testing.expect(result.err == .unknown_flag);
}
