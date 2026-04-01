const std = @import("std");
const types = @import("types.zig");
const api_registry = @import("api_registry.zig");
const event_stream = @import("event_stream.zig");

pub const StreamError = error{
    NoProviderRegistered,
};

/// Stream a response from a model.
/// Returns an AssistantMessageEventStream.
pub fn stream(
    registry: *const api_registry.ApiRegistry,
    model: *const types.Model,
    context: *const types.Context,
    options: ?*const types.StreamOptions,
) StreamError!event_stream.AssistantMessageEventStream {
    const provider = registry.get(model.api) orelse return StreamError.NoProviderRegistered;
    return provider.stream(model, context, options);
}

/// Stream a response and block until complete, returning the final message.
pub fn complete(
    registry: *const api_registry.ApiRegistry,
    model: *const types.Model,
    context: *const types.Context,
    options: ?*const types.StreamOptions,
) StreamError!types.AssistantMessage {
    var s = try stream(registry, model, context, options);
    return s.result();
}

/// Stream with simplified options (includes reasoning level).
pub fn streamSimple(
    registry: *const api_registry.ApiRegistry,
    model: *const types.Model,
    context: *const types.Context,
    options: ?*const types.SimpleStreamOptions,
) StreamError!event_stream.AssistantMessageEventStream {
    const provider = registry.get(model.api) orelse return StreamError.NoProviderRegistered;
    return provider.stream_simple(model, context, options);
}

/// Stream with simplified options and block until complete.
pub fn completeSimple(
    registry: *const api_registry.ApiRegistry,
    model: *const types.Model,
    context: *const types.Context,
    options: ?*const types.SimpleStreamOptions,
) StreamError!types.AssistantMessage {
    var s = try streamSimple(registry, model, context, options);
    return s.result();
}
