const std = @import("std");
const lua_runtime = @import("../extensions/lua_runtime.zig");
const resource_types = @import("../resources/types.zig");

const c = lua_runtime.c;

pub const max_request_bytes: usize = 1024 * 1024;
pub const max_response_bytes: usize = 1024 * 1024;
pub const max_html_bytes: usize = 4 * 1024 * 1024;
pub const max_window_id_bytes: usize = 128;
pub const max_command_name_bytes: usize = 128;
pub const max_host_line_bytes: usize = 2 * 1024 * 1024;

pub const EventDispatcher = struct {
    ptr: *anyopaque,
    wake_fn: *const fn (ptr: *anyopaque) bool,

    pub fn wake(self: EventDispatcher) bool {
        return self.wake_fn(self.ptr);
    }

    pub fn eql(self: EventDispatcher, other: EventDispatcher) bool {
        return self.ptr == other.ptr and @intFromPtr(self.wake_fn) == @intFromPtr(other.wake_fn);
    }
};

pub const Options = struct {
    id: []const u8,
    title: []const u8 = "",
    width: u32 = 800,
    height: u32 = 600,
    floating: bool = false,
    asset_root: ?[]const u8 = null,
    entry: []const u8 = "index.html",
    html: ?[]const u8 = null,
    commands: []Command = &.{},
    provenance: ?resource_types.ExtensionProvenance = null,
};

pub const Command = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    handler_ref: c_int,
};
