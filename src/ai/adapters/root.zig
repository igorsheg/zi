const protocol_api = @import("../protocol.zig");

pub const openai_codex = @import("openai_codex.zig");
pub const openai_compatible = @import("openai_compatible.zig");
pub const openai_responses = @import("openai_responses.zig");

const codex_protocol: openai_codex.OpenAiCodex = .{};
const compatible_protocol: openai_compatible.OpenAiCompatible = .{};
const responses_protocol: openai_responses.OpenAiResponses = .{};

pub const builtin = [_]protocol_api.Protocol{
    compatible_protocol.protocol(),
    codex_protocol.protocol(),
    responses_protocol.protocol(),
};

test {
    _ = @import("openai_codex_test.zig");
    _ = @import("openai_compatible_test.zig");
    _ = @import("openai_responses_test.zig");
}
