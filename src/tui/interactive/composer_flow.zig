const std = @import("std");
const ai_protocol = @import("../../ai/protocol.zig");
const message_memory = @import("../../agent3/message_memory.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const clipboard_images = @import("clipboard_images.zig");

const Interactive = @import("../interactive.zig").Interactive;

const QueuedInputKind = enum {
    steering,
    follow_up,
};

pub fn hasPendingInput(self: *Interactive) bool {
    return self.active_editor.getText().len > 0 or self.pending_images.items.len > 0;
}

pub fn clearDraft(self: *Interactive) void {
    self.active_editor.clear();
    clearPendingImages(self);
    self.refreshHeaderVisibility();
}

pub fn clearPendingImages(self: *Interactive) void {
    for (self.pending_images.items) |*attachment| attachment.deinit(self.allocator);
    self.pending_images.clearRetainingCapacity();
    refreshPendingImageBanner(self);
}

pub fn refreshPendingImageBanner(self: *Interactive) void {
    self.pending_container.clear();
    if (self.pending_images.items.len == 0) return;

    const banner = clipboard_images.pendingImageBannerText(self.allocator, self.pending_images.items) catch return;
    defer self.allocator.free(banner);
    self.pending_image_banner.setContent(banner);
    self.pending_container.addChild(self.pending_image_banner.component());
}

pub fn handlePasteImageShortcut(self: *Interactive) void {
    if (self.is_streaming or self.request_in_flight) {
        self.status_line.setPrimary("cannot paste image while agent is running", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    }

    const raw = self.clipboard_image_reader(self.allocator) orelse {
        self.status_line.setPrimary("clipboard has no image", self.theme.fg(.muted));
        self.tui.dirty = true;
        return;
    };
    defer self.allocator.free(raw);

    const prepared = clipboard_images.prepareClipboardImageAttachment(self.allocator, raw, .{
        .auto_resize = self.settings_manager.getImageAutoResize(),
    }) catch {
        self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };

    switch (prepared) {
        .rejected => |message| {
            defer self.allocator.free(message);
            self.status_line.setPrimary(message, self.theme.fg(.warning));
        },
        .attach => |attachment| {
            self.pending_images.append(self.allocator, attachment) catch {
                var failed_attachment = attachment;
                failed_attachment.deinit(self.allocator);
                self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                return;
            };
            refreshPendingImageBanner(self);
            self.refreshHeaderVisibility();

            var status_buf: [96]u8 = undefined;
            const pending_count = self.pending_images.items.len;
            const status = if (pending_count == 1)
                "attached clipboard image"
            else
                std.fmt.bufPrint(&status_buf, "attached clipboard image ({d} pending)", .{pending_count}) catch "attached clipboard image";
            self.status_line.setPrimary(status, self.theme.fg(.success));
        },
    }
    self.tui.dirty = true;
}

pub fn restoreQueuedInputsToEditor(self: *Interactive) void {
    var snapshot = self.runtime_host.takeQueuedMessagesAndClear(self.msg_allocator) catch {
        self.status_line.setPrimary("failed to restore queued messages", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    defer snapshot.deinit(self.msg_allocator);

    applyRestoredQueuedInputs(self, &snapshot);
    _ = self.publishQueuedSnapshot();
}

pub fn submitUserContent(self: *Interactive, content: ai_protocol.UserMessage.UserMessageContent) bool {
    if (self.request_in_flight) {
        self.status_line.setPrimary("agent is busy", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return false;
    }

    const content_copy = message_memory.cloneUserContent(self.msg_allocator, content) catch return false;

    switch (self.request_queue.trySend(.{ .prompt = .{ .content = content_copy } })) {
        .ok => {},
        .dropped => unreachable,
        .full => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
            self.tui.setFocus(self.active_editor.component());
            self.showAgentRequestQueueFull();
            return false;
        },
        .closed, .oom => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
            self.tui.setFocus(self.active_editor.component());
            self.status_line.setPrimary("agent unavailable", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return false;
        },
    }

    clearDraft(self);
    self.is_streaming = true;
    self.showLoader("Working…");
    self.tui.dirty = true;
    return true;
}

pub fn handleFollowUpShortcut(self: *Interactive) void {
    const expanded = self.active_editor.getExpandedText();
    const text = std.mem.trim(u8, expanded, " \t\r\n");
    if (text.len == 0 and self.pending_images.items.len == 0) return;

    if (self.is_streaming) {
        handleSubmittedText(self, text, .follow_up);
        return;
    }

    handleSubmittedText(self, text, null);
}

pub fn onEditorSubmit(text: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx));
    handleSubmittedText(self, text, if (self.is_streaming) .steering else null);
}

fn queueMessageWhileStreaming(self: *Interactive, kind: QueuedInputKind, text: []const u8) void {
    const queue_kind: coding_agent_mod.runtime_host.QueueKind = switch (kind) {
        .steering => .steering,
        .follow_up => .follow_up,
    };
    switch (self.runtime_host.enqueueQueuedText(queue_kind, text)) {
        .ok => {},
        .closed, .oom => {
            self.status_line.setPrimary("agent unavailable", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        },
    }

    _ = self.publishQueuedSnapshot();

    self.active_editor.clear();
    self.refreshHeaderVisibility();
    self.tui.dirty = true;
}

fn applyRestoredQueuedInputs(self: *Interactive, snapshot: *const coding_agent_mod.runtime_host.QueuedMessageSnapshot) void {
    const count = snapshot.steering.len + snapshot.follow_up.len;
    if (count == 0) {
        self.status_line.setPrimary("no queued messages", self.theme.fg(.muted));
        self.tui.dirty = true;
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    for (snapshot.steering) |entry| {
        if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
        buf.appendSlice(self.allocator, entry.text) catch return;
    }
    for (snapshot.follow_up) |entry| {
        if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
        buf.appendSlice(self.allocator, entry.text) catch return;
    }

    const current_text = self.active_editor.getText();
    if (current_text.len > 0) {
        if (buf.items.len > 0) buf.appendSlice(self.allocator, "\n\n") catch return;
        buf.appendSlice(self.allocator, current_text) catch return;
    }

    self.active_editor.setText(buf.items);
    self.refreshHeaderVisibility();
    self.status_line.setPrimary(if (count == 1) "restored 1 queued message" else "restored queued messages", self.theme.fg(.success));
    self.tui.dirty = true;
}

fn handleSubmittedText(self: *Interactive, text: []const u8, queued_kind: ?QueuedInputKind) void {
    if (text.len == 0 and self.pending_images.items.len == 0) return;

    self.active_editor.addToHistory(text);

    if (text.len > 0 and text[0] == '/' and self.dispatchSlashCommand(text)) return;

    if (queued_kind) |kind| {
        if (self.pending_images.items.len > 0) {
            self.status_line.setPrimary("cannot queue images while agent is streaming", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        }
        queueMessageWhileStreaming(self, kind, text);
        return;
    }

    var built = clipboard_images.buildSubmittedUserContent(self.allocator, text, self.pending_images.items) catch {
        self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    defer built.deinit(self.allocator);

    _ = submitUserContent(self, built.content);
}
