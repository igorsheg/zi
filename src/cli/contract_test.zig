const std = @import("std");
const app_meta = @import("../app_meta.zig");
const action = @import("action.zig");
const diagnostics = @import("diagnostics.zig");
const help = @import("help.zig");
const parse = @import("parse.zig");
const plan = @import("plan.zig");

const CliOutcome = union(enum) {
    ok: plan.ExecutionPlan,
    parse_diag: parse.ParseDiagnostic,
    plan_diag: plan.PlanDiagnostic,
};

fn parseAndPlan(allocator: std.mem.Allocator, argv: []const []const u8) !CliOutcome {
    const detected = action.Action.detect(argv);
    var raw_command = switch (try parse.parse(allocator, detected, argv)) {
        .ok => |command| command,
        .err => |diag| return .{ .parse_diag = diag },
    };
    defer raw_command.deinit(allocator);

    return switch (plan.build(raw_command)) {
        .ok => |execution_plan| .{ .ok = execution_plan },
        .err => |diag| .{ .plan_diag = diag },
    };
}

fn renderPlanDiagnostic(diagnostic: plan.PlanDiagnostic) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diagnostics.writePlanDiagnostic(&out.writer, diagnostic);
    return out.toOwnedSlice();
}

test "cli run contract defaults to interactive and keeps a lone prompt interactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const default_result = try parseAndPlan(arena.allocator(), &.{});
    switch (default_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .interactive => |interactive| {
                    try std.testing.expect(interactive.initial_prompt == null);
                    try std.testing.expect(interactive.session_target == .none);
                },
                else => return error.ExpectedInteractivePlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    const prompt_result = try parseAndPlan(arena.allocator(), &.{"hello"});
    switch (prompt_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .interactive => |interactive| try std.testing.expectEqualStrings("hello", interactive.initial_prompt.?),
                else => return error.ExpectedInteractivePlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }
}

test "cli batch contract requires explicit selectors for text and json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const text_result = try parseAndPlan(arena.allocator(), &.{ "-p", "hello" });
    switch (text_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .batch => |batch| {
                    try std.testing.expectEqual(parse.OutputMode.text, batch.output);
                    try std.testing.expectEqualStrings("hello", batch.prompt);
                },
                else => return error.ExpectedBatchPlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    const json_result = try parseAndPlan(arena.allocator(), &.{ "--mode", "json", "hello" });
    switch (json_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .batch => |batch| {
                    try std.testing.expectEqual(parse.OutputMode.json, batch.output);
                    try std.testing.expectEqualStrings("hello", batch.prompt);
                },
                else => return error.ExpectedBatchPlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }
}

test "cli rejects invalid session-target combinations with actionable diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompt_and_continue = try parseAndPlan(arena.allocator(), &.{ "--continue", "hello" });
    switch (prompt_and_continue) {
        .plan_diag => |diag| {
            const rendered = try renderPlanDiagnostic(diag);
            defer std.testing.allocator.free(rendered);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "prompt cannot be combined with --continue") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "without an initial prompt") != null);
        },
        .ok, .parse_diag => return error.ExpectedDiagnostic,
    }

    const batch_and_continue = try parseAndPlan(arena.allocator(), &.{ "-p", "--continue" });
    switch (batch_and_continue) {
        .plan_diag => |diag| {
            const rendered = try renderPlanDiagnostic(diag);
            defer std.testing.allocator.free(rendered);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "--continue is interactive-only") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "remove -p/--print or --mode") != null);
        },
        .ok, .parse_diag => return error.ExpectedDiagnostic,
    }
}

test "cli utility surfaces stay truthful for help version and list-models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list_models_result = try parseAndPlan(arena.allocator(), &.{ "--list-models", "claude" });
    switch (list_models_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .list_models => |list_models| try std.testing.expectEqualStrings("claude", list_models.search.?),
            else => return error.ExpectedListModelsPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    var help_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help_out.deinit();
    try help.writeGeneralHelp(&help_out.writer);
    const rendered_help = try help_out.toOwnedSlice();
    defer std.testing.allocator.free(rendered_help);
    try std.testing.expect(std.mem.indexOf(u8, rendered_help, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_help, "List available models") != null);

    var version_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer version_out.deinit();
    try help.writeVersion(&version_out.writer);
    const rendered_version = try version_out.toOwnedSlice();
    defer std.testing.allocator.free(rendered_version);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} {s}\n", .{ app_meta.name, app_meta.version });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, rendered_version);
}
