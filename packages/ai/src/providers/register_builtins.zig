const std = @import("std");
const types = @import("../types.zig");
const api_registry = @import("../api_registry.zig");
const event_stream = @import("../event_stream.zig");

/// Register all built-in API providers into the registry.
/// This must be called once at initialization.
pub fn registerBuiltInProviders(registry: *api_registry.ApiRegistry) !void {
    // Each provider maps an Api enum to stream/streamSimple function pointers.
    // Since the actual streaming implementations are in each provider module,
    // we create wrapper functions that delegate to them.

    // For now, register placeholder implementations that return error events.
    // As providers are fully implemented with HTTP streaming, these will be
    // replaced with real implementations.

    // Anthropic
    try registry.register(.{
        .api = .anthropic_messages,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // OpenAI Completions
    try registry.register(.{
        .api = .openai_completions,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // OpenAI Responses
    try registry.register(.{
        .api = .openai_responses,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Azure OpenAI Responses
    try registry.register(.{
        .api = .azure_openai_responses,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // OpenAI Codex Responses
    try registry.register(.{
        .api = .openai_codex_responses,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Google Generative AI
    try registry.register(.{
        .api = .google_generative_ai,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Google Gemini CLI
    try registry.register(.{
        .api = .google_gemini_cli,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Google Vertex
    try registry.register(.{
        .api = .google_vertex,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Mistral
    try registry.register(.{
        .api = .mistral_conversations,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });

    // Bedrock
    try registry.register(.{
        .api = .bedrock_converse_stream,
        .stream = &stubStream,
        .stream_simple = &stubStreamSimple,
    });
}

/// Reset registry to only built-in providers
pub fn resetProviders(registry: *api_registry.ApiRegistry) !void {
    registry.clear();
    try registerBuiltInProviders(registry);
}

// Stub stream function - the actual implementation will be in each provider module
// once HTTP streaming is fully wired up
fn stubStream(_: *const types.Model, _: *const types.Context, _: ?*const types.StreamOptions) event_stream.AssistantMessageEventStream {
    // In a real implementation, this would create an event stream and
    // spawn the provider's HTTP request + SSE parsing.
    // For now, this is a placeholder.
    @panic("stub: provider streaming not yet connected");
}

fn stubStreamSimple(_: *const types.Model, _: *const types.Context, _: ?*const types.SimpleStreamOptions) event_stream.AssistantMessageEventStream {
    @panic("stub: provider streaming not yet connected");
}
