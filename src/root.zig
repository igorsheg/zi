pub const ai = @import("ai/root.zig");
pub const agent = @import("agent/root.zig");
pub const coding_agent = @import("coding_agent/root.zig");
pub const smol = @import("smol/root.zig");

test {
    _ = ai;
    _ = agent;
    _ = coding_agent;
    _ = smol;
}
