const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    msg_allocator: std.mem.Allocator,
};
