const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");

pub fn cloneModel(allocator: std.mem.Allocator, model: agent_mod.message.Model) !agent_mod.message.Model {
    const id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(id);
    const provider_model = if (model.provider_model) |value| try allocator.dupe(u8, value) else null;
    errdefer if (provider_model) |value| allocator.free(value);
    const name = try allocator.dupe(u8, model.name);
    errdefer allocator.free(name);
    const base_url = try allocator.dupe(u8, model.base_url);
    errdefer allocator.free(base_url);
    const input = try allocator.dupe(ai.protocol.Model.InputType, model.input);
    errdefer allocator.free(input);
    const headers = if (model.headers) |source| try cloneHeaders(allocator, source) else null;
    errdefer if (headers) |owned| freeHeaders(allocator, owned);

    return .{
        .id = id,
        .provider_model = provider_model,
        .name = name,
        .api = model.api,
        .provider = model.provider,
        .base_url = base_url,
        .reasoning = model.reasoning,
        .input = input,
        .cost = model.cost,
        .context_window = model.context_window,
        .max_tokens = model.max_tokens,
        .headers = headers,
        .compat = model.compat,
    };
}

pub fn freeModel(allocator: std.mem.Allocator, model: agent_mod.message.Model) void {
    allocator.free(model.id);
    if (model.provider_model) |value| allocator.free(value);
    allocator.free(model.name);
    allocator.free(model.base_url);
    allocator.free(model.input);
    if (model.headers) |headers| freeHeaders(allocator, headers);
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const ai.protocol.Header) ![]const ai.protocol.Header {
    const out = try allocator.alloc(ai.protocol.Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |header| {
            allocator.free(header.key);
            allocator.free(header.value);
        }
        allocator.free(out);
    }
    for (headers, 0..) |header, i| {
        out[i] = .{
            .key = try allocator.dupe(u8, header.key),
            .value = try allocator.dupe(u8, header.value),
        };
        initialized += 1;
    }
    return out;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const ai.protocol.Header) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
    allocator.free(headers);
}
