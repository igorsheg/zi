const std = @import("std");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const session_store_mod = @import("../../coding_agent/session/store.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const overlay_mod = @import("../primitives/overlay.zig");
const resume_picker_flow_mod = @import("resume_picker_flow.zig");

const Interactive = @import("../interactive.zig").Interactive;
const PickerSelection = list_picker_mod.Selection;
const ResumePickerFlow = resume_picker_flow_mod.ResumePickerFlow;

pub fn close(self: *Interactive) void {
    if (self.resume_picker_flow) |*flow| {
        if (flow.handle) |h| {
            flow.handle = null;
            h.hide();
        }
        flow.deinit();
    }
    self.resume_picker_flow = null;
}

pub fn show(self: *Interactive, restore_session_model: bool) void {
    close(self);
    self.resume_picker_generation +%= 1;
    const generation = self.resume_picker_generation;

    var flow = ResumePickerFlow.initLoading(
        self.allocator,
        self.theme,
        restore_session_model,
        generation,
    ) catch {
        self.status_line.setPrimary("failed to open resume picker", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    errdefer flow.deinit();

    flow.picker.on_select = &onSelected;
    flow.picker.on_cancel = &onCancel;
    flow.picker.callback_ctx = @ptrCast(self);
    self.cancelTranscriptSelection();
    self.resume_picker_flow = flow;
    self.resume_picker_flow.?.handle = self.tui.showOverlay(
        self.resume_picker_flow.?.picker.component(),
        overlay_mod.OverlayPreset.ivy.options(.{ .top_margin = self.overlayTopMargin() }),
    );
    self.tui.dirty = true;

    self.session_index_worker.listResumeSessions(generation, self.cwd) catch {
        close(self);
        self.status_line.setPrimary("failed to queue session listing", self.theme.fg(.@"error"));
        self.tui.dirty = true;
    };
}

pub fn applyLoaded(self: *Interactive, generation: u64, sessions: []const session_store_mod.SessionInfo) void {
    if (generation != self.resume_picker_generation) return;
    const flow = if (self.resume_picker_flow) |*flow| flow else return;
    if (flow.generation != generation) return;

    if (sessions.len == 0) {
        flow.picker.setStatus(.{ .text = "No sessions found", .kind = .info });
        flow.picker.setEmptyText("No matching sessions");
        flow.picker.setSearchableItems(&.{}, null);
        self.status_line.setPrimary("no sessions found", self.theme.fg(.muted));
        self.tui.dirty = true;
        return;
    }

    flow.populate(sessions) catch {
        close(self);
        self.status_line.setPrimary("failed to render sessions", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    self.tui.dirty = true;
}

pub fn applyFailed(self: *Interactive, generation: u64, message: []const u8) void {
    if (generation != self.resume_picker_generation) return;
    if (self.resume_picker_flow) |*flow| {
        if (flow.generation != generation) return;
        flow.picker.setStatus(.{ .text = message, .kind = .@"error" });
        flow.picker.setEmptyText("No matching sessions");
        flow.picker.setSearchableItems(&.{}, null);
    }
    self.status_line.setPrimary(message, self.theme.fg(.@"error"));
    self.tui.dirty = true;
}

fn onSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    const path = if (self.resume_picker_flow) |*flow|
        if (selection.source_index < flow.rows.len) flow.rows[selection.source_index].path else null
    else
        null;

    const selected_path = path orelse {
        close(self);
        self.status_line.setPrimary("session not found", self.theme.fg(.@"error"));
        return;
    };

    const path_copy = self.msg_allocator.dupe(u8, selected_path) catch {
        close(self);
        self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
        return;
    };
    const restore_session_model = self.resume_picker_flow.?.restore_session_model;
    close(self);
    _ = self.dispatchIdleRequest(.{ .resume_session = .{
        .path = path_copy,
        .restore_session_model = restore_session_model,
    } }, .{
        .busy_message = "cannot resume while agent is running",
        .loader_message = "Loading session...",
        .spawn_failed_message = "failed to queue resume",
    });
}

fn onCancel(ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    close(self);
}
