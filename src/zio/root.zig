const std = @import("std");

pub const Io = std.Io;

pub const cancel = @import("cancel.zig");
pub const queue = @import("queue.zig");
pub const task = @import("task.zig");
pub const worker = @import("worker.zig");
pub const process = @import("process.zig");
pub const file = @import("file.zig");

// zio is a portability bunker, not a playground. Public callers get std.Io-shaped APIs;
// platform filth stays behind these walls and comes out already washed.
pub const default_io: Io = std.Options.debug_io;
