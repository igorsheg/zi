const std = @import("std");
const request_mod = @import("../../coding_agent/request.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const extension_prompt_flow_mod = @import("extension_prompt_flow.zig");

const Interactive = @import("../interactive.zig").Interactive;
const PickerSelection = list_picker_mod.Selection;
const ExtensionPromptFlow = extension_prompt_flow_mod.ExtensionPromptFlow;

pub fn close(self: *Interactive, resolve_default: bool) void {
    if (self.extension_prompt_flow) |*flow| {
        if (resolve_default) flow.response.finish(request_mod.ExtensionPromptResponse.defaultFor(flow.prompt.kind));
        if (flow.handle) |h| {
            flow.handle = null;
            h.hide();
        }
        flow.deinit();
    }
    self.extension_prompt_flow = null;
    self.extension_prompt_close_after_submit = false;
}

pub fn finishIfTimedOut(self: *Interactive) void {
    if (self.extension_prompt_flow) |*flow| {
        const deadline = flow.deadline_ns orelse return;
        if (std.time.nanoTimestamp() < deadline) return;
        flow.response.finish(.timeout);
        close(self, false);
        self.tui.dirty = true;
    }
}

pub fn show(self: *Interactive, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void {
    close(self, true);
    var flow = ExtensionPromptFlow.init(self.allocator, self.theme, prompt, response) catch {
        response.finish(request_mod.ExtensionPromptResponse.defaultFor(prompt.kind));
        return;
    };
    errdefer flow.deinit();
    if (flow.picker) |*picker| {
        picker.on_select = &onSelected;
        picker.on_cancel = &onCancelled;
        picker.callback_ctx = @ptrCast(self);
    }
    if (flow.editor) |*editor| {
        editor.setOnSubmit(&onSubmitted, @ptrCast(self));
    }
    self.cancelTranscriptSelection();
    self.extension_prompt_flow = flow;
    const component = switch (self.extension_prompt_flow.?.prompt.kind) {
        .confirm, .select => self.extension_prompt_flow.?.picker.?.component(),
        .input, .editor => self.extension_prompt_flow.?.editor.?.component(),
    };
    self.extension_prompt_flow.?.handle = self.tui.showOverlay(
        component,
        self.bottomSheetOptions(),
    );
}

fn onSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    if (self.extension_prompt_flow) |*flow| {
        switch (flow.prompt.kind) {
            .confirm => flow.response.finish(.{ .confirm = std.mem.eql(u8, selection.item.value, "yes") }),
            .select => {
                const selected = if (selection.source_index < flow.prompt.options.len) flow.prompt.options[selection.source_index] else null;
                const value = self.msg_allocator.dupe(u8, selection.item.value) catch null;
                if (value) |text| {
                    const label = if (selected) |option| if (option.label.len > 0) self.msg_allocator.dupe(u8, option.label) catch null else null else null;
                    const description = if (selected) |option| if (option.description) |description| self.msg_allocator.dupe(u8, description) catch null else null else null;
                    const search = if (selected) |option| if (option.search) |search| self.msg_allocator.dupe(u8, search) catch null else null else null;
                    const preview = if (selected) |option| if (option.preview) |preview| self.msg_allocator.dupe(u8, preview) catch null else null else null;
                    flow.response.finish(.{ .value = .{
                        .text = text,
                        .allocator = self.msg_allocator,
                        .label = label,
                        .description = description,
                        .search = search,
                        .preview = preview,
                    } });
                } else {
                    flow.response.finish(.{ .value = null });
                }
            },
            .input, .editor => flow.response.finish(request_mod.ExtensionPromptResponse.defaultFor(flow.prompt.kind)),
        }
    }
    close(self, false);
}

fn onSubmitted(text: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    if (self.extension_prompt_flow) |*flow| {
        const value = self.msg_allocator.dupe(u8, text) catch null;
        flow.response.finish(.{ .value = if (value) |owned| .{ .text = owned, .allocator = self.msg_allocator } else null });
        self.extension_prompt_close_after_submit = true;
    }
}

fn onCancelled(ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    close(self, true);
}
