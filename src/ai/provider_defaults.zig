const std = @import("std");
const provider_mod = @import("provider.zig");
const provider_registry = @import("provider_registry.zig");
const openai_completions = @import("openai/completions/provider.zig");
const openai_responses = @import("openai/responses/provider.zig");

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    registry: provider_registry.Registry,

    openai_completions_prov: openai_completions.OpenAiCompletionsProvider,
    openai_responses_prov: openai_responses.OpenAiResponsesProvider,

    pub fn init(allocator: std.mem.Allocator) !*Bundle {
        const self = try allocator.create(Bundle);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .registry = provider_registry.Registry.init(allocator),
            .openai_completions_prov = openai_completions.OpenAiCompletionsProvider.init(allocator),
            .openai_responses_prov = openai_responses.OpenAiResponsesProvider.init(allocator),
        };
        errdefer self.registry.deinit();

        try self.registry.register("openai-completions", self.openai_completions_prov.provider(), null);
        try self.registry.register("openai-responses", self.openai_responses_prov.provider(), null);
        return self;
    }

    pub fn deinit(self: *Bundle) void {
        // Registry owns lookup metadata. Concrete provider storage lives in this
        // bundle and must remain valid until after registry teardown.
        self.registry.deinit();
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

test "default provider bundle registers openai providers" {
    const bundle = try Bundle.init(testing.allocator);
    defer bundle.deinit();

    try testing.expect(bundle.registry.get("openai-completions") != null);
    try testing.expect(bundle.registry.get("openai-responses") != null);
}
