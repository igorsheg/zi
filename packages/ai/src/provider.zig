const std = @import("std");
const protocol = @import("protocol.zig");

/// Callback invoked for each streaming event.
pub const EventCallback = *const fn (event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void;

/// Provider interface — vtable-based polymorphism.
/// Matches pi-mono's ApiProvider contract: stream and streamSimple.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stream a response. Must NOT return errors for request/runtime failures.
        /// Failures are encoded as error events via the callback.
        /// Terminal event (done or error) must always be emitted.
        stream: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.StreamOptions,
            callback: EventCallback,
            callback_ctx: ?*anyopaque,
        ) void,

        /// Stream with simplified options (includes reasoning level).
        stream_simple: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.SimpleStreamOptions,
            callback: EventCallback,
            callback_ctx: ?*anyopaque,
        ) void,

        /// Provider name for diagnostics.
        get_name: *const fn (ptr: *anyopaque) []const u8,

        /// Clean up resources.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn stream(self: Provider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: EventCallback, callback_ctx: ?*anyopaque) void {
        self.vtable.stream(self.ptr, allocator, model, context, options, callback, callback_ctx);
    }

    pub fn streamSimple(self: Provider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.SimpleStreamOptions, callback: EventCallback, callback_ctx: ?*anyopaque) void {
        self.vtable.stream_simple(self.ptr, allocator, model, context, options, callback, callback_ctx);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.get_name(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

/// API registry — maps Api to Provider.
/// Matches pi-mono's registerApiProvider/getApiProvider/unregisterApiProviders.
pub const Registry = struct {
    // Use StringHashMap since Api is union(enum) with custom string variant
    // We need to map by the api identifier string
    providers: std.StringHashMap(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        provider: Provider,
        source_id: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .providers = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit();
    }

    /// Register a provider for an API identifier.
    pub fn register(self: *Registry, api: []const u8, prov: Provider, source_id: ?[]const u8) !void {
        try self.providers.put(api, .{ .provider = prov, .source_id = source_id });
    }

    /// Look up provider by API identifier.
    pub fn get(self: *const Registry, api: []const u8) ?Provider {
        const entry = self.providers.get(api) orelse return null;
        return entry.provider;
    }

    /// Unregister all providers with a given source_id.
    pub fn unregisterBySource(self: *Registry, source_id: []const u8) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source_id) |sid| {
                if (std.mem.eql(u8, sid, source_id)) {
                    to_remove.append(entry.key_ptr.*) catch continue;
                }
            }
        }
        for (to_remove.items) |key| {
            _ = self.providers.remove(key);
        }
    }

    /// Get all registered providers. Caller owns the returned slice.
    /// pi-mono equivalent: getApiProviders()
    pub fn getAll(self: *const Registry, allocator: std.mem.Allocator) ![]Provider {
        const count = self.providers.count();
        const result = try allocator.alloc(Provider, count);
        var it = self.providers.valueIterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            result[i] = entry.provider;
            i += 1;
        }
        return result;
    }

    /// Clear all providers.
    pub fn clear(self: *Registry) void {
        self.providers.clearRetainingCapacity();
    }
};

/// Convert Api to its string identifier for registry lookup.
pub fn apiToString(api: protocol.Api) []const u8 {
    return switch (api) {
        .openai_completions => "openai-completions",
        .mistral_conversations => "mistral-conversations",
        .openai_responses => "openai-responses",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex_responses => "openai-codex-responses",
        .anthropic_messages => "anthropic-messages",
        .bedrock_converse_stream => "bedrock-converse-stream",
        .google_generative_ai => "google-generative-ai",
        .google_gemini_cli => "google-gemini-cli",
        .google_vertex => "google-vertex",
        .custom => |s| s,
    };
}
