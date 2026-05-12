const std = @import("std");

const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");
const theme_mod = @import("../theme.zig");
const tui_mod = @import("../tui.zig");
const auth_storage_mod = @import("../../coding_agent/auth/storage.zig");
const ai_protocol = @import("../../ai/protocol.zig");
const json_util = @import("../../ai/json_util.zig");

const ListPicker = list_picker_mod.ListPicker;
const SelectItem = select_list_mod.SelectItem;

pub const ModelPickerFlow = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    items: []SelectItem = &.{},
    search_texts: []const []const u8 = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,

    pub const Row = struct {
        item: SelectItem,
        model: ai_protocol.Model,
        search_text: []const u8,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        theme: *const theme_mod.Theme,
        model_catalog: []const ai_protocol.Model,
        auth_storage: *auth_storage_mod.AuthStorage,
    ) !ModelPickerFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var count: usize = 0;
        for (model_catalog) |model| {
            if (auth_storage.hasAuth(json_util.providerToString(model.provider))) count += 1;
        }

        const rows = try a.alloc(Row, count);
        const items = try a.alloc(SelectItem, count);
        const search_texts = try a.alloc([]const u8, count);

        var i: usize = 0;
        for (model_catalog) |model| {
            const provider_str = json_util.providerToString(model.provider);
            if (!auth_storage.hasAuth(provider_str)) continue;

            const item: SelectItem = .{
                .value = model.id,
                .label = model.id,
                .description = provider_str,
            };
            const search_text = try std.fmt.allocPrint(a, "{s} {s}", .{ provider_str, model.id });
            rows[i] = .{ .item = item, .model = model, .search_text = search_text };
            items[i] = item;
            search_texts[i] = search_text;
            i += 1;
        }

        var picker = ListPicker.init(gpa, theme);
        picker.title = "Select model";
        picker.list.max_visible = 12;
        picker.setSearchPlaceholder("Search models");
        picker.setEmptyText("No matching models");
        picker.setSearchableItems(items, search_texts);

        return .{
            .arena = arena,
            .rows = rows,
            .items = items,
            .search_texts = search_texts,
            .picker = picker,
        };
    }

    pub fn deinit(self: *ModelPickerFlow) void {
        self.picker.deinit();
        self.arena.deinit();
    }
};
