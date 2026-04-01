const std = @import("std");
const types = @import("types.zig");
const event_stream = @import("event_stream.zig");

/// Stream function signature - takes model, context, options, returns an event stream
pub const StreamFn = *const fn (*const types.Model, *const types.Context, ?*const types.StreamOptions) event_stream.AssistantMessageEventStream;

/// SimpleStream function signature
pub const SimpleStreamFn = *const fn (*const types.Model, *const types.Context, ?*const types.SimpleStreamOptions) event_stream.AssistantMessageEventStream;

/// API provider interface
pub const ApiProvider = struct {
    api: types.Api,
    stream: StreamFn,
    stream_simple: SimpleStreamFn,
    source_id: ?[]const u8 = null,
};

/// Global API provider registry
pub const ApiRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.AutoHashMap(types.Api, ApiProvider),

    pub fn init(allocator: std.mem.Allocator) ApiRegistry {
        return ApiRegistry{
            .allocator = allocator,
            .providers = std.AutoHashMap(types.Api, ApiProvider).init(allocator),
        };
    }

    pub fn deinit(self: *ApiRegistry) void {
        self.providers.deinit();
    }

    /// Register an API provider
    pub fn register(self: *ApiRegistry, provider: ApiProvider) !void {
        try self.providers.put(provider.api, provider);
    }

    /// Get the provider for an API
    pub fn get(self: *const ApiRegistry, api: types.Api) ?ApiProvider {
        return self.providers.get(api);
    }

    /// Get all registered providers. Caller owns returned slice.
    pub fn getAll(self: *const ApiRegistry, allocator: std.mem.Allocator) ![]ApiProvider {
        const count = self.providers.count();
        const result = try allocator.alloc(ApiProvider, count);
        var it = self.providers.valueIterator();
        var i: usize = 0;
        while (it.next()) |provider| {
            result[i] = provider.*;
            i += 1;
        }
        return result;
    }

    /// Unregister all providers with a given source_id
    pub fn unregisterBySource(self: *ApiRegistry, source_id: []const u8) void {
        // Collect keys to remove first (can't iterate and remove simultaneously)
        var to_remove = std.ArrayList(types.Api).init(self.allocator);
        defer to_remove.deinit();

        var it = self.providers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source_id) |sid| {
                if (std.mem.eql(u8, sid, source_id)) {
                    to_remove.append(entry.key_ptr.*) catch continue;
                }
            }
        }

        // Now remove them
        for (to_remove.items) |api| {
            _ = self.providers.remove(api);
        }
    }

    /// Clear all registered providers
    pub fn clear(self: *ApiRegistry) void {
        self.providers.clearRetainingCapacity();
    }
};
