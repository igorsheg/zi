const agent_protocol = @import("../agent/root.zig").protocol;
const transcript_mod = @import("transcript.zig");
const tool_display_mod = @import("tool_display.zig");
const editor_iface_mod = @import("editor_iface.zig");
const projection = @import("conversation_projection.zig");

const Transcript = transcript_mod.Transcript;
const ToolRendererResolver = tool_display_mod.ToolRendererResolver;
const EditorInterface = editor_iface_mod.EditorInterface;

pub const ApplyOptions = projection.RebuildOptions;

pub fn seedEditorHistory(editor: EditorInterface, messages: []const agent_protocol.AgentMessage) void {
    projection.seedEditorHistory(editor, messages);
}

pub fn applySessionMessages(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    messages: []const agent_protocol.AgentMessage,
    options: ApplyOptions,
) void {
    projection.applySessionMessages(transcript, resolver, messages, options);
}
