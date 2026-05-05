const std = @import("std");
const app_meta = @import("../../runtime/app.zig");
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

fn parseAndPlan(allocator: std.mem.Allocator, argv: []const []const u8, piped_stdin: ?[]const u8) !CliOutcome {
    const detected = action.Action.detect(argv);
    var raw_command = switch (try parse.parse(allocator, detected, argv)) {
        .ok => |command| command,
        .err => |diag| return .{ .parse_diag = diag },
    };
    defer raw_command.deinit(allocator);

    return switch (try plan.build(allocator, raw_command, .{ .piped_stdin = piped_stdin })) {
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

fn expectInteractiveOutcome(outcome: CliOutcome) !plan.InteractivePlan {
    return switch (outcome) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .interactive => |interactive| interactive,
                else => error.ExpectedInteractivePlan,
            },
            else => error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => error.UnexpectedDiagnostic,
    };
}

fn expectBatchOutcome(outcome: CliOutcome) !plan.BatchPlan {
    return switch (outcome) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .batch => |batch| batch,
                else => error.ExpectedBatchPlan,
            },
            else => error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => error.UnexpectedDiagnostic,
    };
}

fn expectPlanDiagnosticOutcome(outcome: CliOutcome) !plan.PlanDiagnostic {
    return switch (outcome) {
        .plan_diag => |diag| diag,
        .ok, .parse_diag => error.ExpectedDiagnostic,
    };
}

test "cli run contract defaults to interactive and keeps a lone prompt interactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const default_plan = try expectInteractiveOutcome(try parseAndPlan(arena.allocator(), &.{}, null));
    try std.testing.expect(default_plan.prompt_sources.prompt_text == null);
    try std.testing.expectEqual(@as(usize, 0), default_plan.prompt_sources.file_args.len);
    try std.testing.expect(default_plan.session_target == .none);

    const prompt_plan = try expectInteractiveOutcome(try parseAndPlan(arena.allocator(), &.{"hello"}, null));
    try std.testing.expectEqualStrings("hello", prompt_plan.prompt_sources.prompt_text.?);
}

test "cli batch contract requires explicit selectors for text and json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const text_batch = try expectBatchOutcome(try parseAndPlan(arena.allocator(), &.{ "-p", "hello" }, null));
    try std.testing.expectEqual(parse.OutputMode.text, text_batch.output);
    try std.testing.expectEqualStrings("hello", text_batch.prompt_sources.prompt_text.?);
    try std.testing.expect(text_batch.prompt_sources.stdin_text == null);
    try std.testing.expectEqual(@as(usize, 0), text_batch.prompt_sources.file_args.len);

    const json_batch = try expectBatchOutcome(try parseAndPlan(arena.allocator(), &.{ "--mode", "json", "hello" }, null));
    try std.testing.expectEqual(parse.OutputMode.json, json_batch.output);
    try std.testing.expectEqualStrings("hello", json_batch.prompt_sources.prompt_text.?);
    try std.testing.expect(json_batch.prompt_sources.stdin_text == null);
    try std.testing.expectEqual(@as(usize, 0), json_batch.prompt_sources.file_args.len);
}

test "cli prompt source planning keeps stdin batch-only and allows interactive @file startup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const stdin_only_batch = try parseAndPlan(arena.allocator(), &.{"-p"}, "from stdin");
    switch (stdin_only_batch) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .batch => |batch| {
                    try std.testing.expectEqualStrings("from stdin", batch.prompt_sources.stdin_text.?);
                    try std.testing.expect(batch.prompt_sources.prompt_text == null);
                    try std.testing.expectEqual(@as(usize, 0), batch.prompt_sources.file_args.len);
                },
                else => return error.ExpectedBatchPlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    const no_prompt_source = try parseAndPlan(arena.allocator(), &.{"-p"}, null);
    switch (no_prompt_source) {
        .plan_diag => |diag| switch (diag) {
            .prompt_required_for_batch => {},
            else => return error.ExpectedDiagnostic,
        },
        .ok, .parse_diag => return error.ExpectedDiagnostic,
    }

    const merged_batch = try parseAndPlan(arena.allocator(), &.{ "--mode", "json", "@README.md", "hello" }, "from stdin\n");
    switch (merged_batch) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .batch => |batch| {
                    try std.testing.expectEqualStrings("from stdin\n", batch.prompt_sources.stdin_text.?);
                    try std.testing.expectEqualStrings("hello", batch.prompt_sources.prompt_text.?);
                    try std.testing.expectEqual(@as(usize, 1), batch.prompt_sources.file_args.len);
                    try std.testing.expectEqualStrings("README.md", batch.prompt_sources.file_args[0]);
                },
                else => return error.ExpectedBatchPlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    const interactive_file_result = try parseAndPlan(arena.allocator(), &.{"@README.md"}, null);
    switch (interactive_file_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .interactive => |interactive| {
                    try std.testing.expect(interactive.prompt_sources.prompt_text == null);
                    try std.testing.expectEqual(@as(usize, 1), interactive.prompt_sources.file_args.len);
                    try std.testing.expectEqualStrings("README.md", interactive.prompt_sources.file_args[0]);
                },
                else => return error.ExpectedInteractivePlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }

    const interactive_result = try parseAndPlan(arena.allocator(), &.{"hello"}, "from stdin");
    switch (interactive_result) {
        .ok => |execution_plan| switch (execution_plan) {
            .run => |run_plan| switch (run_plan) {
                .interactive => |interactive| try std.testing.expectEqualStrings("hello", interactive.prompt_sources.prompt_text.?),
                else => return error.ExpectedInteractivePlan,
            },
            else => return error.ExpectedRunPlan,
        },
        .parse_diag, .plan_diag => return error.UnexpectedDiagnostic,
    }
}

test "cli rejects invalid session-target combinations with actionable diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompt_and_continue = try parseAndPlan(arena.allocator(), &.{ "--continue", "hello" }, null);
    switch (prompt_and_continue) {
        .plan_diag => |diag| {
            const rendered = try renderPlanDiagnostic(diag);
            defer std.testing.allocator.free(rendered);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "startup prompt inputs cannot be combined with --continue") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "without an initial prompt") != null);
        },
        .ok, .parse_diag => return error.ExpectedDiagnostic,
    }

    const batch_and_continue = try parseAndPlan(arena.allocator(), &.{ "-p", "--continue" }, null);
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

    const list_models_result = try parseAndPlan(arena.allocator(), &.{ "--list-models", "claude" }, null);
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
