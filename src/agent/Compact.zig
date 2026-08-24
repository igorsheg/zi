//! Pure compaction policy and text construction. This module does not run providers,
//! execute tools, retry requests, or mutate sessions.

const std = @import("std");
const ai = @import("../ai/root.zig");

const Item = ai.Item.Item;

pub const max_logical_attempts: usize = 4;
pub const max_instructions_bytes: usize = 64 * 1024;
pub const max_summary_bytes: usize = 64 * 1024;
pub const max_final_text_bytes: usize = 64 * 1024;

pub const checkpoint_prompt =
    "Summarize the conversation so far into a structured context checkpoint that lets the " ++
    "work continue without access to the full history above.\n" ++
    "\n" ++
    "CRITICAL: Respond with the summary text ONLY. Do not call any tools and do not continue " ++
    "the task — your entire reply is the summary.\n" ++
    "\n" ++
    "Use this exact Markdown structure, keeping every section even when empty:\n" ++
    "\n" ++
    "## Goal\n" ++
    "- [what the user is ultimately trying to accomplish]\n" ++
    "\n" ++
    "## Constraints & Preferences\n" ++
    "- [explicit user constraints, preferences, or requirements, or \"(none)\"]\n" ++
    "\n" ++
    "## Progress\n" ++
    "### Done\n" ++
    "- [completed work, or \"(none)\"]\n" ++
    "### In Progress\n" ++
    "- [work underway right now, or \"(none)\"]\n" ++
    "### Blocked\n" ++
    "- [blockers, or \"(none)\"]\n" ++
    "\n" ++
    "## Key Decisions\n" ++
    "- [decision: brief rationale, or \"(none)\"]\n" ++
    "\n" ++
    "## Files\n" ++
    "- [path: why it matters / what changed, or \"(none)\"]\n" ++
    "\n" ++
    "## Next Steps\n" ++
    "- [ordered next actions, or \"(none)\"]\n" ++
    "\n" ++
    "## Critical Context\n" ++
    "- [important technical facts, error strings, identifiers, commands, open questions, or " ++
    "\"(none)\"]\n" ++
    "\n" ++
    "Rules:\n" ++
    "- Be terse: bullets, not prose paragraphs.\n" ++
    "- Preserve exact file paths, function names, commands, and error strings.\n" ++
    "- Do not mention that a summary was produced or that context was compacted.";

pub const seed_preamble =
    "The earlier part of this conversation was condensed to free up context. The summary " ++
    "below captures everything that happened before this point — treat it as established " ++
    "context and continue the work from here.";

const focus_prefix = "\n\nAdditional focus for this summary:\n";
const seed_separator = "\n\n";

pub const BuildError = error{
    OutOfMemory,
    InstructionsTooLarge,
    SummaryTooLarge,
    FinalTextTooLarge,
};

/// Allocator-owned compaction text. Call `deinit` exactly once.
pub const OwnedText = struct {
    bytes: []u8,

    pub fn deinit(self: *OwnedText, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Applies hax's auto-compaction threshold policy without provider or session state.
pub fn shouldAuto(
    context_tokens: ?u64,
    context_limit: ?u64,
    enabled: bool,
    threshold: u8,
) bool {
    if (!enabled or threshold < 1 or threshold > 100) return false;
    const tokens = context_tokens orelse return false;
    const limit = context_limit orelse return false;
    if (limit == 0) return false;

    const quotient = limit / 100;
    const remainder = limit % 100;
    const scaled_remainder = remainder * threshold;
    const threshold_tokens = quotient * threshold +
        scaled_remainder / 100 + @intFromBool(scaled_remainder % 100 != 0);
    return tokens >= threshold_tokens;
}

/// Builds the exact structured checkpoint request. Instructions are borrowed.
/// Empty instructions do not add a focus section.
pub fn buildCheckpointPrompt(
    allocator: std.mem.Allocator,
    instructions: ?[]const u8,
) BuildError!OwnedText {
    const focus = instructions orelse "";
    if (focus.len > max_instructions_bytes) return error.InstructionsTooLarge;
    const extra_len = if (focus.len == 0) 0 else focus_prefix.len + focus.len;
    const final_len = checkpoint_prompt.len + extra_len;
    if (final_len > max_final_text_bytes) return error.FinalTextTooLarge;

    const bytes = try allocator.alloc(u8, final_len);
    @memcpy(bytes[0..checkpoint_prompt.len], checkpoint_prompt);
    if (focus.len != 0) {
        @memcpy(bytes[checkpoint_prompt.len..][0..focus_prefix.len], focus_prefix);
        @memcpy(bytes[checkpoint_prompt.len + focus_prefix.len ..], focus);
    }
    return .{ .bytes = bytes };
}

/// Builds the exact compact-seed user text. The summary is borrowed.
pub fn buildSeed(allocator: std.mem.Allocator, summary: []const u8) BuildError!OwnedText {
    if (summary.len > max_summary_bytes) return error.SummaryTooLarge;
    const final_len = seed_preamble.len + seed_separator.len + summary.len;
    if (final_len > max_final_text_bytes) return error.FinalTextTooLarge;

    const bytes = try allocator.alloc(u8, final_len);
    @memcpy(bytes[0..seed_preamble.len], seed_preamble);
    @memcpy(bytes[seed_preamble.len..][0..seed_separator.len], seed_separator);
    @memcpy(bytes[seed_preamble.len + seed_separator.len ..], summary);
    return .{ .bytes = bytes };
}

/// The terminal state is explicit so a partial or failed response cannot be selected.
pub const Terminal = enum {
    done,
    failed,
};

pub const Response = struct {
    terminal: Terminal,
    items: []const Item,
};

/// Borrows the last nonempty assistant message from a completed, tool-call-free response.
/// Reasoning and other response records are ignored. This helper never executes tools.
pub fn selectSummary(response: Response) ?[]const u8 {
    if (response.terminal != .done) return null;
    var result: ?[]const u8 = null;
    for (response.items) |item| switch (item) {
        .tool_call => return null,
        .assistant_message => |message| if (message.text.len != 0) {
            result = message.text;
        },
        else => {},
    };
    return result;
}

const expected_checkpoint_sha256 = [_]u8{
    0xe6, 0xf9, 0x56, 0xc7, 0xff, 0x9c, 0x28, 0x6a,
    0xf9, 0x18, 0x22, 0xf9, 0xc6, 0x71, 0x21, 0xf1,
    0xfe, 0xa4, 0xae, 0x50, 0xfa, 0xd9, 0x85, 0x3f,
    0xa4, 0xe2, 0x08, 0x2c, 0x26, 0xd4, 0x2b, 0xf5,
};

test "checkpoint prompt has exact hax bytes" {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(checkpoint_prompt, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_checkpoint_sha256, &digest);
    try std.testing.expectEqual(@as(usize, 1161), checkpoint_prompt.len);

    var plain = try buildCheckpointPrompt(std.testing.allocator, null);
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(checkpoint_prompt, plain.bytes);

    var focused = try buildCheckpointPrompt(std.testing.allocator, "keep paths");
    defer focused.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        checkpoint_prompt.len + focus_prefix.len + "keep paths".len,
        focused.bytes.len,
    );
    try std.testing.expectEqualStrings(checkpoint_prompt, focused.bytes[0..checkpoint_prompt.len]);
    try std.testing.expectEqualStrings(
        "\n\nAdditional focus for this summary:\nkeep paths",
        focused.bytes[checkpoint_prompt.len..],
    );

    var empty = try buildCheckpointPrompt(std.testing.allocator, "");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(checkpoint_prompt, empty.bytes);
}

test "compact seed has exact hax bytes and owns mutable summary" {
    var summary = [_]u8{ 's', 'u', 'm', 'm', 'a', 'r', 'y' };
    var seed = try buildSeed(std.testing.allocator, &summary);
    defer seed.deinit(std.testing.allocator);
    @memset(&summary, 'x');
    try std.testing.expectEqualStrings(
        "The earlier part of this conversation was condensed to free up context. The summary " ++
            "below captures everything that happened before this point — treat it as established " ++
            "context and continue the work from here.\n\nsummary",
        seed.bytes,
    );
}

test "checkpoint prompt owns mutable instructions" {
    var instructions = [_]u8{ 'f', 'o', 'c', 'u', 's' };
    var prompt = try buildCheckpointPrompt(std.testing.allocator, &instructions);
    defer prompt.deinit(std.testing.allocator);
    @memset(&instructions, 'x');
    try std.testing.expect(std.mem.endsWith(u8, prompt.bytes, "\nfocus"));
}

test "logical attempt limit matches hax" {
    try std.testing.expectEqual(@as(usize, 4), max_logical_attempts);
}

test "auto threshold validates inputs and rounds upward" {
    try std.testing.expect(!shouldAuto(null, 100, true, 80));
    try std.testing.expect(!shouldAuto(80, null, true, 80));
    try std.testing.expect(!shouldAuto(80, 100, false, 80));
    try std.testing.expect(!shouldAuto(80, 0, true, 80));
    try std.testing.expect(!shouldAuto(80, 100, true, 0));
    try std.testing.expect(!shouldAuto(80, 100, true, 101));
    try std.testing.expect(!shouldAuto(0, 1, true, 1));
    try std.testing.expect(shouldAuto(1, 1, true, 1));
    try std.testing.expect(!shouldAuto(1, 3, true, 50));
    try std.testing.expect(shouldAuto(2, 3, true, 50));
}

test "auto threshold is overflow safe at maximum token counts" {
    const maximum = std.math.maxInt(u64);
    try std.testing.expect(shouldAuto(maximum, maximum, true, 100));
    try std.testing.expect(!shouldAuto(maximum - 1, maximum, true, 100));
    const eighty_percent: u64 = maximum / 100 * 80 +
        (maximum % 100 * 80) / 100 +
        @as(u64, @intFromBool((maximum % 100 * 80) % 100 != 0));
    try std.testing.expect(!shouldAuto(eighty_percent - 1, maximum, true, 80));
    try std.testing.expect(shouldAuto(eighty_percent, maximum, true, 80));
}

test "builders enforce input and final byte bounds" {
    const prompt_room = max_final_text_bytes - checkpoint_prompt.len - focus_prefix.len;
    const prompt_input = try std.testing.allocator.alloc(u8, prompt_room + 1);
    defer std.testing.allocator.free(prompt_input);
    @memset(prompt_input, 'p');
    var prompt = try buildCheckpointPrompt(std.testing.allocator, prompt_input[0..prompt_room]);
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_final_text_bytes, prompt.bytes.len);
    try std.testing.expectError(
        error.FinalTextTooLarge,
        buildCheckpointPrompt(std.testing.allocator, prompt_input),
    );

    var oversized_instruction: [max_instructions_bytes + 1]u8 = undefined;
    try std.testing.expectError(
        error.InstructionsTooLarge,
        buildCheckpointPrompt(std.testing.allocator, &oversized_instruction),
    );

    const seed_room = max_final_text_bytes - seed_preamble.len - seed_separator.len;
    const seed_input = try std.testing.allocator.alloc(u8, seed_room + 1);
    defer std.testing.allocator.free(seed_input);
    @memset(seed_input, 's');
    var seed = try buildSeed(std.testing.allocator, seed_input[0..seed_room]);
    defer seed.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_final_text_bytes, seed.bytes.len);
    try std.testing.expectError(
        error.FinalTextTooLarge,
        buildSeed(std.testing.allocator, seed_input),
    );

    var oversized_summary: [max_summary_bytes + 1]u8 = undefined;
    try std.testing.expectError(
        error.SummaryTooLarge,
        buildSeed(std.testing.allocator, &oversized_summary),
    );
}

test "summary selection requires done and rejects every tool call" {
    const messages = [_]Item{
        .{ .assistant_message = .{ .text = @constCast("first") } },
        .{ .reasoning = .{ .text = @constCast("reasoning") } },
        .{ .assistant_message = .{ .text = @constCast("") } },
        .{ .assistant_message = .{ .text = @constCast("last") } },
    };
    try std.testing.expectEqualStrings("last", selectSummary(.{
        .terminal = .done,
        .items = &messages,
    }).?);
    try std.testing.expect(selectSummary(.{ .terminal = .failed, .items = &messages }) == null);

    const with_call = [_]Item{
        .{ .assistant_message = .{ .text = @constCast("summary") } },
        .{ .tool_call = .{
            .id = @constCast("call"),
            .name = @constCast("read"),
            .arguments_json = @constCast("{}"),
        } },
    };
    try std.testing.expect(selectSummary(.{ .terminal = .done, .items = &with_call }) == null);
}

test "summary selection ignores reasoning and empty assistant messages" {
    const items = [_]Item{
        .{ .reasoning = .{ .text = @constCast("reasoning") } },
        .{ .assistant_message = .{ .text = @constCast("") } },
        .turn_boundary,
    };
    try std.testing.expect(selectSummary(.{ .terminal = .done, .items = &items }) == null);
    try std.testing.expect(selectSummary(.{ .terminal = .done, .items = &.{} }) == null);
}

fn exerciseBuildAllocations(allocator: std.mem.Allocator) !void {
    var prompt = try buildCheckpointPrompt(allocator, "focus");
    defer prompt.deinit(allocator);
    var seed = try buildSeed(allocator, "summary");
    defer seed.deinit(allocator);
}

test "builders report OOM without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseBuildAllocations,
        .{},
    );
}
