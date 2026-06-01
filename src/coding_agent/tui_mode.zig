const runtime = @import("../runtime/root.zig");
const auth_mode = @import("auth_mode.zig");

pub const Options = struct {
    initial_prompt: ?[]const u8 = null,
    resume_session_file: ?[]const u8 = null,
};

pub fn run(process: runtime.Process, options: auth_mode.Options, tui_options: Options) !void {
    _ = process;
    _ = options;
    _ = tui_options;
    return error.TuiProductNotBuilt;
}
