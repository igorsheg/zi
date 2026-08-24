const std = @import("std");
const Context = @import("Context.zig");

/// The built-in Zi system prompt. This is hax's default prompt with only the
/// product identity changed from hax to Zi.
pub const default_system_prompt =
    "You are Zi, a minimalist coding assistant running in the user's terminal.\n" ++
    "\n" ++
    "Prefer action over explanation: when a question can be answered by running a " ++
    "command or reading a file, do so. Be concise: no filler, no trailing " ++
    "summaries. Reference code as path:line. Before substantial work, say in one " ++
    "sentence what you're about to do; while working, mention only meaningful " ++
    "developments (a root cause, a change of direction, a blocker worth a " ++
    "decision), not routine steps.\n" ++
    "\n" ++
    "When something is ambiguous, infer from the code and pick a sensible default " ++
    "rather than stopping. Ask only when genuinely blocked: the choice materially " ++
    "changes the result, an action is destructive or affects shared state, or you " ++
    "need a value you can't obtain. To ask, end your turn with one targeted " ++
    "question and a recommended default.\n" ++
    "\n" ++
    "When changing code:\n" ++
    "- Make the smallest correct change that fits the existing style.\n" ++
    "- Fix root causes, not symptoms. Don't fix unrelated bugs unless asked.\n" ++
    "- Don't introduce new abstractions, helpers, or compatibility shims unless " ++
    "the task genuinely needs them.\n" ++
    "- Add a comment only when the *why* is non-obvious.\n" ++
    "- If the project has a build, tests, or linter, run them before reporting done.\n" ++
    "\n" ++
    "Git: never commit, push, amend, branch, or run destructive commands " ++
    "(`reset --hard`, `checkout --`, `branch -D`) unless the user explicitly asks. " ++
    "Never revert changes you didn't make. If a hook or check fails, fix the cause; " ++
    "don't bypass with `--no-verify`.\n" ++
    "\n" ++
    "If asked for a \"review\": lead with bugs, risks, and missing tests for the " ++
    "*proposed change*, not a summary. A finding should be one the author would " ++
    "fix if they knew. Skip pre-existing issues and trivial style. Calibrate " ++
    "severity honestly; no flattery. Empty findings is a valid result.";

pub const Base = union(enum) {
    default,
    custom: []const u8,
    empty,
    none,

    /// Adapts the hax configuration value into the typed base mode. The returned
    /// custom text borrows `value`.
    pub fn fromValue(value: ?[]const u8) Base {
        const text = value orelse return .default;
        if (std.mem.eql(u8, text, "(none)")) return .none;
        if (text.len == 0) return .empty;
        return .{ .custom = text };
    }
};

pub const Options = struct {
    raw: bool = false,
    base: Base = .default,
    append: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
};

/// Allocator-owned, move-only system prompt. Call `deinit` exactly once.
pub const OwnedPrompt = struct {
    bytes: []u8,

    pub fn deinit(self: *OwnedPrompt, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Builds the provider-facing system prompt. `null` means no system message.
/// All option text is borrowed. A non-null return value owns an independent
/// allocation which transfers to the caller.
pub const BuildError = error{ OutOfMemory, PromptTooLarge };

pub fn build(allocator: std.mem.Allocator, options: Options) BuildError!?OwnedPrompt {
    if (options.raw or options.base == .none) return null;

    const base: []const u8 = switch (options.base) {
        .default => default_system_prompt,
        .custom => |text| text,
        .empty => "",
        .none => unreachable,
    };

    const parts = [_]?[]const u8{ base, options.append, options.suffix };
    var total: usize = 0;
    var part_count: usize = 0;
    for (parts) |maybe_part| {
        const part = maybe_part orelse continue;
        if (part.len == 0) continue;
        if (part_count != 0) {
            total = std.math.add(usize, total, 2) catch return error.PromptTooLarge;
        }
        total = std.math.add(usize, total, part.len) catch return error.PromptTooLarge;
        if (total > Context.max_prompt_bytes) return error.PromptTooLarge;
        part_count += 1;
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, total);
    defer output.deinit(allocator);
    for (parts) |maybe_part| {
        const part = maybe_part orelse continue;
        if (part.len == 0) continue;
        if (output.items.len != 0) output.appendSliceAssumeCapacity("\n\n");
        output.appendSliceAssumeCapacity(part);
    }
    if (output.items.len == 0) return null;
    return .{ .bytes = try output.toOwnedSlice(allocator) };
}

fn expectBuild(options: Options, expected: ?[]const u8) !void {
    var actual = try build(std.testing.allocator, options);
    defer if (actual) |*prompt| prompt.deinit(std.testing.allocator);
    if (expected) |text| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(text, actual.?.bytes);
    } else {
        try std.testing.expect(actual == null);
    }
}

test "base values map to typed modes" {
    try std.testing.expect(Base.fromValue(null) == .default);
    try std.testing.expect(Base.fromValue("") == .empty);
    try std.testing.expect(Base.fromValue("(none)") == .none);
    const custom = Base.fromValue("prompt");
    try std.testing.expectEqualStrings("prompt", custom.custom);
}

test "all base append suffix and raw combinations" {
    const bases = [_]Base{ .default, .{ .custom = "base" }, .empty, .none };
    const optional_parts = [_]?[]const u8{ null, "", "part" };
    for ([_]bool{ false, true }) |raw| {
        for (bases) |base| {
            for (optional_parts) |append| {
                for (optional_parts) |suffix| {
                    const has_append = if (append) |part| part.len != 0 else false;
                    const has_suffix = if (suffix) |part| part.len != 0 else false;
                    const expected: ?[]const u8 = if (raw or base == .none)
                        null
                    else switch (base) {
                        .default => if (has_append and has_suffix)
                            default_system_prompt ++ "\n\npart\n\npart"
                        else if (has_append or has_suffix)
                            default_system_prompt ++ "\n\npart"
                        else
                            default_system_prompt,
                        .custom => if (has_append and has_suffix)
                            "base\n\npart\n\npart"
                        else if (has_append or has_suffix)
                            "base\n\npart"
                        else
                            "base",
                        .empty => if (has_append and has_suffix)
                            "part\n\npart"
                        else if (has_append or has_suffix)
                            "part"
                        else
                            null,
                        .none => unreachable,
                    };
                    try expectBuild(.{
                        .raw = raw,
                        .base = base,
                        .append = append,
                        .suffix = suffix,
                    }, expected);
                }
            }
        }
    }
}

test "empty parts are skipped without separators" {
    try expectBuild(.{ .base = .empty, .append = "", .suffix = "suffix" }, "suffix");
    try expectBuild(.{ .base = .{ .custom = "base" }, .append = "", .suffix = "" }, "base");
}

test "result owns copies of mutable inputs" {
    var base = [_]u8{ 'b', 'a', 's', 'e' };
    var append = [_]u8{ 'a', 'p', 'p' };
    var suffix = [_]u8{ 'e', 'n', 'v' };
    var prompt = (try build(std.testing.allocator, .{
        .base = .{ .custom = &base },
        .append = &append,
        .suffix = &suffix,
    })).?;
    defer prompt.deinit(std.testing.allocator);

    @memset(&base, 'x');
    @memset(&append, 'x');
    @memset(&suffix, 'x');
    try std.testing.expectEqualStrings("base\n\napp\n\nenv", prompt.bytes);
}

test "aggregate bound includes separators and rejects one byte over before allocation" {
    const exact = [_]u8{'x'} ** Context.max_prompt_bytes;
    var prompt = (try build(std.testing.allocator, .{ .base = .{ .custom = &exact } })).?;
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(Context.max_prompt_bytes, prompt.bytes.len);

    const over = [_]u8{'x'} ** (Context.max_prompt_bytes + 1);
    try std.testing.expectError(
        error.PromptTooLarge,
        build(std.testing.failing_allocator, .{ .base = .{ .custom = &over } }),
    );

    const append = [_]u8{'y'} ** (Context.max_prompt_bytes - 2);
    try std.testing.expectError(
        error.PromptTooLarge,
        build(std.testing.failing_allocator, .{
            .base = .{ .custom = "x" },
            .append = &append,
        }),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var prompt = try build(allocator, .{
        .base = .{ .custom = "base" },
        .append = "append",
        .suffix = "suffix",
    });
    defer if (prompt) |*owned| owned.deinit(allocator);
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
