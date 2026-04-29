const std = @import("std");
const json_util = @import("../../ai/json_util.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const model_picker_flow_mod = @import("model_picker_flow.zig");

const Interactive = @import("../interactive.zig").Interactive;
const PickerSelection = list_picker_mod.Selection;
const ModelPickerFlow = model_picker_flow_mod.ModelPickerFlow;

pub fn close(self: *Interactive) void {
    if (self.model_picker_flow) |*flow| {
        if (flow.handle) |h| {
            flow.handle = null;
            h.hide();
        }
        flow.deinit();
    }
    self.model_picker_flow = null;
}

pub fn show(self: *Interactive) void {
    close(self);
    var flow = ModelPickerFlow.init(self.allocator, self.theme, self.model_catalog, self.auth_storage) catch {
        self.status_line.setPrimary("failed to build model picker", self.theme.fg(.@"error"));
        return;
    };
    errdefer flow.deinit();

    if (flow.rows.len == 0) {
        self.status_line.setPrimary("no models available", self.theme.fg(.muted));
        return;
    }

    flow.picker.on_select = &onSelected;
    flow.picker.on_cancel = &onCancel;
    flow.picker.callback_ctx = @ptrCast(self);
    for (flow.rows, 0..) |row, i| {
        if (std.mem.eql(u8, json_util.providerToString(row.model.provider), self.status_data.model_provider) and
            std.mem.eql(u8, row.model.id, self.status_data.model_id))
        {
            flow.picker.setInitialSelectionIndex(i);
            break;
        }
    }
    self.cancelTranscriptSelection();
    self.model_picker_flow = flow;
    self.model_picker_flow.?.handle = self.tui.showOverlay(
        self.model_picker_flow.?.picker.component(),
        self.bottomSheetOptions(),
    );
}

pub fn switchDirect(self: *Interactive, pattern: []const u8) void {
    queuePatternSwitch(self, pattern);
}

fn onSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    const selected_model = if (self.model_picker_flow) |*flow|
        if (selection.source_index < flow.rows.len) flow.rows[selection.source_index].model else null
    else
        null;

    close(self);

    const m = selected_model orelse {
        self.status_line.setPrimary("model not found", self.theme.fg(.@"error"));
        return;
    };

    const reference = std.fmt.allocPrint(self.msg_allocator, "{s}/{s}", .{ json_util.providerToString(m.provider), m.id }) catch {
        self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    defer self.msg_allocator.free(reference);
    queuePatternSwitch(self, reference);
}

fn onCancel(ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    close(self);
}

fn queuePatternSwitch(self: *Interactive, pattern: []const u8) void {
    const pattern_copy = self.msg_allocator.dupe(u8, pattern) catch {
        self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    _ = self.dispatchIdleRequest(.{ .set_model_by_pattern = .{ .pattern = pattern_copy } }, .{
        .busy_message = "cannot switch model while agent is running",
        .loader_message = "Switching model...",
        .spawn_failed_message = "failed to queue model switch",
    });
}
