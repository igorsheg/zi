const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

pub const current_session_version = 3;
pub const max_session_entries = 16_384;
pub const max_branch_depth = 16_384;

pub const SessionHeader = struct {
    version: u32 = current_session_version,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const ModelRef = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContext = struct {
    messages: []const agent.AgentMessage,
    thinking_level: []const u8,
    model: ?ModelRef,
};

pub const SessionEntry = union(enum) {
    message: Message,
    thinking_level_change: ThinkingLevelChange,
    model_change: ModelChange,

    pub const Base = struct {
        id: []const u8,
        parent_id: ?[]const u8,
        timestamp: []const u8,
    };

    pub const Message = struct {
        base: Base,
        message: agent.AgentMessage,
    };

    pub const ThinkingLevelChange = struct {
        base: Base,
        thinking_level: []const u8,
    };

    pub const ModelChange = struct {
        base: Base,
        provider: []const u8,
        model_id: []const u8,
    };

    pub fn id(self: SessionEntry) []const u8 {
        return switch (self) {
            inline else => |entry| entry.base.id,
        };
    }

    pub fn parentId(self: SessionEntry) ?[]const u8 {
        return switch (self) {
            inline else => |entry| entry.base.parent_id,
        };
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    header: SessionHeader,
    entries: std.ArrayList(SessionEntry) = .empty,
    leaf_id: ?[]const u8 = null,
    next_id: u64 = 1,

    pub const Error = error{
        EntryLimitExceeded,
        BranchDepthExceeded,
        EntryNotFound,
        DuplicateEntryId,
    } || std.mem.Allocator.Error;

    pub const LoadedEntry = struct {
        id: []const u8,
        parent_id: ?[]const u8,
        timestamp: []const u8,
        value: Value,

        pub const Value = union(enum) {
            message: agent.AgentMessage,
            thinking_level_change: []const u8,
            model_change: ModelRef,
        };
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        session_id: []const u8,
        timestamp: []const u8,
    ) !SessionManager {
        const id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(id);
        const timestamp_copy = try allocator.dupe(u8, timestamp);
        errdefer allocator.free(timestamp_copy);
        const cwd_copy = try allocator.dupe(u8, cwd);
        return .{
            .allocator = allocator,
            .header = .{
                .id = id,
                .timestamp = timestamp_copy,
                .cwd = cwd_copy,
            },
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.header.id);
        self.allocator.free(self.header.timestamp);
        self.allocator.free(self.header.cwd);
        if (self.header.parent_session) |parent_session| self.allocator.free(parent_session);
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendMessage(self: *SessionManager, message: agent.AgentMessage, timestamp: []const u8) Error![]const u8 {
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.freeBase(base);
            break :blk .{ .message = .{
                .base = base,
                .message = try cloneAgentMessage(self.allocator, message),
            } };
        };
        errdefer self.freeEntry(entry);
        return self.appendEntry(entry);
    }

    pub fn appendThinkingLevelChange(
        self: *SessionManager,
        thinking_level: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.freeBase(base);
            break :blk .{ .thinking_level_change = .{
                .base = base,
                .thinking_level = try self.allocator.dupe(u8, thinking_level),
            } };
        };
        errdefer self.freeEntry(entry);
        return self.appendEntry(entry);
    }

    pub fn appendModelChange(
        self: *SessionManager,
        provider: []const u8,
        model_id: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.freeBase(base);
            const provider_copy = try self.allocator.dupe(u8, provider);
            errdefer self.allocator.free(provider_copy);
            const model_id_copy = try self.allocator.dupe(u8, model_id);
            break :blk .{ .model_change = .{
                .base = base,
                .provider = provider_copy,
                .model_id = model_id_copy,
            } };
        };
        errdefer self.freeEntry(entry);
        return self.appendEntry(entry);
    }

    pub fn appendLoadedEntry(self: *SessionManager, loaded: LoadedEntry) Error![]const u8 {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        if (self.findEntry(loaded.id) != null) return error.DuplicateEntryId;
        if (loaded.parent_id) |parent_id| {
            if (self.findEntry(parent_id) == null) return error.EntryNotFound;
        } else if (self.entries.items.len > 0) {
            return error.EntryNotFound;
        }
        const base: SessionEntry.Base = blk: {
            const id = try self.allocator.dupe(u8, loaded.id);
            errdefer self.allocator.free(id);
            const parent_id = if (loaded.parent_id) |parent_id| try self.allocator.dupe(u8, parent_id) else null;
            errdefer if (parent_id) |value| self.allocator.free(value);
            const timestamp = try self.allocator.dupe(u8, loaded.timestamp);
            break :blk .{ .id = id, .parent_id = parent_id, .timestamp = timestamp };
        };
        errdefer self.freeBase(base);
        const entry: SessionEntry = switch (loaded.value) {
            .message => |message| .{ .message = .{
                .base = base,
                .message = try cloneAgentMessage(self.allocator, message),
            } },
            .thinking_level_change => |thinking_level| .{ .thinking_level_change = .{
                .base = base,
                .thinking_level = try self.allocator.dupe(u8, thinking_level),
            } },
            .model_change => |model| blk: {
                const provider = try self.allocator.dupe(u8, model.provider);
                errdefer self.allocator.free(provider);
                const model_id = try self.allocator.dupe(u8, model.model_id);
                break :blk .{ .model_change = .{
                    .base = base,
                    .provider = provider,
                    .model_id = model_id,
                } };
            },
        };
        errdefer self.freeEntry(entry);
        var next_id = self.next_id;
        if (std.fmt.parseInt(u64, loaded.id, 16)) |numeric_id| {
            const after_loaded_id = if (numeric_id == std.math.maxInt(u64)) numeric_id else numeric_id + 1;
            next_id = @max(next_id, after_loaded_id);
        } else |_| {}
        const appended_id = try self.appendEntry(entry);
        self.next_id = next_id;
        return appended_id;
    }

    pub fn branch(self: *SessionManager, id: []const u8) Error!void {
        self.leaf_id = (try self.getEntry(id)).id();
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    pub fn getEntry(self: *const SessionManager, id: []const u8) Error!*const SessionEntry {
        return self.findEntry(id) orelse error.EntryNotFound;
    }

    pub fn getLeafEntry(self: *const SessionManager) Error!?*const SessionEntry {
        return if (self.leaf_id) |id| try self.getEntry(id) else null;
    }

    pub fn getTree(self: *const SessionManager) []const SessionEntry {
        return self.entries.items;
    }

    pub fn getChildren(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        parent_id: ?[]const u8,
    ) Error![]const SessionEntry {
        var children = std.ArrayList(SessionEntry).empty;
        errdefer children.deinit(allocator);
        for (self.entries.items) |entry| {
            const entry_parent_id = entry.parentId();
            const matches = if (parent_id) |expected|
                entry_parent_id != null and std.mem.eql(u8, entry_parent_id.?, expected)
            else
                entry_parent_id == null;
            if (matches) try children.append(allocator, entry);
        }
        return children.toOwnedSlice(allocator);
    }

    pub fn getBranch(self: *const SessionManager, allocator: std.mem.Allocator) Error![]const SessionEntry {
        return self.getBranchFrom(allocator, self.leaf_id);
    }

    pub fn getBranchFrom(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) Error![]const SessionEntry {
        var path = std.ArrayList(SessionEntry).empty;
        errdefer path.deinit(allocator);
        var current_id = leaf_id;
        var depth: usize = 0;
        while (current_id) |id| {
            if (depth == max_branch_depth) return error.BranchDepthExceeded;
            const entry = self.findEntry(id) orelse return error.EntryNotFound;
            try path.append(allocator, entry.*);
            current_id = entry.parentId();
            depth += 1;
        }
        std.mem.reverse(SessionEntry, path.items);
        return path.toOwnedSlice(allocator);
    }

    pub fn buildSessionContext(self: *const SessionManager, allocator: std.mem.Allocator) Error!SessionContext {
        const branch_entries = try self.getBranch(allocator);
        defer allocator.free(branch_entries);

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer messages.deinit(allocator);
        var thinking_level: []const u8 = "off";
        var model: ?ModelRef = null;

        for (branch_entries) |entry| {
            switch (entry) {
                .message => |message_entry| {
                    try messages.append(allocator, message_entry.message);
                    if (message_entry.message == .assistant) {
                        model = .{
                            .provider = message_entry.message.assistant.provider,
                            .model_id = message_entry.message.assistant.model,
                        };
                    }
                },
                .thinking_level_change => |thinking| thinking_level = thinking.thinking_level,
                .model_change => |model_change| model = .{
                    .provider = model_change.provider,
                    .model_id = model_change.model_id,
                },
            }
        }

        return .{
            .messages = try messages.toOwnedSlice(allocator),
            .thinking_level = thinking_level,
            .model = model,
        };
    }

    pub fn freeSessionContext(_: *const SessionManager, allocator: std.mem.Allocator, context: SessionContext) void {
        allocator.free(context.messages);
    }

    fn nextBase(self: *SessionManager, timestamp: []const u8) Error!SessionEntry.Base {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        if (self.next_id == std.math.maxInt(u64)) return error.EntryLimitExceeded;
        const id = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{self.next_id});
        errdefer self.allocator.free(id);
        const parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null;
        errdefer if (parent_id) |value| self.allocator.free(value);
        const timestamp_copy = try self.allocator.dupe(u8, timestamp);
        self.next_id += 1;
        return .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp_copy,
        };
    }

    fn appendEntry(self: *SessionManager, entry: SessionEntry) Error![]const u8 {
        const id = entry.id();
        try self.entries.append(self.allocator, entry);
        self.leaf_id = id;
        return id;
    }

    fn findEntry(self: *const SessionManager, id: []const u8) ?*const SessionEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id(), id)) return entry;
        }
        return null;
    }

    fn freeEntry(self: *SessionManager, entry: SessionEntry) void {
        switch (entry) {
            .message => |message| {
                self.freeBase(message.base);
                freeAgentMessage(self.allocator, message.message);
            },
            .thinking_level_change => |thinking| {
                self.freeBase(thinking.base);
                self.allocator.free(thinking.thinking_level);
            },
            .model_change => |model| {
                self.freeBase(model.base);
                self.allocator.free(model.provider);
                self.allocator.free(model.model_id);
            },
        }
    }

    fn freeBase(self: *SessionManager, base: SessionEntry.Base) void {
        self.allocator.free(base.id);
        if (base.parent_id) |parent_id| self.allocator.free(parent_id);
        self.allocator.free(base.timestamp);
    }
};

fn cloneAgentMessage(allocator: std.mem.Allocator, source: agent.AgentMessage) !agent.AgentMessage {
    return switch (source) {
        .user => |message| .{ .user = .{
            .content = switch (message.content) {
                .string => |text| .{ .string = try allocator.dupe(u8, text) },
                .blocks => |blocks| .{ .blocks = try cloneUserContentSlice(allocator, blocks) },
            },
            .timestamp = message.timestamp,
        } },
        .assistant => |message| .{ .assistant = try ai.owned.cloneAssistantMessage(allocator, message) },
        .tool_result => |message| blk: {
            const tool_call_id = try allocator.dupe(u8, message.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, message.tool_name);
            errdefer allocator.free(tool_name);
            const content = try cloneToolResultContentSlice(allocator, message.content);
            errdefer freeToolResultContentSlice(allocator, content);
            const details = if (message.details) |details| try runtime.cloneJsonValue(allocator, details) else null;
            break :blk .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .content = content,
                .details = details,
                .is_error = message.is_error,
                .timestamp = message.timestamp,
            } };
        },
        .custom => |message| blk: {
            const kind = try allocator.dupe(u8, message.kind);
            errdefer allocator.free(kind);
            const payload = try runtime.cloneJsonValue(allocator, message.payload);
            break :blk .{ .custom = .{
                .kind = kind,
                .payload = payload,
                .timestamp = message.timestamp,
            } };
        },
    };
}

fn freeAgentMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => |text| allocator.free(text),
            .blocks => |blocks| freeUserContentSlice(allocator, blocks),
        },
        .assistant => |assistant| ai.owned.freeAssistantMessage(allocator, assistant),
        .tool_result => |tool_result| {
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            freeToolResultContentSlice(allocator, tool_result.content);
            if (tool_result.details) |details| runtime.freeJsonValue(allocator, details);
        },
        .custom => |custom| {
            allocator.free(custom.kind);
            runtime.freeJsonValue(allocator, custom.payload);
        },
    }
}

fn cloneUserContent(allocator: std.mem.Allocator, content: ai.UserContent) !ai.UserContent {
    return switch (content) {
        .text => |text| blk: {
            const text_copy = try allocator.dupe(u8, text.text);
            errdefer allocator.free(text_copy);
            const signature = try cloneOptionalString(allocator, text.text_signature);
            break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
        },
        .image => |image| blk: {
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, image.mime_type);
            break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
        },
    };
}

fn cloneToolResultContent(allocator: std.mem.Allocator, content: ai.ToolResultContent) !ai.ToolResultContent {
    return switch (content) {
        .text => |text| blk: {
            const text_copy = try allocator.dupe(u8, text.text);
            errdefer allocator.free(text_copy);
            const signature = try cloneOptionalString(allocator, text.text_signature);
            break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
        },
        .image => |image| blk: {
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, image.mime_type);
            break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
        },
    };
}

fn cloneUserContentSlice(allocator: std.mem.Allocator, source: []const ai.UserContent) ![]const ai.UserContent {
    const cloned = try allocator.alloc(ai.UserContent, source.len);
    var initialized: usize = 0;
    errdefer {
        freeUserContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = try cloneUserContent(allocator, content);
        initialized += 1;
    }
    return cloned;
}

fn cloneToolResultContentSlice(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultContent,
) ![]const ai.ToolResultContent {
    const cloned = try allocator.alloc(ai.ToolResultContent, source.len);
    var initialized: usize = 0;
    errdefer {
        freeToolResultContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = try cloneToolResultContent(allocator, content);
        initialized += 1;
    }
    return cloned;
}

fn freeUserContentItems(allocator: std.mem.Allocator, source: []const ai.UserContent) void {
    for (source) |content| switch (content) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |value| allocator.free(value);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    };
}

fn freeUserContentSlice(allocator: std.mem.Allocator, source: []const ai.UserContent) void {
    freeUserContentItems(allocator, source);
    allocator.free(source);
}

fn freeToolResultContentItems(allocator: std.mem.Allocator, source: []const ai.ToolResultContent) void {
    for (source) |content| switch (content) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |value| allocator.free(value);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    };
}

fn freeToolResultContentSlice(allocator: std.mem.Allocator, source: []const ai.ToolResultContent) void {
    freeToolResultContentItems(allocator, source);
    allocator.free(source);
}

fn cloneOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

fn assistantMessage(provider: []const u8, model: []const u8) agent.AgentMessage {
    return .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = provider,
        .model = model,
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } };
}

test "new session stores header metadata" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "2026-01-01T00:00:00Z");
    defer manager.deinit();

    try std.testing.expectEqual(@as(u32, current_session_version), manager.header.version);
    try std.testing.expectEqualStrings("session-1", manager.header.id);
    try std.testing.expectEqualStrings("/repo", manager.header.cwd);
    try std.testing.expect(manager.leaf_id == null);
}

test "append entries create parent linked branch" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const first = try manager.appendMessage(userMessage("one"), "t1");
    const second = try manager.appendThinkingLevelChange("high", "t2");

    try std.testing.expectEqualStrings(first, manager.entries.items[1].parentId().?);
    try std.testing.expectEqualStrings(second, manager.leaf_id.?);
}

test "build context follows active leaf" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendModelChange("openai", "gpt", "t1");
    _ = try manager.appendThinkingLevelChange("medium", "t2");
    _ = try manager.appendMessage(userMessage("hello"), "t3");
    _ = try manager.appendMessage(assistantMessage("anthropic", "claude"), "t4");

    const context = try manager.buildSessionContext(std.testing.allocator);
    defer manager.freeSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("medium", context.thinking_level);
    try std.testing.expectEqualStrings("anthropic", context.model.?.provider);
    try std.testing.expectEqualStrings("claude", context.model.?.model_id);
}

test "branching preserves old entries and appends from selected leaf" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("root"), "t1");
    _ = try manager.appendMessage(userMessage("main"), "t2");
    try manager.branch(root);
    _ = try manager.appendMessage(userMessage("branch"), "t3");

    const context = try manager.buildSessionContext(std.testing.allocator);
    defer manager.freeSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("root", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("branch", context.messages[1].user.content.string);
    try std.testing.expectEqual(@as(usize, 3), manager.entries.items.len);
}

test "tree navigation returns entries leaf and children" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("root"), "t1");
    const left = try manager.appendMessage(userMessage("left"), "t2");
    try manager.branch(root);
    const right = try manager.appendMessage(userMessage("right"), "t3");

    try std.testing.expectEqual(@as(usize, 3), manager.getTree().len);
    try std.testing.expectEqualStrings(right, (try manager.getLeafEntry()).?.id());
    try std.testing.expectEqualStrings(left, (try manager.getEntry(left)).id());

    const children = try manager.getChildren(std.testing.allocator, root);
    defer std.testing.allocator.free(children);
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings(left, children[0].id());
    try std.testing.expectEqualStrings(right, children[1].id());
}

test "loaded entries preserve ids parent links and next generated id" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "0000000a",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    _ = try manager.appendLoadedEntry(.{
        .id = "0000000b",
        .parent_id = "0000000a",
        .timestamp = "t2",
        .value = .{ .thinking_level_change = "high" },
    });
    _ = try manager.appendMessage(userMessage("next"), "t3");

    try std.testing.expectEqualStrings("0000000c", manager.entries.items[2].id());
    try std.testing.expectEqualStrings("0000000b", manager.entries.items[2].parentId().?);
}

test "loaded entries reject duplicate ids and missing parents" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    try std.testing.expectError(error.DuplicateEntryId, manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t2",
        .value = .{ .message = userMessage("duplicate") },
    }));
    try std.testing.expectError(error.EntryNotFound, manager.appendLoadedEntry(.{
        .id = "00000002",
        .parent_id = "missing",
        .timestamp = "t2",
        .value = .{ .message = userMessage("orphan") },
    }));
}

test "branch rejects unknown entry" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try std.testing.expectError(error.EntryNotFound, manager.branch("missing"));
}
