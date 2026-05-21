const std = @import("std");

pub const max_settings_file_bytes: usize = 1024 * 1024;
pub const max_models: usize = 256;

pub const Model = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    api: []const u8,
    provider: []const u8,
    base_url: ?[]const u8 = null,
    provider_model: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_tokens: ?u32 = null,
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    models: []Model = &.{},

    pub fn empty(allocator: std.mem.Allocator) Settings {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(settings: *Settings) void {
        settings.arena.deinit();
        settings.* = undefined;
    }
};

pub const JsonSettings = struct {
    defaultProvider: ?[]const u8 = null,
    defaultModel: ?[]const u8 = null,
    models: ?[]JsonModel = null,
};

pub const JsonModel = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    api: []const u8,
    provider: []const u8,
    baseUrl: ?[]const u8 = null,
    providerModel: ?[]const u8 = null,
    contextWindow: ?u32 = null,
    maxTokens: ?u32 = null,
};
