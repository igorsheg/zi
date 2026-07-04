const ai = @import("ai/root.zig");
const agent = @import("agent/root.zig");
const app_info = @import("app_info.zig");
const coding_agent = @import("coding_agent/root.zig");
const frontend_print = @import("frontends/print/print_mode.zig");
const frontend_rpc = @import("frontends/rpc/stdio.zig");
const frontend_tui = @import("frontends/tui/interactive.zig");
const frontend_tui_failure_text = @import("frontends/tui/failure_text.zig");
const frontend_tui_frame_loop = @import("frontends/tui/frame_loop.zig");
const frontend_tui_pickers = @import("frontends/tui/pickers.zig");
const frontend_tui_view_diff = @import("frontends/tui/view_diff.zig");
const frontend_tui_worker = @import("frontends/tui/worker.zig");
const runtime = @import("runtime/root.zig");
const tui = @import("tui/root.zig");

test {
    _ = ai;
    _ = agent;
    _ = app_info;
    _ = coding_agent;
    _ = frontend_print;
    _ = frontend_rpc;
    _ = frontend_tui;
    _ = frontend_tui_failure_text;
    _ = frontend_tui_frame_loop;
    _ = frontend_tui_pickers;
    _ = frontend_tui_view_diff;
    _ = frontend_tui_worker;
    _ = runtime;
    _ = tui;
}
