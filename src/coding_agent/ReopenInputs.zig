const std = @import("std");
const ai = @import("../ai/root.zig");
const AgentSessionRuntime = @import("AgentSessionRuntime.zig");
const RuntimeServices = @import("RuntimeServices.zig");
const SessionSelection = @import("SessionSelection.zig");
const SystemPrompt = @import("SystemPrompt.zig");

const ReopenInputs = @This();

const max_environment_entries = 64;
const max_sensitive_bytes = 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    TooManyEnvironmentEntries,
    SensitiveInputsTooLarge,
};

pub const Selection = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
sensitive: std.ArrayList([]u8) = .empty,
inputs: RuntimeServices.Inputs,

/// Owns every string in a runtime input that can outlive process parsing.
/// Source callbacks and event sinks remain borrowed function contracts.
pub fn init(
    allocator: std.mem.Allocator,
    source: RuntimeServices.Inputs,
) Error!ReopenInputs {
    if (source.environment.entries.len > max_environment_entries) {
        return error.TooManyEnvironmentEntries;
    }

    var self: ReopenInputs = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .inputs = undefined,
    };
    errdefer self.deinit();
    try self.sensitive.ensureTotalCapacity(
        allocator,
        source.environment.entries.len + @intFromBool(source.cli_api_key != null),
    );

    const owned = self.arena.allocator();
    const environment_entries = try owned.alloc(ai.auth.EnvironmentEntry, source.environment.entries.len);
    var sensitive_bytes: usize = 0;
    for (source.environment.entries, environment_entries) |entry, *destination| {
        const value = try self.copySensitive(entry.value, &sensitive_bytes);
        destination.* = .{
            .name = try owned.dupe(u8, entry.name),
            .value = value,
        };
    }
    const cli_api_key = if (source.cli_api_key) |value|
        try self.copySensitive(value, &sensitive_bytes)
    else
        null;

    self.inputs = .{
        .startup_cwd = try owned.dupe(u8, source.startup_cwd),
        .home = try owned.dupe(u8, source.home),
        .session = try copySessionIntent(owned, source.session),
        .sources = source.sources,
        .requested_provider = if (source.requested_provider) |value| try owned.dupe(u8, value) else null,
        .requested_model = if (source.requested_model) |value| try owned.dupe(u8, value) else null,
        .cli_api_key = cli_api_key,
        .project_trust = source.project_trust,
        .environment = .{ .entries = environment_entries },
        .options = try copyOptions(owned, source.options),
    };
    return self;
}

pub fn initial(self: *const ReopenInputs) RuntimeServices.Inputs {
    return self.inputs;
}

pub fn reopen(
    self: *const ReopenInputs,
    journal_path: []const u8,
    selection: Selection,
) RuntimeServices.Inputs {
    var result = self.inputs;
    result.session = .{ .open = journal_path };
    result.requested_provider = selection.provider;
    result.requested_model = selection.model;
    return result;
}

pub fn deinit(self: *ReopenInputs) void {
    for (self.sensitive.items) |value| std.crypto.secureZero(u8, value);
    self.sensitive.deinit(self.allocator);
    self.arena.deinit();
    self.* = undefined;
}

fn copySensitive(
    self: *ReopenInputs,
    value: []const u8,
    retained_bytes: *usize,
) Error![]u8 {
    if (value.len > max_sensitive_bytes -| retained_bytes.*) {
        return error.SensitiveInputsTooLarge;
    }
    const copy = try self.arena.allocator().dupe(u8, value);
    self.sensitive.appendAssumeCapacity(copy);
    retained_bytes.* += copy.len;
    return copy;
}

fn copySessionIntent(
    allocator: std.mem.Allocator,
    source: SessionSelection.Intent,
) error{OutOfMemory}!SessionSelection.Intent {
    return switch (source) {
        .new => .new,
        .continue_recent => .continue_recent,
        .open => |path| .{ .open = try allocator.dupe(u8, path) },
    };
}

fn copyOptions(
    allocator: std.mem.Allocator,
    source: AgentSessionRuntime.Options,
) error{OutOfMemory}!AgentSessionRuntime.Options {
    var result = source;
    result.prompt.working_directory = try allocator.dupe(u8, source.prompt.working_directory);
    result.prompt.policy = switch (source.prompt.policy) {
        .verbatim => |text| .{ .verbatim = try allocator.dupe(u8, text) },
        .composed => |composition| .{ .composed = try copyComposition(allocator, composition) },
    };
    return result;
}

fn copyComposition(
    allocator: std.mem.Allocator,
    source: SystemPrompt.Composition,
) error{OutOfMemory}!SystemPrompt.Composition {
    const sections = try allocator.alloc(SystemPrompt.ContextSection, source.context_sections.len);
    for (source.context_sections, sections) |section, *destination| {
        destination.* = .{
            .path = try allocator.dupe(u8, section.path),
            .text = try allocator.dupe(u8, section.text),
        };
    }
    const rules = try allocator.alloc([]const u8, source.rules.len);
    for (source.rules, rules) |rule, *destination| destination.* = try allocator.dupe(u8, rule);
    return .{
        .base = switch (source.base) {
            .builtin => .builtin,
            .custom => |text| .{ .custom = try allocator.dupe(u8, text) },
        },
        .context_sections = sections,
        .rules = rules,
    };
}

test "reopen inputs own nested launch text and wipe every copied secret" {
    var api_key = [_]u8{ 'c', 'l', 'i' };
    var environment_secret = [_]u8{ 'e', 'n', 'v' };
    var source_context = [_]u8{ 'r', 'u', 'l', 'e' };
    const environment = [_]ai.auth.EnvironmentEntry{.{
        .name = "OPENAI_API_KEY",
        .value = &environment_secret,
    }};
    const sections = [_]SystemPrompt.ContextSection{.{ .path = "AGENTS.md", .text = &source_context }};
    var owned = try ReopenInputs.init(std.testing.allocator, .{
        .startup_cwd = "/work",
        .home = "/home",
        .session = .{ .open = "session.jsonl" },
        .sources = undefined,
        .requested_provider = "openai",
        .requested_model = "model",
        .cli_api_key = &api_key,
        .environment = .{ .entries = &environment },
        .options = .{ .prompt = .{ .policy = .{ .composed = .{
            .context_sections = &sections,
            .rules = &.{"prompt rule"},
        } } } },
    });
    @memset(&api_key, 'x');
    @memset(&environment_secret, 'x');
    @memset(&source_context, 'x');

    try std.testing.expectEqualStrings("cli", owned.initial().cli_api_key.?);
    try std.testing.expectEqualStrings("env", owned.initial().environment.entries[0].value);
    try std.testing.expectEqualStrings(
        "rule",
        owned.initial().options.prompt.policy.composed.context_sections[0].text,
    );
    const reopened = owned.reopen("exact.jsonl", .{});
    try std.testing.expectEqualStrings("exact.jsonl", reopened.session.open);
    try std.testing.expect(reopened.requested_provider == null);
    try std.testing.expect(reopened.requested_model == null);

    owned.deinit();
}
