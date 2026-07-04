const std = @import("std");

const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");

const slash_commands = coding_agent.slash_commands;
const vm = coding_agent.view_model;

pub const model_picker_id: tui.Picker.Id = 1;
pub const command_completion_picker_id: tui.Picker.Id = 2;
pub const resume_picker_id: tui.Picker.Id = 3;
pub const file_picker_id: tui.Picker.Id = 4;
pub const settings_picker_id: tui.Picker.Id = 5;
pub const settings_thinking_picker_id: tui.Picker.Id = 6;
pub const binding_open_model_picker: tui.keybind.Id = 1;

pub const BareCommand = enum { none, model, resume_session, settings };

pub fn bareCommand(text: []const u8) BareCommand {
    if (isBareSlashCommand(text, .model)) return .model;
    if (isBareSlashCommand(text, .resume_session)) return .resume_session;
    if (isBareSlashCommand(text, .settings)) return .settings;
    return .none;
}

pub fn commandQueryId(kind: vm.CompletionSlot.Kind) u64 {
    return switch (kind) {
        .model => model_picker_id,
        .resume_session => resume_picker_id,
        .file => file_picker_id,
        .settings => settings_picker_id,
        .slash_arg => command_completion_picker_id,
        .none => 0,
    };
}

pub fn commandForCompletion(gpa: std.mem.Allocator, completion: vm.CompletionSlot) !?tui.Command {
    if (completion.kind == .none) return null;
    var items = try gpa.alloc(tui.Picker.Item, completion.items.items.len);
    errdefer gpa.free(items);
    for (completion.items.items, 0..) |item, index| {
        items[index] = .{
            .id = item.id.slice(),
            .label = item.label.slice(),
            .detail = item.detail.slice(),
        };
    }
    return switch (completion.kind) {
        .file => .{ .set_file_completions = .{
            .id = @intCast(completion.query_id),
            .items = items,
            .search_detail = true,
            .layout = .{ .two_column = .{ .label_width = 32, .detail_width = 48 } },
            .min_visible_rows = 4,
        } },
        .model => .{ .set_composer_arg_completions = .{
            .command_name = "model",
            .picker = .{
                .id = model_picker_id,
                .items = items,
                .search_detail = true,
                .layout = .{ .two_column = .{ .label_width = 28, .detail_width = 44 } },
            },
        } },
        .resume_session => .{ .set_composer_arg_completions = .{
            .command_name = "resume",
            .accept = .emit_selection,
            .picker = .{
                .id = resume_picker_id,
                .items = items,
                .search_detail = true,
                .match_order = .input,
                .layout = .{ .four_column = .{
                    .label_width = 40,
                    .detail_width = 14,
                    .meta_width = 8,
                    .aux_width = 10,
                } },
            },
        } },
        .settings => .{ .open_picker = settingsOpen(items) },
        .slash_arg => .{ .set_composer_completions = .{ .id = command_completion_picker_id, .items = items } },
        .none => unreachable,
    };
}

pub fn settingsCommand(out: *[2]tui.Picker.Item, chrome: vm.Chrome) tui.Command {
    const hide_value = if (chrome.hide_thinking) "thinking:shown" else "thinking:hidden";
    const thinking_visibility_label = if (chrome.hide_thinking) "Show thinking" else "Hide thinking";
    const thinking_visibility_detail = if (chrome.hide_thinking)
        "Currently hidden; Enter to show reasoning text"
    else
        "Currently shown; Enter to show compact Thinking blocks";
    out.* = .{
        .{
            .id = "open:thinking",
            .label = "Thinking effort",
            .detail = @tagName(chrome.thinking_level),
            .meta = "configure",
        },
        .{
            .id = hide_value,
            .label = thinking_visibility_label,
            .detail = thinking_visibility_detail,
            .meta = if (chrome.hide_thinking) "hidden" else "shown",
        },
    };
    return .{ .open_picker = settingsOpen(out) };
}

pub fn thinkingCommand(out: *[6]tui.Picker.Item, level: vm.ThinkingLevel) tui.Command {
    out.* = .{
        thinkingItem("thinking:off", "off", "No reasoning", level == .off),
        thinkingItem("thinking:minimal", "minimal", "Very brief reasoning", level == .minimal),
        thinkingItem("thinking:low", "low", "Light reasoning", level == .low),
        thinkingItem("thinking:medium", "medium", "Moderate reasoning", level == .medium),
        thinkingItem("thinking:high", "high", "Deep reasoning", level == .high),
        thinkingItem("thinking:xhigh", "xhigh", "Maximum reasoning", level == .xhigh),
    };
    return .{ .open_picker = .{
        .id = settings_thinking_picker_id,
        .items = out,
        .search_detail = true,
        .filter_enabled = false,
        .layout = .{ .two_column = .{} },
        .min_visible_rows = 6,
    } };
}

pub fn modelSelectionPrompt(buffer: []u8, item_id: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "/model {s}", .{item_id}) catch null;
}

pub fn settingsSelectionPrompt(buffer: []u8, item_id: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "/settings {s}", .{item_id}) catch null;
}

const key_bindings = [_]tui.keybind.Binding{.{
    .id = binding_open_model_picker,
    .chord = tui.input.Chord.ctrl('l'),
}};

pub fn installKeyBindingsCommand() tui.Command {
    return .{ .set_key_bindings = &key_bindings };
}

pub fn formatModelTokenCount(buffer: []u8, tokens: u64) []const u8 {
    if (tokens >= 1_000_000 and tokens % 1_000_000 == 0) {
        return std.fmt.bufPrint(buffer, "{d}m", .{tokens / 1_000_000}) catch "?";
    }
    if (tokens >= 1_000 and tokens % 1_000 == 0) {
        return std.fmt.bufPrint(buffer, "{d}k", .{tokens / 1_000}) catch "?";
    }
    return std.fmt.bufPrint(buffer, "{d}", .{tokens}) catch "?";
}

pub fn formatModelCost(buffer: []u8, cost: ai.Model.Cost) []const u8 {
    return std.fmt.bufPrint(buffer, "${d:.2} in/${d:.2} out per 1M", .{
        cost.input,
        cost.output,
    }) catch "$? in/$? out per 1M";
}

pub fn formatModelDetail(allocator: std.mem.Allocator, model: ai.Model, status: []const u8, current: bool) ![]const u8 {
    var context_buffer: [24]u8 = undefined;
    var cost_buffer: [80]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s} - {s}{s}; ctx {s}; {s}", .{
        model.name,
        if (current) "current, " else "",
        status,
        formatModelTokenCount(&context_buffer, model.context_window),
        formatModelCost(&cost_buffer, model.cost),
    });
}

fn settingsOpen(items: []const tui.Picker.Item) tui.Picker.Open {
    return .{
        .id = settings_picker_id,
        .items = items,
        .search_detail = true,
        .layout = .{ .two_column = .{} },
        .min_visible_rows = 2,
    };
}

fn thinkingItem(id: []const u8, label: []const u8, detail: []const u8, current: bool) tui.Picker.Item {
    return .{ .id = id, .label = label, .detail = detail, .meta = if (current) "current" else "" };
}

fn isBareSlashCommand(text: []const u8, id: slash_commands.Id) bool {
    const invocation = slash_commands.parseInvocation(text) orelse return false;
    const spec = slash_commands.lookup(invocation.name) orelse return false;
    return spec.id == id and invocation.args.len == 0;
}

test "bare slash commands" {
    try std.testing.expectEqual(BareCommand.model, bareCommand("/model"));
    try std.testing.expectEqual(BareCommand.model, bareCommand("/model   "));
    try std.testing.expectEqual(BareCommand.resume_session, bareCommand("/resume"));
    try std.testing.expectEqual(BareCommand.settings, bareCommand("/settings"));
    try std.testing.expectEqual(BareCommand.none, bareCommand("/model gpt-5.1"));
    try std.testing.expectEqual(BareCommand.none, bareCommand("/modelx"));
}

test "model token and cost formatting goldens" {
    var token_buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1m", formatModelTokenCount(&token_buffer, 1_000_000));
    try std.testing.expectEqualStrings("128k", formatModelTokenCount(&token_buffer, 128_000));
    try std.testing.expectEqualStrings("127500", formatModelTokenCount(&token_buffer, 127_500));

    var cost_buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings(
        "$1.25 in/$10.00 out per 1M",
        formatModelCost(&cost_buffer, .{ .input = 1.25, .output = 10, .cache_read = 0, .cache_write = 0 }),
    );
}

test "settings picker reflects chrome" {
    var chrome: vm.Chrome = .{};
    chrome.thinking_level = .medium;
    chrome.hide_thinking = true;
    var items: [2]tui.Picker.Item = undefined;
    const command = settingsCommand(&items, chrome);
    try std.testing.expect(command == .open_picker);
    try std.testing.expectEqual(settings_picker_id, command.open_picker.id);
    try std.testing.expectEqualStrings("medium", command.open_picker.items[0].detail);
    try std.testing.expectEqualStrings("Show thinking", command.open_picker.items[1].label);
}
