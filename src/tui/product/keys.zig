const input_mod = @import("input.zig");

pub const KeyAction = union(enum) {
    composer_insert: input_mod.InlineBytes,
    composer_backspace,
    composer_left,
    composer_right,
    composer_start,
    composer_end,
    composer_submit,
    transcript_page_up,
    transcript_page_down,
    interrupt,
    clear_or_exit,
    exit_if_composer_empty,
    request_shutdown,
    none,
};

pub fn resolve(event: input_mod.Input) KeyAction {
    return switch (event) {
        .text => |bytes| .{ .composer_insert = bytes },
        .key => |key| resolveKey(key),
        else => .none,
    };
}

fn resolveKey(key: input_mod.Key) KeyAction {
    return switch (key) {
        .backspace => .composer_backspace,
        .arrow_left => .composer_left,
        .arrow_right => .composer_right,
        .home => .composer_start,
        .end => .composer_end,
        .enter => .composer_submit,
        .page_up => .transcript_page_up,
        .page_down => .transcript_page_down,
        .escape => .interrupt,
        .ctrl_c => .clear_or_exit,
        .ctrl_u => .transcript_page_up,
        .ctrl_d => .exit_if_composer_empty,
        .tab, .delete => .none,
    };
}
