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
        .too_many_positionals => try writer.writeAll("error: run accepts at most one prompt positional\n"),
        .prompt_required_for_batch => try writer.writeAll(
            "error: batch mode requires a prompt. use `zi -p \"prompt\"` or `zi --mode json \"prompt\"`\n",
        ),
        .prompt_not_allowed_for_this_session_target => try writer.writeAll(
            "error: prompt cannot be combined with --continue. use `zi --continue <path>` to resume interactively\n",
        ),
        .conflicting_batch_selectors => try writer.writeAll(
            "error: choose either -p/--print or --mode, not both\n",
        ),
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
            "error: no model found. configure auth in interactive mode with /login, or set an API key env var.\nuse `zi --list-models` to see models with configured auth\n",
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
            "error: the resumed session already ends with an assistant message. open it with `zi --continue <path>` and send a follow-up prompt interactively.\n",
        ),
        .continue_session_failed => |err_name| try writer.print("error: could not continue session: {s}\n", .{err_name}),
    }
}

test "plan diagnostics explain batch and resume semantics" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writePlanDiagnostic(&out.writer, .prompt_required_for_batch);
    try writePlanDiagnostic(&out.writer, .prompt_not_allowed_for_this_session_target);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "zi -p \"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zi --continue <path>") != null);
}
