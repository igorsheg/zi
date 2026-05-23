pub const protocol = @import("protocol.zig");

pub const Api = protocol.Api;
pub const Provider = protocol.Provider;
pub const Timestamp = protocol.Timestamp;
pub const ThinkingLevel = protocol.ThinkingLevel;
pub const CacheRetention = protocol.CacheRetention;
pub const Transport = protocol.Transport;
pub const ProviderResponse = protocol.ProviderResponse;
pub const StreamOptions = protocol.StreamOptions;
pub const ThinkingBudgets = protocol.ThinkingBudgets;
pub const SimpleStreamOptions = protocol.SimpleStreamOptions;
pub const TextSignatureV1 = protocol.TextSignatureV1;
pub const TextContent = protocol.TextContent;
pub const ThinkingContent = protocol.ThinkingContent;
pub const ImageContent = protocol.ImageContent;
pub const ToolCall = protocol.ToolCall;
pub const Usage = protocol.Usage;
pub const StopReason = protocol.StopReason;
pub const UserContent = protocol.UserContent;
pub const AssistantContent = protocol.AssistantContent;
pub const ToolResultContent = protocol.ToolResultContent;
pub const UserMessage = protocol.UserMessage;
pub const AssistantMessage = protocol.AssistantMessage;
pub const ToolResultMessage = protocol.ToolResultMessage;
pub const Message = protocol.Message;
pub const Tool = protocol.Tool;
pub const Context = protocol.Context;
pub const AssistantMessageEvent = protocol.AssistantMessageEvent;
pub const DoneReason = protocol.DoneReason;
pub const ErrorReason = protocol.ErrorReason;
pub const AssistantMessageEventStream = protocol.AssistantMessageEventStream;
pub const AssistantMessageEventSink = protocol.AssistantMessageEventSink;

test {
    _ = protocol;
}
