const ai = @import("../ai/root.zig");

pub const AssistantMessage = ai.protocol.AssistantMessage;
pub const AssistantMessageEvent = ai.protocol.AssistantMessageEvent;
pub const Model = ai.protocol.Model;
pub const ToolCall = ai.protocol.ToolCall;
pub const ToolResultMessage = ai.protocol.ToolResultMessage;
pub const AgentMessage = ai.protocol.AgentMessage;

pub const AgentInput = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: []const @import("tool.zig").AgentTool = &.{}, // ziglint-ignore: Z028
};
