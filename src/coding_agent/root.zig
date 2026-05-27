pub const AgentSession = @import("AgentSession.zig");
pub const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
pub const paths = @import("paths.zig");
pub const resources = @import("resources.zig");
pub const session_manager = @import("session_manager.zig");
pub const session_store = @import("session_store.zig");
pub const skills = @import("skills.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const tool_registry = @import("tool_registry.zig");
pub const tools = @import("tools/root.zig");

pub const PersistencePaths = paths.PersistencePaths;
pub const ContextFile = resources.ContextFile;
pub const OwnedContextFiles = resources.OwnedContextFiles;
pub const OwnedPromptFile = resources.OwnedPromptFile;
pub const PromptFile = resources.PromptFile;
pub const PromptResources = resources.PromptResources;
pub const RuntimeHost = AgentSessionRuntimeHost;
pub const SessionManager = session_manager.SessionManager;
pub const SessionHeader = session_manager.SessionHeader;
pub const SessionEntry = session_manager.SessionEntry;
pub const SessionContext = session_manager.SessionContext;
pub const SessionStore = session_store.SessionStore;
pub const Skill = skills.Skill;
pub const OwnedSkills = skills.OwnedSkills;
pub const ToolDefinition = tool_registry.ToolDefinition;
pub const ToolRegistry = tool_registry.ToolRegistry;
pub const EditTool = tools.EditTool;
pub const FileMutationQueue = tools.FileMutationQueue;
pub const ReadTool = tools.ReadTool;
pub const WriteTool = tools.WriteTool;
pub const ToolSnippet = system_prompt.ToolSnippet;

pub const current_session_version = session_manager.current_session_version;
pub const discoverAppendSystemPromptFile = resources.discoverAppendSystemPromptFile;
pub const discoverSystemPromptFile = resources.discoverSystemPromptFile;
pub const loadProjectContextFiles = resources.loadProjectContextFiles;
pub const loadSkills = skills.loadSkills;
pub const buildSystemPrompt = system_prompt.build;

pub fn testsReachable() void {
    _ = AgentSession;
    _ = AgentSessionRuntimeHost;
    _ = paths;
    _ = resources;
    _ = session_manager;
    _ = session_store;
    _ = skills;
    _ = system_prompt;
    _ = tool_registry;
    _ = tools;
}

test {
    _ = AgentSession;
    _ = AgentSessionRuntimeHost;
    _ = paths;
    _ = resources;
    _ = session_manager;
    _ = session_store;
    _ = skills;
    _ = system_prompt;
    _ = tool_registry;
    _ = tools;
}
