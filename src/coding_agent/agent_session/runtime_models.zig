const std = @import("std");
const ai = @import("../../ai/root.zig");
const protocol = @import("../../agent3/types.zig");
const resolve_mod = @import("../resolve.zig");

pub fn modelsGet(self: anytype, allocator: std.mem.Allocator) ?std.json.Value {
    const registry = self.model_registry orelse return null;
    var arr = std.json.Array.init(allocator);
    for (registry.getAll()) |model| arr.append(modelJson(allocator, model) catch return null) catch return null;
    return .{ .array = arr };
}

pub fn modelGet(self: anytype, allocator: std.mem.Allocator, model_ref: []const u8) ?std.json.Value {
    const model = resolveModelRef(self, model_ref) orelse return null;
    return modelJson(allocator, model) catch null;
}

pub fn resolveModelRef(self: anytype, model_ref: []const u8) ?ai.protocol.Model {
    const registry = self.model_registry orelse return null;
    const parsed = resolve_mod.parseModelPattern(self.allocator, model_ref, registry.getAll(), .{});
    return parsed.model orelse registry.findByProviderName(ai.json_util.providerToString(self.agent.modelValue().provider), model_ref);
}

fn modelJson(allocator: std.mem.Allocator, model: protocol.Model) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put(try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, model.id) });
    try obj.put(try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, model.name) });
    const provider = ai.json_util.providerToString(model.provider);
    try obj.put(try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, provider) });
    const api = ai.provider.apiToString(model.api);
    try obj.put(try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, api) });
    try obj.put(try allocator.dupe(u8, "context_window"), .{ .integer = @intCast(model.context_window) });
    try obj.put(try allocator.dupe(u8, "max_tokens"), .{ .integer = @intCast(model.max_tokens) });
    try obj.put(try allocator.dupe(u8, "reasoning"), .{ .bool = model.reasoning });
    return .{ .object = obj };
}
