const std = @import("std");
const parse_mod = @import("parse.zig");
const plan_mod = @import("plan.zig");
const spec = @import("spec.zig");

pub fn writeParse(writer: anytype, diag: parse_mod.Diagnostic) !void {
    switch (diag) {
        .unknown_flag => |flag| try writer.print("unknown flag: {s}\n", .{flag}),
        .missing_value => |flag| try writer.print("missing value for --{s}\n", .{flagName(flag)}),
        .duplicate_flag => |flag| try writer.print("duplicate flag: --{s}\n", .{flagName(flag)}),
    }
}

pub fn writePlan(writer: anytype, diag: plan_mod.Diagnostic) !void {
    switch (diag) {
        .missing_prompt => try writer.writeAll("missing prompt\n"),
        .invalid_mode => |mode| try writer.print("invalid mode: {s}\n", .{mode}),
        .conflicting_output_modes => try writer.writeAll("conflicting output modes\n"),
    }
}

fn flagName(id: spec.FlagId) []const u8 {
    for (spec.all_flags) |flag| if (flag.id == id) return flag.long;
    unreachable;
}
