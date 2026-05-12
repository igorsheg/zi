const std = @import("std");

const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");
const theme_mod = @import("../theme.zig");
const tui_mod = @import("../tui.zig");
const session_store_mod = @import("../../coding_agent/session/store.zig");
const time_util = @import("../../lib/time_util.zig");

const ListPicker = list_picker_mod.ListPicker;
const SelectItem = select_list_mod.SelectItem;

pub const ResumePickerFlow = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    items: []SelectItem = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,
    restore_session_model: bool = true,
    generation: u64 = 0,

    pub const Row = struct {
        item: SelectItem,
        path: []const u8,
    };

    pub fn initLoading(
        gpa: std.mem.Allocator,
        theme: *const theme_mod.Theme,
        restore_session_model: bool,
        generation: u64,
    ) !ResumePickerFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        var picker = ListPicker.init(gpa, theme);
        picker.title = "Resume session";
        picker.list.max_visible = 10;
        picker.setSearchPlaceholder("Filter sessions");
        picker.setEmptyText("No matching sessions");
        picker.setStatus(.{ .text = "Loading sessions...", .kind = .loading });
        picker.setSearchableItems(&.{}, null);

        return .{
            .arena = arena,
            .picker = picker,
            .restore_session_model = restore_session_model,
            .generation = generation,
        };
    }

    pub fn populate(self: *ResumePickerFlow, summaries: []const session_store_mod.SessionInfo) !void {
        const a = self.arena.allocator();
        const rows = try a.alloc(Row, summaries.len);
        const items = try a.alloc(SelectItem, summaries.len);

        for (summaries, 0..) |session, i| {
            const item: SelectItem = .{
                .value = try a.dupe(u8, session.session_id),
                .label = try a.dupe(u8, session.first_message),
                .description = try std.fmt.allocPrint(a, "{d} msgs \xC2\xB7 {s}", .{
                    session.message_count,
                    time_util.relativeTimeLabel(session.timestamp),
                }),
            };
            rows[i] = .{ .item = item, .path = try a.dupe(u8, session.path) };
            items[i] = item;
        }

        self.rows = rows;
        self.items = items;
        self.picker.setStatus(null);
        self.picker.setEmptyText("No matching sessions");
        self.picker.setSearchableItems(items, null);
    }

    pub fn deinit(self: *ResumePickerFlow) void {
        self.picker.deinit();
        self.arena.deinit();
    }
};
