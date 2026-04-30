const std = @import("std");

const editor_mod = @import("../components/editor.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");
const theme_mod = @import("../theme.zig");
const tui_mod = @import("../tui.zig");
const request_mod = @import("../../coding_agent/request.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");

const ListPicker = list_picker_mod.ListPicker;
const SelectItem = select_list_mod.SelectItem;

pub const ExtensionPromptFlow = struct {
    arena: std.heap.ArenaAllocator,
    prompt: extension_ui.PromptRequest,
    response: *request_mod.ExtensionPromptResponse,
    items: []SelectItem = &.{},
    search_texts: []const []const u8 = &.{},
    picker: ?ListPicker = null,
    editor: ?editor_mod.Editor = null,
    handle: ?tui_mod.OverlayHandle = null,
    deadline_ns: ?i128 = null,

    pub fn init(gpa: std.mem.Allocator, theme: *const theme_mod.Theme, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) !ExtensionPromptFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_prompt = try extension_ui.PromptRequest.clone(a, prompt);
        const deadline_ns = if (owned_prompt.timeout_ms) |ms|
            @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + @as(i128, @intCast(ms)) * std.time.ns_per_ms
        else
            null;

        switch (prompt.kind) {
            .confirm, .select => {
                const items = switch (prompt.kind) {
                    .confirm => blk: {
                        const confirm_items = try a.alloc(SelectItem, 2);
                        confirm_items[0] = .{ .value = "yes", .label = "Yes" };
                        confirm_items[1] = .{ .value = "no", .label = "No" };
                        break :blk confirm_items;
                    },
                    .select => blk: {
                        const select_items = try a.alloc(SelectItem, owned_prompt.options.len);
                        for (owned_prompt.options, 0..) |option, i| {
                            select_items[i] = .{ .value = option.id, .label = option.label, .description = option.description };
                        }
                        break :blk select_items;
                    },
                    .input, .editor => unreachable,
                };
                var picker = ListPicker.init(theme);
                picker.title = owned_prompt.title;
                picker.list.max_visible = 8;
                picker.setSearchPlaceholder(owned_prompt.placeholder);
                if (owned_prompt.empty_text) |empty_text| picker.setEmptyText(empty_text);
                const search_texts = try buildPromptSearchTexts(a, owned_prompt.options);
                if (search_texts.len > 0) {
                    picker.setSearchableItems(items, search_texts);
                } else {
                    picker.setItems(items);
                }
                return .{ .arena = arena, .prompt = owned_prompt, .response = response, .items = items, .search_texts = search_texts, .picker = picker, .deadline_ns = deadline_ns };
            },
            .input, .editor => {
                var editor = editor_mod.Editor.init(a);
                editor.setTheme(theme);
                editor.setCwd(owned_prompt.title);
                editor.setAutocompleteMaxVisible(0);
                editor.setMaxVisibleLines(if (prompt.kind == .input) 1 else 8);
                if (owned_prompt.prefill) |prefill| editor.setText(prefill);
                return .{ .arena = arena, .prompt = owned_prompt, .response = response, .editor = editor, .deadline_ns = deadline_ns };
            },
        }
    }

    pub fn deinit(self: *ExtensionPromptFlow) void {
        if (self.editor) |*editor| editor.deinit();
        self.arena.deinit();
    }
};

fn buildPromptSearchTexts(arena: std.mem.Allocator, options: []const extension_ui.SelectOption) ![]const []const u8 {
    if (options.len == 0) return &.{};
    var any_search = false;
    for (options) |option| {
        if (option.search != null) {
            any_search = true;
            break;
        }
    }
    if (!any_search) return &.{};
    const out = try arena.alloc([]const u8, options.len);
    for (options, 0..) |option, i| {
        out[i] = option.search orelse option.label;
    }
    return out;
}
