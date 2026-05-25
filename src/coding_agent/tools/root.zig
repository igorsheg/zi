pub const read = @import("read.zig");

pub const ReadTool = read.ReadTool;

pub fn testsReachable() void {
    _ = read;
}

test {
    _ = read;
}
