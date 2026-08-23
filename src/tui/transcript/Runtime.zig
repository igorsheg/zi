// Adapts vercel-labs/fx src/ui/transcript/runtime.zig to Zi's admitted
// interactive event contract. The runtime owns transcript mutation and open-tail
// settlement; Screen only coordinates invalidation and publication.
const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const interactive = @import("../../coding_agent/root.zig").interactive;
const terminal_render = @import("../../terminal_render/root.zig");
const SafeText = @import("../SafeText.zig");
const markdown = @import("../markdown/root.zig");
const tool_presentation = @import("../tools/tool_presentation.zig");
const StoreModule = @import("Store.zig");

const Runtime = @This();
const Store = StoreModule.Store;
const EntryClass = StoreModule.EntryClass;
const ToolOutcome = StoreModule.ToolOutcome;

const StreamKind = enum { assistant, thinking };

const ActiveTool = struct {
    call_hash: u64,
    presentation: tool_presentation.Activity,
};

allocator: std.mem.Allocator,
store: Store,
scratch: std.Io.Writer.Allocating,
processor: markdown.Processor,
markdown_out: std.ArrayList(u8) = .empty,
open_entry: ?u32 = null,
open_kind: StreamKind = .assistant,
open_part_index: usize = 0,
open_entry_irreversible: bool = false,
response_next_index: usize = 0,
active_tool: ?ActiveTool = null,

pub fn init(allocator: std.mem.Allocator, max_store_bytes: usize) !Runtime {
    if (max_store_bytes == 0) return error.InvalidStoreByteLimit;
    return .{
        .allocator = allocator,
        .store = Store.init(allocator, max_store_bytes),
        .scratch = .init(allocator),
        .processor = .{},
    };
}

pub fn deinit(self: *Runtime) void {
    if (self.active_tool) |*active| active.presentation.deinit(self.allocator);
    self.processor.deinit(self.allocator);
    self.markdown_out.deinit(self.allocator);
    self.scratch.deinit();
    self.store.deinit();
    self.* = undefined;
}

pub fn openEntryId(self: *const Runtime) ?u32 {
    return self.open_entry;
}

pub fn markOpenEntryMaterialized(self: *Runtime) void {
    if (self.open_entry != null) self.open_entry_irreversible = true;
}

pub fn finishOpenEntry(self: *Runtime) !void {
    if (self.open_entry != null) try self.sealOpenEntry();
}

pub fn start(
    self: *Runtime,
    restored: ?*const interactive.SessionTranscript,
) !void {
    self.scratch.clearRetainingCapacity();
    var welcome_style = terminal_render.Ansi.Encoder.init(&self.scratch.writer);
    try welcome_style.setStyle(.{ .attributes = .{ .bold = true } });
    try self.scratch.writer.writeAll("Zi");
    try welcome_style.setStyle(.{ .attributes = .{ .dim = true } });
    try self.scratch.writer.writeAll(" · enter to send, /model to switch");
    try welcome_style.setStyle(.{});
    try self.scratch.writer.writeByte('\n');
    _ = try self.sealedEntry(.welcome, self.scratch.written());
    if (restored) |value| try self.restoreTranscript(value);
}

fn restoreTranscript(self: *Runtime, value: *const interactive.SessionTranscript) !void {
    for (value.items) |item| switch (item.content) {
        .model_change => |identity| try self.addModel(identity),
        .user => |user| try self.addUser(user.parts),
        .assistant => |response| for (response.parts) |part|
            try self.renderPartSource(part),
        .tool_results => |results| for (results.results) |result|
            try self.addToolResult(result),
        .failure => |failure| {
            var label_buffer: [128]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &label_buffer,
                "turn failed: {s}",
                .{@tagName(failure.category)},
            );
            try self.addNotice(label);
        },
        .cancelled => try self.addNotice("turn cancelled"),
        .interrupted => try self.addNotice("turn interrupted"),
    };
}

pub fn apply(self: *Runtime, fact: interactive.HostFact) !void {
    switch (fact) {
        .turn => |turn| try self.applyTurnFact(turn),
        .auth_started => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logging in to {s}", .{value.provider});
            try self.addNotice(label);
        },
        .auth_interaction => |interaction| switch (interaction) {
            .auth_url => |value| {
                try self.addNotice(value.instructions);
                try self.addNotice(value.url);
            },
            .device_code => |value| {
                try self.addNotice(value.verification_uri);
                var buffer: [1024]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, "Device code: {s}", .{value.user_code});
                try self.addNotice(label);
            },
            .prompt => |value| try self.addNotice(value.message),
        },
        .auth_cancelled => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Login cancelled for {s}", .{value.provider});
            try self.addNotice(label);
        },
        .login_succeeded => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logged in to {s}", .{value.provider});
            try self.addNotice(label);
        },
        .login_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Login failed for {s}: {s}",
                .{ value.provider, @tagName(value.failure) },
            );
            try self.addNotice(label);
        },
        .model_changed => |selection| try self.addModel(selection),
        .model_less => try self.addNotice("No model is available"),
        .model_switch_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} failed: {s}",
                .{ value.requested.provider, value.requested.model, value.reason },
            );
            try self.addNotice(label);
        },
        .model_switch_commit_indeterminate => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} had an indeterminate journal commit",
                .{ value.provider, value.model },
            );
            try self.addNotice(label);
        },
        .settings_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model changed, but saving the default failed: {s}",
                .{value.reason},
            );
            try self.addNotice(label);
        },
        .settings_commit_indeterminate => try self.addNotice(
            "Model changed, but saving the default was indeterminate",
        ),
        .session_unavailable => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Session unavailable: {s}", .{value.reason});
            try self.addNotice(label);
        },
    }
}

fn applyTurnFact(self: *Runtime, fact: interactive.TurnFact) !void {
    switch (fact) {
        .event => |event| try self.applyEvent(event),
        .completion => |completion| {
            if (!completion.agent_end_observed) switch (completion.value.outcome) {
                .completed => {},
                .failed => |failure| try self.addNotice(@errorName(failure)),
            };
        },
        .fault => |fault| switch (fault) {
            .follow_up_submission => |failure| try self.addNotice(@errorName(failure)),
            .draft_restore => |failure| try self.addNotice(@errorName(failure)),
        },
    }
}

fn applyEvent(self: *Runtime, event: interactive.Event) !void {
    switch (event) {
        .agent_start, .turn_start, .turn_end => {},
        .message_start => |started| switch (started.message) {
            .request => |request| for (request.parts) |part| switch (part) {
                .user => |user| try self.addUser(&.{user}),
                .tool_result, .retry_prompt => {},
            },
            .response => self.response_next_index = 0,
        },
        .message_update => |update| switch (update.update) {
            .part_start => |started| self.streamPartStart(started),
            .part_delta => |delta| try self.streamPartDelta(delta),
            .part_end => |ended| try self.sealStreamedPart(ended.index, ended.part),
            .usage => {},
        },
        .message_end => |ended| switch (ended.message) {
            .published => |message| switch (message) {
                .request => {},
                .response => |response| try self.finishResponse(response.parts),
            },
            .discarded_response => |discarded| {
                try self.discardOpenEntry();
                for (discarded.response.parts[self.response_next_index..]) |part|
                    try self.renderSnapshotPart(part);
                self.response_next_index = 0;
                var label_buffer: [128]u8 = undefined;
                const label = try std.fmt.bufPrint(
                    &label_buffer,
                    "response discarded: {s}",
                    .{@tagName(discarded.outcome)},
                );
                try self.addNotice(label);
            },
        },
        .tool_execution_start => |started| try self.startTool(
            started.call_id,
            started.name,
            started.arguments_json,
        ),
        .tool_execution_end => |ended| try self.finishTool(ended.call_id, ended.name, ended.result),
        .agent_end => |ended| switch (ended.outcome) {
            .completed => {},
            .cancelled, .interrupted, .failed => {
                try self.discardOpenEntry();
                var label_buffer: [128]u8 = undefined;
                const label = switch (ended.outcome) {
                    .cancelled => "turn cancelled",
                    .interrupted => "turn interrupted",
                    .failed => |failure| try std.fmt.bufPrint(
                        &label_buffer,
                        "turn failed: {s}",
                        .{@tagName(failure)},
                    ),
                    .completed => unreachable,
                };
                try self.addNotice(label);
            },
        },
        .agent_settled => |settled| if (settled.availability == .poisoned) {
            try self.addNotice("session unavailable, reopen the durable session");
        },
    }
}

// Streaming facts ------------------------------------------------------------

fn streamPartStart(self: *Runtime, started: ai.stream.PartStart) void {
    self.open_part_index = started.index;
    switch (started.part) {
        .text => self.open_kind = .assistant,
        .thinking => self.open_kind = .thinking,
        .tool_call => {},
    }
}

fn streamPartDelta(self: *Runtime, delta: ai.stream.PartDelta) !void {
    self.open_part_index = delta.index;
    switch (delta.delta) {
        .text => |text| try self.streamMarkdownBytes(text),
        .thinking => |thinking| try self.streamMarkdownBytes(thinking),
        .tool_call => {},
    }
}

fn streamMarkdownBytes(self: *Runtime, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (self.open_entry == null) {
        const seed = if (self.open_kind == .thinking)
            "\x1b[2mThinking\x1b[22m\n"
        else
            "";
        self.open_entry = try self.store.openEntry(
            switch (self.open_kind) {
                .assistant => .assistant_turn,
                .thinking => .thinking,
            },
            seed,
        );
        self.open_entry_irreversible = false;
    }
    // Only settled processor output enters the transcript source. Sanitation
    // happens before Markdown interpretation so provider controls can never be
    // mistaken for trusted presentation SGR or OSC runs.
    self.markdown_out.clearRetainingCapacity();
    try self.pushSafeMarkdown(&self.processor, bytes, &self.markdown_out);
    if (self.markdown_out.items.len != 0) {
        try self.store.appendTo(self.open_entry.?, self.markdown_out.items);
    }
}

fn sealStreamedPart(self: *Runtime, index: usize, part: ai.message.ResponsePart) !void {
    self.response_next_index = index + 1;
    if (self.open_entry != null) return self.sealOpenEntry();
    try self.renderPartSource(part);
}

fn finishResponse(self: *Runtime, parts: []const ai.message.ResponsePart) !void {
    if (self.open_entry != null) try self.sealOpenEntry();
    // Parts the stream never delivered are rendered whole, once.
    for (parts[self.response_next_index..]) |part| try self.renderPartSource(part);
    self.response_next_index = 0;
}

/// Finalizes an open entry whose already-painted rows may have entered native
/// scrollback. Released terminal history is immutable, so cancellation must
/// retain the matching transcript source instead of trying to erase it.
fn sealOpenEntry(self: *Runtime) !void {
    const id = self.open_entry orelse return;
    defer self.resetOpenEntry();
    self.markdown_out.clearRetainingCapacity();
    try self.processor.flush(self.allocator, &self.markdown_out);
    if (self.markdown_out.items.len != 0) {
        try self.store.appendTo(id, self.markdown_out.items);
    }
    try self.store.sealEntry(id);
    self.response_next_index = @max(self.response_next_index, self.open_part_index +| 1);
}

/// Drops a replaceable tail only while every painted row remains inside Zi's
/// current owned band. Once a commit scrolls a prior copy, finality wins.
fn discardOpenEntry(self: *Runtime) !void {
    const id = self.open_entry orelse return;
    if (self.open_entry_irreversible) return self.sealOpenEntry();
    self.resetOpenEntry();
    self.store.dropEntriesFrom(id) catch |failure| switch (failure) {
        error.EntryNotFound => {},
        else => return failure,
    };
}

fn resetOpenEntry(self: *Runtime) void {
    self.open_entry = null;
    self.open_entry_irreversible = false;
    self.processor.reset(self.allocator);
}

// Entry helpers --------------------------------------------------------------

/// Renders one complete response part into its own sealed entry. This is the
/// fallback for parts the stream never delta-fed and for restored transcripts.
fn renderPartSource(self: *Runtime, part: ai.message.ResponsePart) !void {
    switch (part) {
        .text => |text| try self.addMarkdownEntry(.assistant_turn, text.text),
        .thinking => |thinking| try self.addMarkdownEntry(.thinking, thinking.text),
        .tool_call => {},
    }
}

fn renderSnapshotPart(self: *Runtime, part: ai.stream.ResponsePartSnapshot) !void {
    switch (part) {
        .text => |text| try self.addMarkdownEntry(.assistant_turn, text),
        .thinking => |thinking| try self.addMarkdownEntry(.thinking, thinking),
        .tool_call => {},
    }
}

fn addMarkdownEntry(
    self: *Runtime,
    entry_class: EntryClass,
    markdown_source: []const u8,
) !void {
    if (std.mem.trim(u8, markdown_source, " \t\r\n").len == 0) return;

    var processor: markdown.Processor = .{};
    defer processor.deinit(self.allocator);
    self.markdown_out.clearRetainingCapacity();
    try self.pushSafeMarkdown(&processor, markdown_source, &self.markdown_out);
    try processor.flush(self.allocator, &self.markdown_out);
    if (self.markdown_out.items.len > self.remainingStoreBytes()) return error.StoreFull;

    self.scratch.clearRetainingCapacity();
    if (entry_class == .thinking) {
        var encoder = terminal_render.Ansi.Encoder.init(&self.scratch.writer);
        try encoder.setStyle(.{ .attributes = .{ .dim = true } });
        try self.scratch.writer.writeAll("Thinking");
        try encoder.setStyle(.{});
        try self.scratch.writer.writeByte('\n');
    }
    try self.scratch.writer.writeAll(self.markdown_out.items);
    try self.scratch.writer.writeByte('\n');
    _ = try self.sealedEntry(entry_class, self.scratch.written());
}

fn pushSafeMarkdown(
    self: *Runtime,
    processor: *markdown.Processor,
    source: []const u8,
    out: *std.ArrayList(u8),
) !void {
    self.scratch.clearRetainingCapacity();
    try SafeText.write(&self.scratch.writer, source, true);
    try processor.push(self.allocator, self.scratch.written(), out);
}

fn addUser(self: *Runtime, parts: []const ai.message.UserContent) !void {
    self.scratch.clearRetainingCapacity();
    for (parts, 0..) |part, index| {
        if (index != 0) try self.scratch.writer.writeByte(' ');
        switch (part) {
            .text => |text| try SafeText.write(&self.scratch.writer, text, true),
            .image => |image| {
                try self.scratch.writer.writeAll("[image ");
                try SafeText.write(&self.scratch.writer, image.media_type, false);
                try self.scratch.writer.writeByte(']');
            },
        }
    }
    if (self.scratch.written().len == 0) return;
    // User turns stay semantic in the store. The card owner rebuilds their
    // connected rail at paint-time for the current terminal width.
    _ = try self.sealedEntry(.user_turn, self.scratch.written());
}

fn addModel(self: *Runtime, identity: ai.message.ModelIdentity) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.writer.writeAll("[model ");
    try SafeText.write(&self.scratch.writer, identity.provider, false);
    try self.scratch.writer.writeByte('/');
    try SafeText.write(&self.scratch.writer, identity.model, false);
    try self.scratch.writer.writeAll("]\n");
    _ = try self.sealedEntry(.model_change, self.scratch.written());
}

fn addToolResult(self: *Runtime, result: ai.message.ToolResult) !void {
    var presentation = try tool_presentation.Activity.init(self.allocator, result.name, "{}");
    defer presentation.deinit(self.allocator);
    try self.addToolCompletion(
        presentation,
        if (result.outcome == .success) .success else .failed,
    );
}

fn startTool(
    self: *Runtime,
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) !void {
    if (self.active_tool != null) return error.ToolAlreadyRunning;
    var presentation = try tool_presentation.Activity.init(
        self.allocator,
        name,
        arguments_json,
    );
    errdefer presentation.deinit(self.allocator);
    self.active_tool = .{
        .call_hash = std.hash.Wyhash.hash(0, call_id),
        .presentation = presentation,
    };
}

fn finishTool(
    self: *Runtime,
    call_id: []const u8,
    name: []const u8,
    result: agent.event.ToolExecutionResult,
) !void {
    var active = self.active_tool orelse return error.ToolNotRunning;
    if (active.call_hash != std.hash.Wyhash.hash(0, call_id)) return error.ToolLifecycleMismatch;
    self.active_tool = null;
    defer active.presentation.deinit(self.allocator);
    _ = name;
    switch (result) {
        .published => |published| try self.addToolCompletion(
            active.presentation,
            if (published.outcome == .success) .success else .failed,
        ),
        .discarded => |outcome| try self.addToolCompletion(active.presentation, switch (outcome) {
            .completed => .success,
            .failed => .failed,
            .cancelled => .cancelled,
            .interrupted => .interrupted,
        }),
    }
}

fn addToolCompletion(
    self: *Runtime,
    presentation: tool_presentation.Activity,
    outcome: ToolOutcome,
) !void {
    _ = try self.store.appendToolStatus(presentation.completed, outcome);
}

pub fn activeToolLabel(self: *const Runtime) ?[]const u8 {
    const active = self.active_tool orelse return null;
    return active.presentation.running;
}

fn addNotice(self: *Runtime, label: []const u8) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.writer.writeByte('[');
    try SafeText.write(&self.scratch.writer, label, false);
    try self.scratch.writer.writeAll("]\n");
    _ = try self.sealedEntry(.system_notice, self.scratch.written());
}

fn sealedEntry(self: *Runtime, entry_class: EntryClass, bytes: []const u8) !u32 {
    return self.store.appendSealed(entry_class, bytes);
}

fn remainingStoreBytes(self: *const Runtime) usize {
    return self.store.max_store_bytes -| self.store.total_bytes;
}

pub fn notice(self: *Runtime, text: []const u8) !void {
    try self.addNotice(text);
}

test "runtime sanitizes Markdown before retaining presentation escapes" {
    var runtime = try Runtime.init(std.testing.allocator, 1024);
    defer runtime.deinit();

    try runtime.addMarkdownEntry(.assistant_turn, "safe\x1b[2J **text**");
    const entry = runtime.store.lastEntry().?;
    const bytes = entry.textBytes().?;
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "safe") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "text") != null);
}
