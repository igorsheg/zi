//! Compaction executor.
//!
//! Orchestration / glue layer. Pure domain logic (cut-point selection,
//! split-turn detection, file-op extraction, summarization-input
//! serialization) lives in `compaction_prep.zig`. This file only:
//!  - fans out to the pure prep module
//!  - performs the LLM completion(s) needed to produce summaries
//!  - composes the final summary (history + split-turn prefix + file-ops)
//!  - mutates the session store via applyCompaction and refreshes agent context
//!
//! Keep it thin — pi-mono's `compact()` in compaction.ts is the reference.

const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../root.zig");
const prep = @import("compaction_prep.zig");
const hooks_mod = @import("compaction_hooks.zig");
const session_runner = @import("../session_runner.zig");

const AgentSession = coding_agent.AgentSession;
const CompactionPolicy = session_runner.CompactionPolicy;
const CompactionReason = session_runner.CompactionReason;
const CompactionExecutor = session_runner.CompactionExecutor;
const CompactionResult = session_runner.CompactionResult;
const CompactionRunContext = session_runner.CompactionRunContext;

const summarization_system_prompt =
    "You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.\n\n" ++
    "Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.";

const initial_summarization_prompt =
    "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.\n\n" ++
    "Use this EXACT format:\n\n" ++
    "## Goal\n" ++
    "[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n" ++
    "## Constraints & Preferences\n" ++
    "- [Any constraints, preferences, or requirements mentioned by user]\n" ++
    "- [Or \"(none)\" if none were mentioned]\n\n" ++
    "## Progress\n" ++
    "### Done\n" ++
    "- [x] [Completed tasks/changes]\n\n" ++
    "### In Progress\n" ++
    "- [ ] [Current work]\n\n" ++
    "### Blocked\n" ++
    "- [Issues preventing progress, if any]\n\n" ++
    "## Key Decisions\n" ++
    "- **[Decision]**: [Brief rationale]\n\n" ++
    "## Next Steps\n" ++
    "1. [Ordered list of what should happen next]\n\n" ++
    "## Critical Context\n" ++
    "- [Any data, examples, or references needed to continue]\n" ++
    "- [Or \"(none)\" if not applicable]\n\n" ++
    "Keep each section concise. Preserve exact file paths, function names, and error messages.";

const update_summarization_prompt =
    "The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.\n\n" ++
    "Update the existing structured summary with new information. RULES:\n" ++
    "- PRESERVE all existing information from the previous summary\n" ++
    "- ADD new progress, decisions, and context from the new messages\n" ++
    "- UPDATE the Progress section: move items from \"In Progress\" to \"Done\" when completed\n" ++
    "- UPDATE \"Next Steps\" based on what was accomplished\n" ++
    "- PRESERVE exact file paths, function names, and error messages\n" ++
    "- If something is no longer relevant, you may remove it\n\n" ++
    "Use this EXACT format:\n\n" ++
    "## Goal\n" ++
    "[Preserve existing goals, add new ones if the task expanded]\n\n" ++
    "## Constraints & Preferences\n" ++
    "- [Preserve existing, add new ones discovered]\n\n" ++
    "## Progress\n" ++
    "### Done\n" ++
    "- [x] [Include previously done items AND newly completed items]\n\n" ++
    "### In Progress\n" ++
    "- [ ] [Current work - update based on progress]\n\n" ++
    "### Blocked\n" ++
    "- [Current blockers - remove if resolved]\n\n" ++
    "## Key Decisions\n" ++
    "- **[Decision]**: [Brief rationale] (preserve all previous, add new)\n\n" ++
    "## Next Steps\n" ++
    "1. [Update based on current state]\n\n" ++
    "## Critical Context\n" ++
    "- [Preserve important context, add new if needed]\n\n" ++
    "Keep each section concise. Preserve exact file paths, function names, and error messages.";

const turn_prefix_summarization_prompt =
    "This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.\n\n" ++
    "Summarize the prefix to provide context for the retained suffix:\n\n" ++
    "## Original Request\n" ++
    "[What did the user ask for in this turn?]\n\n" ++
    "## Early Progress\n" ++
    "- [Key decisions and work done in the prefix]\n\n" ++
    "## Context for Suffix\n" ++
    "- [Information needed to understand the retained recent work]\n\n" ++
    "Be concise. Focus on what's needed to understand the kept suffix.";

pub fn createExecutor() CompactionExecutor {
    return .{ .func = &execute };
}

fn execute(
    session: *AgentSession,
    reason: CompactionReason,
    policy: CompactionPolicy,
    run_ctx: CompactionRunContext,
    ctx: ?*anyopaque,
) anyerror!CompactionResult {
    _ = ctx;

    var arena = std.heap.ArenaAllocator.init(session.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try session.session_store.buildCurrentBranchAlloc(allocator);
    if (path.len == 0) return error.NothingToCompact;

    const settings: prep.CompactionSettings = .{
        .enabled = policy.enabled,
        .reserve_tokens = policy.reserve_tokens,
        .keep_recent_tokens = policy.keep_recent_tokens,
    };

    const preparation = (try prep.prepareCompaction(allocator, path, settings)) orelse return error.NothingToCompact;

    const hook_reason: hooks_mod.BeforeCompactPayload.Reason = switch (reason) {
        .manual => .manual,
        .threshold => .threshold,
        .overflow => .overflow,
    };

    var from_hook = false;
    var composed_summary: []const u8 = "";
    var first_kept_id_source: []const u8 = preparation.first_kept_entry_id;
    var tokens_before_value: u64 = preparation.tokens_before;
    var details_from_hook: ?std.json.Value = null;

    const before_outcome: hooks_mod.BeforeCompactOutcome = if (session.compaction_hooks.before_compact) |cb|
        cb(.{ .reason = hook_reason, .preparation = &preparation }, session.compaction_hooks.ctx)
    else
        .proceed;

    switch (before_outcome) {
        .cancel => return error.CompactionCancelled,
        .provide => |provided| {
            if (!entryIdExists(path, provided.first_kept_entry_id)) return error.InvalidCompactionFirstKeptEntry;
            from_hook = true;
            composed_summary = provided.summary;
            first_kept_id_source = provided.first_kept_entry_id;
            tokens_before_value = provided.tokens_before;
            details_from_hook = provided.details;
        },
        .proceed => {
            const history_summary = if (preparation.is_split_turn and
                preparation.turn_prefix_messages.len > 0 and
                preparation.messages_to_summarize.len == 0)
                try allocator.dupe(u8, "No prior history.")
            else
                try generateHistorySummary(
                    session,
                    allocator,
                    preparation.messages_to_summarize,
                    preparation.previous_summary,
                    policy,
                    run_ctx.custom_instructions,
                );

            if (preparation.is_split_turn and preparation.turn_prefix_messages.len > 0) {
                const turn_prefix_summary = try generateTurnPrefixSummary(
                    session,
                    allocator,
                    preparation.turn_prefix_messages,
                    policy,
                );
                composed_summary = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\n---\n\n**Turn Context (split turn):**\n\n{s}",
                    .{ history_summary, turn_prefix_summary },
                );
            } else {
                composed_summary = history_summary;
            }
        },
    }

    const file_lists = try prep.computeFileLists(allocator, &preparation.file_ops);
    const file_ops_suffix = if (from_hook)
        try allocator.dupe(u8, "")
    else
        try prep.formatFileOperations(allocator, file_lists.read_files, file_lists.modified_files);

    const summary_owned = try std.fmt.allocPrint(session.allocator, "{s}{s}", .{ composed_summary, file_ops_suffix });
    const first_kept_id_owned = try session.allocator.dupe(u8, first_kept_id_source);
    const details_value: std.json.Value = if (from_hook)
        if (details_from_hook) |d| try ai.json_util.cloneJsonValue(session.allocator, d) else .null
    else
        try buildDetailsJson(session.allocator, file_lists);
    const details_arg: ?std.json.Value = if (details_value == .null) null else details_value;

    const new_context = try session.session_store.applyCompaction(
        summary_owned,
        first_kept_id_owned,
        tokens_before_value,
        details_arg,
        from_hook,
    );
    try session.agent.setMessages(new_context.messages);
    session.noteCompactionApplied();
    session.agent.clearError();

    if (session.compaction_hooks.after_compact) |cb| {
        cb(.{ .reason = hook_reason, .entry = .{
            .summary = summary_owned,
            .first_kept_entry_id = first_kept_id_owned,
            .tokens_before = tokens_before_value,
            .details = details_arg,
            .from_hook = from_hook,
        } }, session.compaction_hooks.ctx);
    }

    return .{
        .summary = summary_owned,
        .first_kept_entry_id = first_kept_id_owned,
        .tokens_before = tokens_before_value,
        .details = details_arg,
        .from_hook = from_hook,
    };
}

test "compactor prepares from current branch including entries appended after cache" {
    const testing = std.testing;
    const sdk = @import("../sdk.zig");
    const faux = @import("../../ai/faux.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fs.path.resolve(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "workspace" });
    const agent_dir = try std.fs.path.resolve(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cwd);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, agent_dir);

    var session = try sdk.createAgentSession(allocator, .{
        .model = faux.fauxModel(),
        .api_key = "test-key",
        .cwd = cwd,
        .agent_dir_override = agent_dir,
        .tools = &.{},
        .no_session = false,
    });
    defer session.deinit();

    _ = session.session_store.appendMessage(.{ .user = .{ .content = .{ .text = "old user" }, .timestamp = 1 } }) orelse return error.TestUnexpectedResult;
    const old_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("old answer")};
    _ = session.session_store.appendMessage(.{ .assistant = faux.fauxAssistantMessage(allocator, &old_content, .stop) }) orelse return error.TestUnexpectedResult;

    // Populate the session store cache, then append more flushed entries. This
    // recreates the resumed-session shape where readEntries() alone is stale and
    // buildCurrentBranchAlloc() must merge writer.appended_entries.
    _ = try session.session_store.readEntries();

    _ = session.session_store.appendMessage(.{ .user = .{ .content = .{ .text = "new user" }, .timestamp = 3 } }) orelse return error.TestUnexpectedResult;
    const new_content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{faux.fauxText("new answer")};
    const expected_first_kept = session.session_store.appendMessage(.{ .assistant = faux.fauxAssistantMessage(allocator, &new_content, .stop) }) orelse return error.TestUnexpectedResult;

    const Hook = struct {
        allocator: std.mem.Allocator,
        seen_first_kept: ?[]const u8 = null,

        fn before(payload: hooks_mod.BeforeCompactPayload, ctx: ?*anyopaque) hooks_mod.BeforeCompactOutcome {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.seen_first_kept = self.allocator.dupe(u8, payload.preparation.first_kept_entry_id) catch return .cancel;
            return .{ .provide = .{
                .summary = "hook summary",
                .first_kept_entry_id = payload.preparation.first_kept_entry_id,
                .tokens_before = payload.preparation.tokens_before,
            } };
        }
    };
    var hook = Hook{ .allocator = allocator };
    session.setCompactionHooks(.{ .ctx = &hook, .before_compact = Hook.before });

    const executor = createExecutor();
    const result = try executor.func(&session, .threshold, .{ .enabled = true, .reserve_tokens = 1, .keep_recent_tokens = 1 }, .{}, executor.ctx);

    try testing.expectEqualStrings(expected_first_kept, hook.seen_first_kept.?);
    try testing.expectEqualStrings(expected_first_kept, result.first_kept_entry_id);
    try testing.expect(result.from_hook.?);
}

fn entryIdExists(entries: []const @import("../../session/protocol.zig").SessionEntry, id: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

/// Build the persisted `details` JSON object — pi-mono shape
/// `{ "readFiles": string[], "modifiedFiles": string[] }`. Allocates from the
/// session's long-lived allocator so the value outlives any executor-local arena.
fn buildDetailsJson(
    allocator: std.mem.Allocator,
    file_lists: prep.ComputedFileLists,
) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    errdefer obj.deinit(allocator);

    var read_arr: std.json.Array = .init(allocator);
    errdefer read_arr.deinit();
    for (file_lists.read_files) |f| {
        try read_arr.append(.{ .string = try allocator.dupe(u8, f) });
    }

    var mod_arr: std.json.Array = .init(allocator);
    errdefer mod_arr.deinit();
    for (file_lists.modified_files) |f| {
        try mod_arr.append(.{ .string = try allocator.dupe(u8, f) });
    }

    try obj.put(allocator, try allocator.dupe(u8, "readFiles"), .{ .array = read_arr });
    try obj.put(allocator, try allocator.dupe(u8, "modifiedFiles"), .{ .array = mod_arr });
    return .{ .object = obj };
}

fn generateHistorySummary(
    session: *AgentSession,
    allocator: std.mem.Allocator,
    messages: []const agent.protocol.AgentMessage,
    previous_summary: ?[]const u8,
    policy: CompactionPolicy,
    custom_instructions: ?[]const u8,
) ![]const u8 {
    if (messages.len == 0 and previous_summary != null) {
        return try allocator.dupe(u8, previous_summary.?);
    }
    if (messages.len == 0) return try allocator.dupe(u8, "No prior history.");

    const conversation = try prep.serializeConversation(allocator, messages);
    const template = if (previous_summary != null) update_summarization_prompt else initial_summarization_prompt;
    const base = if (custom_instructions) |ci| try std.fmt.allocPrint(
        allocator,
        "{s}\n\nAdditional focus: {s}",
        .{ template, ci },
    ) else template;

    const prompt_text = if (previous_summary) |prev| try std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n<previous-summary>\n{s}\n</previous-summary>\n\n{s}",
        .{ conversation, prev, base },
    ) else try std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ conversation, base },
    );

    const max_tokens: u32 = @intCast(@max(@divTrunc(policy.reserve_tokens * 4, 5), 1024));
    return try session.completeUserText(allocator, summarization_system_prompt, prompt_text, max_tokens);
}

fn generateTurnPrefixSummary(
    session: *AgentSession,
    allocator: std.mem.Allocator,
    messages: []const agent.protocol.AgentMessage,
    policy: CompactionPolicy,
) ![]const u8 {
    const conversation = try prep.serializeConversation(allocator, messages);
    const prompt_text = try std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ conversation, turn_prefix_summarization_prompt },
    );
    const max_tokens: u32 = @intCast(@max(@divTrunc(policy.reserve_tokens, 2), 512));
    return try session.completeUserText(allocator, summarization_system_prompt, prompt_text, max_tokens);
}
