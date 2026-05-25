pub const paths = @import("paths.zig");
pub const resources = @import("resources.zig");
pub const session_manager = @import("session_manager.zig");
pub const session_store = @import("session_store.zig");
pub const skills = @import("skills.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const tools = @import("tools/root.zig");

pub const PersistencePaths = paths.PersistencePaths;
pub const ContextFile = resources.ContextFile;
pub const OwnedContextFiles = resources.OwnedContextFiles;
pub const OwnedPromptFile = resources.OwnedPromptFile;
pub const PromptFile = resources.PromptFile;
pub const PromptResources = resources.PromptResources;
pub const SessionManager = session_manager.SessionManager;
pub const SessionHeader = session_manager.SessionHeader;
pub const SessionEntry = session_manager.SessionEntry;
pub const SessionContext = session_manager.SessionContext;
pub const SessionStore = session_store.SessionStore;
pub const Skill = skills.Skill;
pub const OwnedSkills = skills.OwnedSkills;
pub const ReadTool = tools.ReadTool;
pub const ToolSnippet = system_prompt.ToolSnippet;

pub const current_session_version = session_manager.current_session_version;
pub const discoverAppendSystemPromptFile = resources.discoverAppendSystemPromptFile;
pub const discoverSystemPromptFile = resources.discoverSystemPromptFile;
pub const loadProjectContextFiles = resources.loadProjectContextFiles;
pub const loadSkills = skills.loadSkills;
pub const buildSystemPrompt = system_prompt.build;

pub fn testsReachable() void {
    _ = paths;
    _ = resources;
    _ = session_manager;
    _ = session_store;
    _ = skills;
    _ = system_prompt;
    _ = tools;
}

test {
    _ = paths;
    _ = resources;
    _ = session_manager;
    _ = session_store;
    _ = skills;
    _ = system_prompt;
    _ = tools;
}
