const std = @import("std");
const parse = @import("parse.zig");
const plan = @import("plan.zig");
const runtime = @import("runtime.zig");
const result = @import("result.zig");

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

pub fn writeRuntimeInitDiagnostic(writer: anytype, diagnostic: runtime.InitDiagnostic) !void {
    switch (diagnostic) {
        .auth_storage_init_failed => try writer.writeAll("error: could not load auth storage\n"),
        .settings_init_failed => try writer.writeAll("error: could not load settings\n"),
        .model_registry_init_failed => try writer.writeAll("error: could not build model registry\n"),
    }
}

pub fn writeExecutionDiagnostic(writer: anytype, diagnostic: result.ExecutionDiagnostic) !void {
    switch (diagnostic) {
        .resolver_message => |message| try writer.print("error: {s}\n", .{message}),
        .session_load_failed => |err_name| try writer.print("error: could not load session: {s}\n", .{err_name}),
        .session_file_has_no_messages => try writer.writeAll("error: session file has no messages\n"),
        .model_resolution_failed => try writer.writeAll("error: model resolution failed\n"),
        .no_model_found => try writer.writeAll(
            "error: no model found. configure auth or set an API key env var.\nuse --list-models to see available models\n",
        ),
        .no_model_available => try writer.writeAll(
            "error: no model available — configure auth via /login or pass --api-key, then --model.\n",
        ),
        .no_api_key_for_provider => |info| {
            try writer.print("error: no API key for provider '{s}'. use /login in interactive mode or set ", .{info.provider});
            if (info.env_hint) |env_hint| {
                try writer.writeAll(env_hint);
            } else if (std.mem.eql(u8, info.provider, "anthropic")) {
                try writer.writeAll("ANTHROPIC_API_KEY");
            } else {
                try writer.writeAll("the provider's API key env var");
            }
            try writer.writeAll("\n");
        },
        .continue_session_needs_prompt => try writer.writeAll(
            "session loaded but transcript ends with assistant. provide a prompt to continue.\n",
        ),
        .continue_session_failed => |err_name| try writer.print("error: could not continue session: {s}\n", .{err_name}),
    }
}
