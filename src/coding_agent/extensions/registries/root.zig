//! Registries module — re-exports the four storage primitives that
//! every ExtensionRunner generation owns. Importing this file pulls
//! the full set; importing individual files works too.

pub const tool = @import("tool_registry.zig");
pub const event = @import("event_registry.zig");
pub const command = @import("command_registry.zig");
pub const provider = @import("provider_queue.zig");

pub const ToolRegistry = tool.ToolRegistry;
pub const EventRegistry = event.EventRegistry;
pub const CommandRegistry = command.CommandRegistry;
pub const ProviderQueue = provider.ProviderQueue;

test {
    @import("std").testing.refAllDecls(@This());
}
