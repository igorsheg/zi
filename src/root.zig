const ai = @import("ai/root.zig");
const agent = @import("agent/root.zig");
const app_info = @import("app_info.zig");
const coding_agent = @import("coding_agent/root.zig");
const cli = @import("cli/root.zig");
const runtime = @import("runtime/root.zig");
const tui = @import("tui/root.zig");
const print_mode = @import("frontends/print/print_mode.zig");

test {
    _ = ai;
    _ = agent;
    _ = app_info;
    _ = coding_agent;
    _ = cli;
    _ = runtime;
    _ = tui;
    _ = print_mode;
}
