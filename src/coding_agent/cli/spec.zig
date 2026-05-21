const std = @import("std");

pub const FlagId = enum { help, version, print, json, mode, model, no_tools };
pub const ValueKind = enum { none, required };

pub const FlagSpec = struct {
    id: FlagId,
    long: []const u8,
    short: ?u8 = null,
    value_kind: ValueKind = .none,
    value_name: []const u8 = "",
    description: []const u8,

    pub fn matches(self: FlagSpec, arg: []const u8) bool {
        if (arg.len == self.long.len + 2 and std.mem.eql(u8, arg[0..2], "--") and std.mem.eql(u8, arg[2..], self.long)) return true;
        if (self.short) |short| return arg.len == 2 and arg[0] == '-' and arg[1] == short;
        return false;
    }
};

pub const all_flags = [_]FlagSpec{
    .{ .id = .help, .long = "help", .short = 'h', .description = "Show help" },
    .{ .id = .version, .long = "version", .description = "Show version" },
    .{ .id = .print, .long = "print", .short = 'p', .description = "Print final assistant text only" },
    .{ .id = .json, .long = "json", .description = "Emit JSONL events" },
    .{ .id = .mode, .long = "mode", .value_kind = .required, .value_name = "<json>", .description = "Legacy output mode alias" },
    .{ .id = .model, .long = "model", .value_kind = .required, .value_name = "<id>", .description = "Model id" },
    .{ .id = .no_tools, .long = "no-tools", .description = "Disable builtin tools" },
};

pub fn findFlag(arg: []const u8) ?FlagSpec {
    for (all_flags) |flag| if (flag.matches(arg)) return flag;
    return null;
}
