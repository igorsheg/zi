const std = @import("std");
const parse = @import("parse.zig");

pub const OutputMode = parse.OutputMode;
pub const RawCommand = parse.RawCommand;
pub const RawRunArgs = parse.RawRunArgs;
pub const RawListModelsArgs = parse.RawListModelsArgs;

pub const SessionTarget = union(enum) {
    none,
    most_recent,
    picker,
    reference: []const u8,
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

pub const BatchPromptSources = struct {
    stdin_text: ?[]const u8 = null,
    file_args: []const []const u8 = &.{},
    prompt_text: ?[]const u8 = null,

    pub fn hasAny(self: BatchPromptSources) bool {
        return self.stdin_text != null or self.file_args.len > 0 or self.prompt_text != null;
    }
};

pub const BatchPlan = struct {
    output: OutputMode,
    prompt_sources: BatchPromptSources,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
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
    search: ?[]const u8 = null,
};

pub const BuildOptions = struct {
    piped_stdin: ?[]const u8 = null,
};

pub const PlanDiagnostic = union(enum) {
    too_many_positionals,
    too_many_list_models_positionals,
    prompt_required_for_batch,
    file_inputs_require_batch,
    prompt_not_allowed_for_session_target: []const u8,
    session_target_requires_interactive: []const u8,
    conflicting_batch_selectors,
    conflicting_session_selectors: struct {
        first: []const u8,
        second: []const u8,
    },
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

pub fn build(allocator: std.mem.Allocator, raw: RawCommand, options: BuildOptions) std.mem.Allocator.Error!PlanResult {
    return switch (raw) {
        .help => .{ .ok = .{ .help = .{} } },
        .version => .{ .ok = .{ .version = .{} } },
        .list_models => |list_models| buildListModels(list_models),
        .run => |run| try buildRun(allocator, run, options),
    };
}

fn buildListModels(raw: RawListModelsArgs) PlanResult {
    if (raw.positionals.len > 1) return .{ .err = .too_many_list_models_positionals };

    return .{ .ok = .{ .list_models = .{
        .search = if (raw.positionals.len == 1) raw.positionals[0] else null,
    } } };
}

fn buildRun(allocator: std.mem.Allocator, raw: RawRunArgs, options: BuildOptions) std.mem.Allocator.Error!PlanResult {
    if (raw.positionals.len > 1) return .{ .err = .too_many_positionals };
    if (raw.print_mode and raw.mode != null) return .{ .err = .conflicting_batch_selectors };

    const positional_prompt = if (raw.positionals.len == 1) raw.positionals[0] else null;
    const session_selection = switch (selectSessionTarget(raw)) {
        .ok => |selection| selection,
        .err => |diag| return .{ .err = diag },
    };
    const session_target = session_selection.target;
    const session_flag = session_selection.flag;
    const batch_selected = raw.print_mode or raw.mode != null;

    if (raw.no_session and session_flag != null) {
        return .{ .err = .{ .invalid_flag_combination = .{
            .first = session_flag.?,
            .second = "--no-session",
        } } };
    }

    if (batch_selected and session_flag != null) {
        return .{ .err = .{ .session_target_requires_interactive = session_flag.? } };
    }

    if (positional_prompt != null and session_flag != null) {
        return .{ .err = .{ .prompt_not_allowed_for_session_target = session_flag.? } };
    }

    if (raw.file_args.len > 0 and !batch_selected) {
        return .{ .err = .file_inputs_require_batch };
    }

    if (batch_selected) {
        const prompt_sources: BatchPromptSources = .{
            .stdin_text = options.piped_stdin,
            .file_args = try allocator.dupe([]const u8, raw.file_args),
            .prompt_text = positional_prompt,
        };
        if (!prompt_sources.hasAny()) return .{ .err = .prompt_required_for_batch };

        return .{ .ok = .{ .run = .{ .batch = .{
            .output = raw.mode orelse .text,
            .prompt_sources = prompt_sources,
            .api_key = raw.api_key,
            .model_id = raw.model_id,
            .no_session = raw.no_session,
            .tool_allowlist_csv = raw.tools_filter,
            .append_system_prompt = raw.append_system_prompt,
        } } } };
    }

    return .{ .ok = .{ .run = .{ .interactive = .{
        .initial_prompt = positional_prompt,
        .api_key = raw.api_key,
        .model_id = raw.model_id,
        .session_target = session_target,
        .no_session = raw.no_session,
        .tool_allowlist_csv = raw.tools_filter,
        .append_system_prompt = raw.append_system_prompt,
    } } } };
}

const SessionSelection = struct {
    target: SessionTarget,
    flag: ?[]const u8,
};

const SessionSelectionResult = union(enum) {
    ok: SessionSelection,
    err: PlanDiagnostic,
};

fn selectSessionTarget(raw: RawRunArgs) SessionSelectionResult {
    var target: SessionTarget = .none;
    var flag: ?[]const u8 = null;

    if (raw.continue_session) {
        target = .most_recent;
        flag = "--continue";
    }
    if (raw.resume_picker) {
        if (flag) |existing| {
            return .{ .err = .{ .conflicting_session_selectors = .{
                .first = existing,
                .second = "--resume",
            } } };
        }
        target = .picker;
        flag = "--resume";
    }
    if (raw.session_ref) |ref| {
        if (flag) |existing| {
            return .{ .err = .{ .conflicting_session_selectors = .{
                .first = existing,
                .second = "--session",
            } } };
        }
        target = .{ .reference = ref };
        flag = "--session";
    }

    return .{ .ok = .{ .target = target, .flag = flag } };
}

test "default run plan is interactive without initial prompt or session target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try build(arena.allocator(), .{ .run = .{} }, .{});
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

test "planner builds explicit interactive and batch plans from the chosen selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const continue_result = try build(arena.allocator(), .{ .run = .{
        .continue_session = true,
    } }, .{});
    switch (continue_result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .interactive => |interactive| try std.testing.expect(interactive.session_target == .most_recent),
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const session_result = try build(arena.allocator(), .{ .run = .{
        .session_ref = "session-1234",
    } }, .{});
    switch (session_result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .interactive => |interactive| switch (interactive.session_target) {
                    .reference => |ref| try std.testing.expectEqualStrings("session-1234", ref),
                    else => return error.UnexpectedPlan,
                },
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const batch_result = try build(arena.allocator(), .{ .run = .{
        .mode = .json,
        .positionals = &.{"hello"},
    } }, .{});
    switch (batch_result) {
        .ok => |plan| switch (plan) {
            .run => |run| switch (run) {
                .batch => |batch| {
                    try std.testing.expectEqual(OutputMode.json, batch.output);
                    try std.testing.expectEqualStrings("hello", batch.prompt_sources.prompt_text.?);
                    try std.testing.expect(batch.prompt_sources.stdin_text == null);
                    try std.testing.expectEqual(@as(usize, 0), batch.prompt_sources.file_args.len);
                },
                else => return error.UnexpectedPlan,
            },
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "list-models plan carries optional search and rejects extra positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const default_result = try build(arena.allocator(), .{ .list_models = .{} }, .{});
    switch (default_result) {
        .ok => |plan| switch (plan) {
            .list_models => |list_models| try std.testing.expect(list_models.search == null),
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const search_result = try build(arena.allocator(), .{ .list_models = .{ .positionals = &.{"claude"} } }, .{});
    switch (search_result) {
        .ok => |plan| switch (plan) {
            .list_models => |list_models| try std.testing.expectEqualStrings("claude", list_models.search.?),
            else => return error.UnexpectedPlan,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const too_many = try build(arena.allocator(), .{ .list_models = .{ .positionals = &.{ "claude", "sonnet" } } }, .{});
    switch (too_many) {
        .err => |diag| switch (diag) {
            .too_many_list_models_positionals => {},
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

test "planner rejects conflicting session selectors and batch-only file inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const conflicting_selectors = try build(arena.allocator(), .{ .run = .{
        .continue_session = true,
        .resume_picker = true,
    } }, .{});
    switch (conflicting_selectors) {
        .err => |diag| switch (diag) {
            .conflicting_session_selectors => |combo| {
                try std.testing.expectEqualStrings("--continue", combo.first);
                try std.testing.expectEqualStrings("--resume", combo.second);
            },
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }

    const prompt_and_target = try build(arena.allocator(), .{ .run = .{
        .session_ref = "session-1234",
        .positionals = &.{"hello"},
    } }, .{});
    switch (prompt_and_target) {
        .err => |diag| switch (diag) {
            .prompt_not_allowed_for_session_target => |flag| try std.testing.expectEqualStrings("--session", flag),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }

    const file_args_in_interactive = try build(arena.allocator(), .{ .run = .{
        .file_args = &.{"docs/README.md"},
    } }, .{});
    switch (file_args_in_interactive) {
        .err => |diag| switch (diag) {
            .file_inputs_require_batch => {},
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }

    const batch_and_target = try build(arena.allocator(), .{ .run = .{
        .print_mode = true,
        .continue_session = true,
    } }, .{});
    switch (batch_and_target) {
        .err => |diag| switch (diag) {
            .session_target_requires_interactive => |flag| try std.testing.expectEqualStrings("--continue", flag),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}
