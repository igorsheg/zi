const std = @import("std");

pub const Action = enum {
    run,
    help,
    version,
    list_models,

    pub fn detect(argv: []const []const u8) Action {
        var saw_help = false;
        var saw_list_models = false;

        for (argv) |arg| {
            if (eql(arg, "--version") or eql(arg, "-v")) return .version;
            if (eql(arg, "--list-models")) saw_list_models = true;
            if (eql(arg, "--help") or eql(arg, "-h")) saw_help = true;
        }

        if (saw_list_models) return .list_models;
        if (saw_help) return .help;
        return .run;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "action detection prefers specific utility actions over help fallback" {
    try std.testing.expectEqual(Action.run, Action.detect(&.{"hello"}));
    try std.testing.expectEqual(Action.help, Action.detect(&.{ "--help", "hello" }));
    try std.testing.expectEqual(Action.list_models, Action.detect(&.{ "--help", "--list-models" }));
    try std.testing.expectEqual(Action.version, Action.detect(&.{ "--help", "--list-models", "--version" }));
}
