pub const auth = @import("auth.zig");
pub const credential = @import("credential.zig");
pub const failure = @import("failure.zig");
pub const message = @import("message.zig");
pub const model = @import("model.zig");
pub const model_catalog = @import("model_catalog.zig");
pub const model_catalog_snapshot = @import("model_catalog_snapshot.zig");
pub const models = @import("Models.zig");
pub const oauth = @import("oauth.zig");
pub const settings = @import("settings.zig");
pub const stream = @import("stream.zig");
pub const usage = @import("usage.zig");
pub const transport = @import("transport.zig");
pub const provider = @import("provider.zig");
pub const protocol_api = @import("protocol.zig");
pub const adapters = @import("adapters/root.zig");
pub const providers = @import("providers/root.zig");
const openai_chat_wire = @import("wire/openai_chat.zig");
const openai_responses_wire = @import("wire/openai_responses.zig");
const sse_wire = @import("wire/sse.zig");
/// Stateless wire codecs. Transport-bound composition lives in adapters.
pub const wire = struct {
    pub const openai_chat = openai_chat_wire;
    pub const openai_responses = openai_responses_wire;
    pub const sse = sse_wire;
};
pub const transport_testing = @import("transport/fake.zig");
pub const testing = @import("testing.zig");

pub const Credential = credential.Credential;
pub const ModelAuth = auth.ModelAuth;
pub const Protocol = protocol_api.Protocol;
pub const Models = models;
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
    _ = auth;
    _ = credential;
    _ = wire.openai_chat;
    _ = wire.openai_responses;
    _ = wire.sse;
    _ = model_catalog;
    _ = model_catalog_snapshot;
    _ = models;
    _ = oauth;
    _ = provider;
    _ = protocol_api;
    _ = adapters;
    _ = providers;
    _ = transport;
    _ = transport_testing;
    _ = testing;
}
