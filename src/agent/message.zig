const ai = @import("../ai/root.zig");
const json_value = @import("../json/value.zig");

pub const AssistantMessage = ai.protocol.AssistantMessage;
pub const AssistantMessageEvent = ai.protocol.AssistantMessageEvent;
pub const Model = ai.protocol.Model;
pub const ToolCall = ai.protocol.ToolCall;
pub const ToolResultMessage = ai.protocol.ToolResultMessage;

pub const AgentMessage = union(enum) {
    user: ai.protocol.UserMessage,
    assistant: ai.protocol.AssistantMessage,
    tool_result: ai.protocol.ToolResultMessage,
    compaction_summary: CompactionSummary,
    branch_summary: BranchSummary,
    custom: Custom,

    pub const CompactionSummary = struct {
        summary: []const u8,
        tokens_before: u64,
        timestamp: i64,
    };

    pub const BranchSummary = struct {
        summary: []const u8,
        from_id: []const u8,
        timestamp: i64,
    };

    pub const CustomContent = union(enum) {
        text: []const u8,
        blocks: []const ai.protocol.UserMessage.UserMessageContent.Block,
    };

    pub const Custom = struct {
        custom_type: []const u8,
        content: CustomContent,
        display: bool = false,
        details: ?json_value.OwnedValue = null,
        timestamp: i64,
    };
};

pub const AgentInput = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: []const @import("tool.zig").AgentTool = &.{},
};
