const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");

pub const Kind = enum {
    function,
    table,
};

pub const InstallFn = *const fn (*lua_runtime.LuaState, *runner_mod.ExtensionRunner) void;

pub const Export = struct {
    name: [:0]const u8,
    kind: Kind,
    install: InstallFn,
};
