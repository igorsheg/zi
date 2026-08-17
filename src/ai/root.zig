pub const failure = @import("failure.zig");
pub const message = @import("message.zig");
pub const model = @import("model.zig");
pub const settings = @import("settings.zig");
pub const stream = @import("stream.zig");
pub const usage = @import("usage.zig");
pub const transport = @import("transport.zig");
pub const provider = @import("provider.zig");
pub const providers = @import("providers/root.zig");
const openai_chat_api = @import("protocol/openai_chat.zig");
const openai_responses_api = @import("protocol/openai_responses.zig");
const sse_api = @import("protocol/sse.zig");
pub const protocol = struct {
    pub const openai_chat = openai_chat_api;
    pub const openai_responses = openai_responses_api;
    pub const sse = sse_api;
};
pub const transport_testing = @import("transport/fake.zig");
pub const testing = @import("testing.zig");

pub const Model = model.Model;
pub const ModelError = model.ModelError;
pub const ModelRequest = model.ModelRequest;
pub const ModelIdentity = model.ModelIdentity;
pub const ModelProfile = model.ModelProfile;
pub const ModelSettings = settings.ModelSettings;
pub const Message = message.Message;
pub const ResponseMessage = message.ResponseMessage;
pub const ResponsePart = message.ResponsePart;
pub const ToolDefinition = message.ToolDefinition;
pub const StreamSink = stream.StreamSink;
pub const StreamEvent = stream.StreamEvent;
pub const OwnedResponse = model.OwnedResponse;
pub const Usage = usage.Usage;

test {
    _ = protocol.openai_chat;
    _ = protocol.openai_responses;
    _ = protocol.sse;
    _ = provider;
    _ = providers;
    _ = transport;
    _ = transport_testing;
    _ = testing;
}
