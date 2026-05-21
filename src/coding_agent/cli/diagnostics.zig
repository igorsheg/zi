const std = @import("std");
const parse_mod = @import("parse.zig");
const plan_mod = @import("plan.zig");
const result_mod = @import("result.zig");
const settings_resolve = @import("../../settings/resolve.zig");
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

pub fn writeResult(writer: anytype, diag: result_mod.Diagnostic) !void {
    switch (diag) {
        .submit_rejected => try writer.writeAll("run rejected\n"),
        .run_failed => try writer.writeAll("run failed\n"),
        .tui_unavailable => try writer.writeAll("TUI mode is not implemented yet; use -p or --json\n"),
        .missing_model => try writer.writeAll("missing model runtime\n"),
        .unknown_model => try writer.writeAll("unknown model\n"),
        .invalid_settings_model => |invalid| try writeInvalidSettingsModel(writer, invalid),
        .provider_unavailable => try writer.writeAll("provider runtime unavailable\n"),
        .missing_api_key => try writer.writeAll("missing OPENAI_API_KEY\n"),
    }
}

fn writeInvalidSettingsModel(writer: anytype, diag: settings_resolve.Diagnostic) !void {
    switch (diag) {
        .unknown_api => |field| try writer.print(
            "settings model {s} has unknown api: {s}\n",
            .{ field.model_id, field.value },
        ),
        .unknown_provider => |field| try writer.print(
            "settings model {s} has unknown provider: {s}\n",
            .{ field.model_id, field.value },
        ),
        .missing_base_url => |missing| try writer.print(
            "settings model {s} provider {s} requires baseUrl\n",
            .{ missing.model_id, missing.provider },
        ),
    }
}

fn flagName(id: spec.FlagId) []const u8 {
    for (spec.all_flags) |flag| if (flag.id == id) return flag.long;
    unreachable;
}
