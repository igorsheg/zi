const std = @import("std");
const harness_mod = @import("vscreen_harness.zig");
const text_primitive = @import("../primitive/text.zig");
const substrate = @import("../substrate/root.zig");
const transcript = @import("transcript.zig");

fn applyMessage(
    harness: *harness_mod.VScreenHarness,
    role: transcript.TranscriptRole,
    text: []const u8,
) !void {
    try std.testing.expect(try harness.apply(.{
        .append_transcript = .{ .message = .{ .role = role, .text = text } },
    }) == null);
}

fn expectCellText(harness: *const harness_mod.VScreenHarness, x: u16, y: u16, text: []const u8) !void {
    var col: u16 = x;
    var i: usize = 0;
    while (i < text.len) {
        const grapheme = text_primitive.nextGrapheme(text[i..]);
        if (grapheme.end == 0) break;
        const cell = try harness.nextCell(col, y);
        const inline_text = cell.renderText() orelse return error.MissingCellText;
        try std.testing.expectEqualStrings(text[i..][grapheme.start..grapheme.end], inline_text.slice());
        i += grapheme.end;
        col += grapheme.width;
    }
}

test "product frame renders through deterministic vscreen harness" {
    var storage: [4096]u8 = undefined;
    var harness = try harness_mod.VScreenHarness.init(std.testing.allocator, 20, 4, &storage);
    defer harness.deinit();

    const text = substrate.input.InlineBytes.from("hello");
    try std.testing.expect(try harness.apply(.{ .input = .{ .text = text } }) == null);
    const diff = try harness.render();
    try std.testing.expect(diff.changed > 0);
    try std.testing.expect(std.mem.indexOf(u8, harness.output.bytes(), "h") != null);
    try expectCellText(&harness, 0, 0, "zi");
    try expectCellText(&harness, 0, 3, "> hello");

    harness.output.reset();
    try harness.build();
    const second = try harness.stage();
    try std.testing.expectEqual(@as(usize, 0), second.changed);
    harness.commit();
}

test "product frame wraps long transcript text from bottom" {
    var storage: [4096]u8 = undefined;
    var harness = try harness_mod.VScreenHarness.init(std.testing.allocator, 12, 5, &storage);
    defer harness.deinit();

    try std.testing.expect(try harness.apply(.{
        .append_transcript = .{ .message = .{ .role = .assistant, .text = "abcdefghij0123456789" } },
    }) == null);

    _ = try harness.render();
    try expectCellText(&harness, 0, 1, "assistant: a");
    try expectCellText(&harness, 0, 2, "bcdefghij012");
    try expectCellText(&harness, 0, 3, "3456789");
}

test "product frame wraps graphemes without splitting wide cells" {
    var storage: [4096]u8 = undefined;
    var harness = try harness_mod.VScreenHarness.init(std.testing.allocator, 10, 4, &storage);
    defer harness.deinit();

    try std.testing.expect(try harness.apply(.{
        .append_transcript = .{ .message = .{ .role = .assistant, .text = "o\u{0300}中👩🏽‍🚀b" } },
    }) == null);

    _ = try harness.render();
    try expectCellText(&harness, 0, 1, "assistant:");
    try expectCellText(&harness, 0, 2, "o\u{0300}中👩🏽‍🚀b");
}

test "product frame shows newest transcript lines and preserves composer row" {
    var storage: [4096]u8 = undefined;
    var harness = try harness_mod.VScreenHarness.init(std.testing.allocator, 40, 5, &storage);
    defer harness.deinit();

    try applyMessage(&harness, .system, "old");
    try applyMessage(&harness, .user, "one");
    try applyMessage(&harness, .assistant, "tw");
    try std.testing.expect(try harness.apply(.{
        .append_transcript = .{ .message = .{
            .role = .assistant,
            .text = "o",
            .mode = .extend_previous_assistant_message,
        } },
    }) == null);
    try applyMessage(&harness, .system, "three");
    try std.testing.expect(try harness.apply(.{
        .input = .{ .text = substrate.input.InlineBytes.from("o\u{0300}👩🏽‍🚀") },
    }) == null);

    _ = try harness.render();
    try expectCellText(&harness, 0, 1, "user: one");
    try expectCellText(&harness, 0, 2, "assistant: two");
    try expectCellText(&harness, 0, 3, "system: three");
    try expectCellText(&harness, 0, 4, "> o\u{0300}👩🏽‍🚀");
    try std.testing.expectEqual(@as(usize, 4), harness.app.transcript.items.items.len);
    try std.testing.expectEqualStrings("two", harness.app.transcript.items.items[2].message.text);
}
