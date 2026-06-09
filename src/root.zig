const ai = @import("ai/root.zig");
const agent = @import("agent/root.zig");
const coding_agent = @import("coding_agent/root.zig");
const frontend_print = @import("frontends/print/print_mode.zig");
const frontend_rpc = @import("frontends/rpc/stdio.zig");
const runtime = @import("runtime/root.zig");
const tui = @import("tui/root.zig");

test {
    _ = ai;
    _ = agent;
    _ = coding_agent;
    _ = frontend_print;
    _ = frontend_rpc;
    _ = runtime;
    _ = tui;
}
