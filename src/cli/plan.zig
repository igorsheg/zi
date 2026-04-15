const std = @import("std");
const parse = @import("parse.zig");

pub const OutputMode = parse.OutputMode;
pub const RawCommand = parse.RawCommand;
pub const RawRunArgs = parse.RawRunArgs;

pub const SessionTarget = union(enum) {
    none,
    continue_path: []const u8,
};

pub const RunPlan = union(enum) {
    interactive: InteractivePlan,
    batch: BatchPlan,
};

pub const InteractivePlan = struct {
    initial_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    session_target: SessionTarget = .none,
    no_session: bool = false,
    tool_allowlist_csv: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub const BatchPlan = struct {
    output: OutputMode,
    prompt: []const u8,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    session_target: SessionTarget = .none,
    no_session: bool = false,
    tool_allowlist_csv: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub const ExecutionPlan = union(enum) {
    help: HelpPlan,
    version: VersionPlan,
    list_models: ListModelsPlan,
    run: RunPlan,
};

pub const HelpPlan = struct {};
pub const VersionPlan = struct {};
pub const ListModelsPlan = struct {
    available_only: bool = true,
};

pub const PlanDiagnostic = union(enum) {
    too_many_positionals,
    prompt_required_for_batch,
    prompt_not_allowed_for_this_session_target,
    conflicting_batch_selectors,
    unsupported_flag_for_action: []const u8,
    invalid_flag_combination: struct {
        first: []const u8,
        second: []const u8,
    },
};

pub const PlanResult = union(enum) {
    ok: ExecutionPlan,
    err: PlanDiagnostic,
};

pub fn build(raw: RawCommand) PlanResult {
    return switch (raw) {
        .help => .{ .ok = .{ .help = .{} } },
        .version => .{ .ok = .{ .version = .{} } },
        .list_models => .{ .ok = .{ .list_models = .{} } },
        .run => |run| buildRun(run),
    };
}

fn buildRun(raw: RawRunArgs) PlanResult {
    if (raw.positionals.len > 1) return .{ .err = .too_many_positionals };
    if (raw.print_mode and raw.mode != null) return .{ .err = .conflicting_batch_selectors };

    const prompt = if (raw.positionals.len == 1) raw.positionals[0] else null;
    const session_target = if (raw.continue_path) |path|
        SessionTarget{ .continue_path = path }
    else
        SessionTarget.none;

    if (raw.no_session and session_target != .none) {
        return .{ .err = .{ .invalid_flag_combination = .{
            .first = "--continue",
            .second = "--no-session",
        } } };
    }

    if (prompt != null and session_target != .none) {
        return .{ .err = .prompt_not_allowed_for_this_session_target };
    }

    if (raw.print_mode or raw.mode != null) {
        return .{ .ok = .{ .run = .{ .batch = .{
            .output = raw.mode orelse .text,
            .prompt = prompt orelse return .{ .err = .prompt_required_for_batch },
            .api_key = raw.api_key,
            .model_id = raw.model_id,
            .session_target = session_target,
            .no_session = raw.no_session,
            .tool_allowlist_csv = raw.tools_filter,
            .append_system_prompt = raw.append_system_prompt,
        } } } };
    }

    return .{ .ok = .{ .run = .{ .interactive = .{
        .initial_prompt = prompt,
        .api_key = raw.api_key,
        .model_id = raw.model_id,
        .session_target = session_target,
        .no_session = raw.no_session,
        .tool_allowlist_csv = raw.tools_filter,
        .append_system_prompt = raw.append_system_prompt,
    } } } };
}

test "default run plan is interactive without initial prompt" {
    const result = build(.{ .run = .{} });
    switch (result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .interactive => |interactive| {
                    try std.testing.expect(interactive.initial_prompt == null);
                    try std.testing.expect(interactive.session_target == .none);
                },
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "explicit batch selectors produce batch text and batch json plans" {
    const print_result = build(.{ .run = .{
        .print_mode = true,
        .positionals = &.{"hello"},
    } });
    switch (print_result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .batch => |batch| {
                    try std.testing.expectEqual(OutputMode.text, batch.output);
                    try std.testing.expectEqualStrings("hello", batch.prompt);
                },
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const json_result = build(.{ .run = .{
        .mode = .json,
        .positionals = &.{"hello"},
    } });
    switch (json_result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .batch => |batch| {
                    try std.testing.expectEqual(OutputMode.json, batch.output);
                    try std.testing.expectEqualStrings("hello", batch.prompt);
                },
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "planner rejects prompt plus session target and bypasses run planning for list-models" {
    const invalid = build(.{ .run = .{
        .continue_path = "session.jsonl",
        .positionals = &.{"hello"},
    } });
    switch (invalid) {
        .err => |diag| try std.testing.expect(diag == .prompt_not_allowed_for_this_session_target),
        .ok => return error.ExpectedDiagnostic,
    }

    const list_models = build(.{ .list_models = .{} });
    switch (list_models) {
        .ok => |plan| switch (plan) {
            .list_models => |lm| try std.testing.expect(lm.available_only),
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}
