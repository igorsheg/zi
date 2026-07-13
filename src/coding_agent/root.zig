//! Public surface of the coding agent core. Everything outside
//! `src/coding_agent` imports this file, never the internals directly.

const std = @import("std");

pub const AgentSession = @import("AgentSession.zig");
pub const ExtensionHost = @import("ExtensionHost.zig");
pub const auth_mode = @import("auth_mode.zig");
pub const file_completion = @import("file_completion.zig");
pub const failure_display = @import("failure_display.zig");
pub const runtime_services = @import("runtime_services.zig");
pub const session_bootstrap = @import("session_bootstrap.zig");
pub const session_listing = @import("session_listing.zig");
pub const session_manager = @import("session_manager.zig");
pub const settings = @import("settings.zig");
pub const slash_commands = @import("slash_commands.zig");
pub const tool_metadata = @import("tool_metadata.zig");

// Internal modules, referenced here so `zig build test` reaches their tests.
const auth = @import("auth.zig");
const extension_host_asset = @import("extension_host_asset.zig");
comptime {
    _ = extension_host_asset.zi_extension_host_bundle;
}
const message_policy = @import("message_policy.zig");
const paths = @import("paths.zig");
const resources = @import("resources.zig");
const skills = @import("skills.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");
const tool_output_policy = @import("tool_output_policy.zig");
const tools = @import("tools/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = AgentSession;
    _ = ExtensionHost;
    _ = auth;
    _ = extension_host_asset;
    _ = failure_display;
    _ = file_completion;
    _ = message_policy;
    _ = paths;
    _ = resources;
    _ = runtime_services;
    _ = session_manager;
    _ = settings;
    _ = skills;
    _ = system_prompt;
    _ = tool_metadata;
    _ = tool_registry;
    _ = tool_output_policy;
    _ = tools;
}
