const std = @import("std");

pub const FocusTarget = enum {
    composer,
    surface,
};

pub const RunState = enum {
    idle,
    active,
};

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    meta: bool = false,

    fn hasNonTextModifier(self: Modifiers) bool {
        return self.ctrl or self.alt or self.super or self.meta;
    }
};

pub const Key = struct {
    codepoint: ?u21 = null,
    text: ?[]const u8 = null,
    enter: bool = false,
    backspace: bool = false,
    escape: bool = false,
    modifiers: Modifiers = .{},
};

pub const Intent = union(enum) {
    none,
    quit,
    cancel_run,
    dismiss_focused_surface,
    submit_composer,
    composer_backspace,
    composer_insert: []const u8,
};

pub const Router = struct {
    focus: FocusTarget = .composer,

    pub fn route(self: Router, key: Key, run_state: RunState) Intent {
        if (key.codepoint == 'c' and key.modifiers.ctrl) return .quit;
        if (key.escape and run_state == .active) return .cancel_run;
        if (key.escape and self.focus == .surface) return .dismiss_focused_surface;

        return switch (self.focus) {
            .composer => routeComposer(key, run_state),
            .surface => .none,
        };
    }
};

fn routeComposer(key: Key, run_state: RunState) Intent {
    if (key.enter) {
        if (run_state == .active) return .none;
        return .submit_composer;
    }
    if (key.backspace) return .composer_backspace;
    if (key.modifiers.hasNonTextModifier()) return .none;
    if (key.text) |text| return .{ .composer_insert = text };
    return .none;
}

test "input router maps global quit before focused input" {
    const router: Router = .{};
    try std.testing.expectEqual(Intent.quit, router.route(.{
        .codepoint = 'c',
        .text = "c",
        .modifiers = .{ .ctrl = true },
    }, .idle));
}

test "input router maps escape to run cancellation only while active" {
    const router: Router = .{};

    try std.testing.expectEqual(Intent.none, router.route(.{ .escape = true }, .idle));
    try std.testing.expectEqual(Intent.cancel_run, router.route(.{ .escape = true }, .active));
}

test "input router maps escape to focused surface dismiss when idle" {
    const router: Router = .{ .focus = .surface };

    try std.testing.expectEqual(Intent.dismiss_focused_surface, router.route(.{ .escape = true }, .idle));
    try std.testing.expectEqual(Intent.cancel_run, router.route(.{ .escape = true }, .active));
}

test "input router maps composer editing without mutating app state" {
    const router: Router = .{};

    try std.testing.expectEqual(Intent.submit_composer, router.route(.{ .enter = true }, .idle));
    try std.testing.expectEqual(Intent.none, router.route(.{ .enter = true }, .active));
    try std.testing.expectEqual(Intent.composer_backspace, router.route(.{ .backspace = true }, .idle));

    const intent = router.route(.{ .text = "hello" }, .idle);
    try std.testing.expect(intent == .composer_insert);
    try std.testing.expectEqualStrings("hello", intent.composer_insert);
}

test "input router does not send text to composer when another surface owns focus" {
    const router: Router = .{ .focus = .surface };

    try std.testing.expectEqual(Intent.none, router.route(.{ .text = "x" }, .idle));
    try std.testing.expectEqual(Intent.none, router.route(.{ .backspace = true }, .idle));
    try std.testing.expectEqual(Intent.none, router.route(.{ .enter = true }, .idle));
}
