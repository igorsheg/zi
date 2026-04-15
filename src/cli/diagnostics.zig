const parse = @import("parse.zig");
const plan = @import("plan.zig");

pub fn writeParseDiagnostic(writer: anytype, diagnostic: parse.ParseDiagnostic) !void {
    switch (diagnostic) {
        .missing_value => |flag| try writer.print("error: missing value for {s}\n", .{flag}),
        .invalid_mode => |value| try writer.print("error: unknown mode '{s}'. use 'json' or 'text'\n", .{value}),
        .unknown_flag => |flag| try writer.print("error: unknown flag '{s}'\n", .{flag}),
    }
}

pub fn writePlanDiagnostic(writer: anytype, diagnostic: plan.PlanDiagnostic) !void {
    switch (diagnostic) {
        .too_many_positionals => try writer.writeAll("error: too many positional arguments\n"),
        .prompt_required_for_batch => try writer.writeAll("error: prompt required for batch mode\n"),
        .prompt_not_allowed_for_this_session_target => try writer.writeAll("error: prompt is not allowed with the selected session target\n"),
        .conflicting_batch_selectors => try writer.writeAll("error: conflicting batch selectors\n"),
        .unsupported_flag_for_action => |flag| try writer.print("error: flag '{s}' is not supported for this action\n", .{flag}),
        .invalid_flag_combination => |combo| try writer.print(
            "error: invalid flag combination: {s} and {s}\n",
            .{ combo.first, combo.second },
        ),
    }
}
