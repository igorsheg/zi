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
        .too_many_list_models_positionals => try writer.writeAll(
            "error: --list-models accepts at most one optional search term\n",
        ),
        .prompt_required_for_batch => try writer.writeAll(
            "error: batch mode requires a prompt source. use `zi -p \"prompt\"`, `zi -p @file`, `zi --mode json \"prompt\"`, or `cat file | zi -p`\n",
        ),
        .file_inputs_require_batch => try writer.writeAll(
            "error: @file arguments currently require explicit batch mode. use `zi -p [@file ...] [prompt]` or `zi --mode json [@file ...] [prompt]`\n",
        ),
        .prompt_not_allowed_for_session_target => |flag| try writer.print(
            "error: prompt cannot be combined with {s}. session targets start interactively without an initial prompt\n",
            .{flag},
        ),
        .session_target_requires_interactive => |flag| try writer.print(
            "error: {s} is interactive-only. remove -p/--print or --mode\n",
            .{flag},
        ),
        .conflicting_batch_selectors => try writer.writeAll(
            "error: choose either -p/--print or --mode, not both\n",
        ),
        .conflicting_session_selectors => |combo| try writer.print(
            "error: choose only one session target: {s} or {s}\n",
            .{ combo.first, combo.second },
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
        .session_lookup_failed => |err_name| try writer.print("error: could not inspect sessions: {s}\n", .{err_name}),
        .no_recent_session => try writer.writeAll(
            "error: no saved session found for this project. start one with `zi`, or use `zi --resume` to browse available sessions\n",
        ),
        .session_target_not_found => |ref| try writer.print("error: no session found matching '{s}'\n", .{ref}),
        .session_target_ambiguous => |ref| try writer.print(
            "error: session reference '{s}' matches multiple sessions. pass more of the id or a full path\n",
            .{ref},
        ),
        .model_resolution_failed => try writer.writeAll("error: model resolution failed\n"),
        .no_model_found => try writer.writeAll(
            "error: no model found. configure auth in interactive mode with /login, or set an API key env var.\nuse `zi --list-models` to see available models\n",
        ),
        .no_model_available => try writer.writeAll(
            "error: no model available — configure auth via /login or pass --api-key, then --model.\n",
        ),
        .batch_prompt_sources_resolved_empty => try writer.writeAll(
            "error: batch mode did not receive any non-empty prompt sources. empty @file inputs are ignored; provide piped stdin, a non-empty @file, or a prompt\n",
        ),
        .batch_file_not_found => |path| try writer.print("error: file not found: {s}\n", .{path}),
        .batch_file_read_failed => |info| try writer.print("error: could not read file {s}: {s}\n", .{ info.path, info.err_name }),
        .batch_assistant_failed => |message| try writer.print("error: {s}\n", .{message}),
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
    }
}

test "plan and execution diagnostics explain the finalized session-target contract" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writePlanDiagnostic(&out.writer, .prompt_required_for_batch);
    try writePlanDiagnostic(&out.writer, .file_inputs_require_batch);
    try writePlanDiagnostic(&out.writer, .{ .prompt_not_allowed_for_session_target = "--session" });
    try writePlanDiagnostic(&out.writer, .{ .session_target_requires_interactive = "--continue" });
    try writeExecutionDiagnostic(&out.writer, .no_recent_session);
    try writeExecutionDiagnostic(&out.writer, .batch_prompt_sources_resolved_empty);
    try writeExecutionDiagnostic(&out.writer, .{ .batch_assistant_failed = "Request aborted" });
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "piped stdin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zi -p @file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "@file arguments currently require explicit batch mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "empty @file inputs are ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--session") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--continue") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zi --resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Request aborted") != null);
}
