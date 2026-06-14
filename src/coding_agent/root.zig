//! Public surface of the coding agent core. Everything outside
//! `src/coding_agent` imports this file, never the internals directly.

const std = @import("std");

pub const auth_mode = @import("auth_mode.zig");
pub const client_protocol = @import("client_protocol.zig");
pub const session_listing = @import("session_listing.zig");
pub const session_runtime = @import("session_runtime.zig");
pub const slash_commands = @import("slash_commands.zig");
pub const wire_protocol = @import("wire_protocol.zig");

// Internal modules, referenced here so `zig build test` reaches their tests.
const AgentSession = @import("AgentSession.zig");
const auth = @import("auth.zig");
const event_drain = @import("event_drain.zig");
const message_policy = @import("message_policy.zig");
const paths = @import("paths.zig");
const queue_mirror = @import("queue_mirror.zig");
const resources = @import("resources.zig");
const runtime_services = @import("runtime_services.zig");
const session_manager = @import("session_manager.zig");
const settings = @import("settings.zig");
const skills = @import("skills.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");
const tool_output_policy = @import("tool_output_policy.zig");
const tools = @import("tools/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = AgentSession;
    _ = auth;
    _ = event_drain;
    _ = message_policy;
    _ = paths;
    _ = queue_mirror;
    _ = resources;
    _ = runtime_services;
    _ = session_manager;
    _ = settings;
    _ = skills;
    _ = system_prompt;
    _ = tool_registry;
    _ = tool_output_policy;
    _ = tools;
}
