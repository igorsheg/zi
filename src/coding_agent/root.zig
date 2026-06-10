//! Public surface of the coding agent core. Everything outside
//! `src/coding_agent` imports this file, never the internals directly.

const std = @import("std");

pub const AgentSession = @import("AgentSession.zig");
pub const auth = @import("auth.zig");
pub const auth_mode = @import("auth_mode.zig");
pub const client_protocol = @import("client_protocol.zig");
pub const paths = @import("paths.zig");
pub const session_listing = @import("session_listing.zig");
pub const session_runtime = @import("session_runtime.zig");
pub const wire_protocol = @import("wire_protocol.zig");

// Internal modules, referenced here so `zig build test` reaches their tests.
const event_drain = @import("event_drain.zig");
const message_policy = @import("message_policy.zig");
const queue_mirror = @import("queue_mirror.zig");
const resources = @import("resources.zig");
const runtime_services = @import("runtime_services.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const settings = @import("settings.zig");
const skills = @import("skills.zig");
const system_prompt = @import("system_prompt.zig");
const tool_registry = @import("tool_registry.zig");
const tool_output_policy = @import("tool_output_policy.zig");
const tools = @import("tools/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = event_drain;
    _ = message_policy;
    _ = queue_mirror;
    _ = resources;
    _ = runtime_services;
    _ = session_manager;
    _ = session_store;
    _ = settings;
    _ = skills;
    _ = system_prompt;
    _ = tool_registry;
    _ = tool_output_policy;
    _ = tools;
}
