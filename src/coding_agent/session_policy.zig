const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const model_memory = @import("model_memory.zig");

pub const Init = struct {
    system_prompt: []const u8 = "",
    model: ?agent_mod.message.Model = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,
};

pub const SessionPolicy = struct {
    arena: std.heap.ArenaAllocator,
    system_prompt: []const u8,
    model: ?agent_mod.message.Model,
    reasoning: ?ai.protocol.ThinkingLevel,

    pub fn init(allocator: std.mem.Allocator, policy: Init) !SessionPolicy {
        var self: SessionPolicy = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .system_prompt = &.{},
            .model = null,
            .reasoning = policy.reasoning,
        };
        errdefer self.deinit();
        const a = self.arena.allocator();
        self.system_prompt = try a.dupe(u8, policy.system_prompt);
        self.model = if (policy.model) |model| try model_memory.cloneModel(a, model) else null;
        return self;
    }

    pub fn deinit(self: *SessionPolicy) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn replaceModel(self: *SessionPolicy, allocator: std.mem.Allocator, model: agent_mod.message.Model) !void {
        const next = try SessionPolicy.init(allocator, .{
            .system_prompt = self.system_prompt,
            .model = model,
            .reasoning = self.reasoning,
        });
        self.deinit();
        self.* = next;
    }

    pub fn setReasoning(self: *SessionPolicy, reasoning: ?ai.protocol.ThinkingLevel) void {
        self.reasoning = reasoning;
    }
};
