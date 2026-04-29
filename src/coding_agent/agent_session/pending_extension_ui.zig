const std = @import("std");

const extension_ui = @import("../extensions/ui.zig");

pub const PendingExtensionUi = struct {
    allocator: std.mem.Allocator,
    report: ?extension_ui.Report = null,
    prompts: std.ArrayListUnmanaged(extension_ui.PromptRequest) = .empty,
    ui_publications: std.ArrayListUnmanaged(extension_ui.UiPublication) = .empty,
    editor_actions: std.ArrayListUnmanaged(extension_ui.EditorAction) = .empty,

    pub fn init(allocator: std.mem.Allocator) PendingExtensionUi {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PendingExtensionUi) void {
        self.clearReport();
        self.clearPrompts();
        self.clearUiPublications();
        self.clearEditorActions();
    }

    pub fn publishReport(self: *PendingExtensionUi, report: extension_ui.Report) !void {
        self.clearReport();
        self.report = try extension_ui.Report.clone(self.allocator, report);
    }

    pub fn takeReport(self: *PendingExtensionUi) ?extension_ui.Report {
        const report = self.report;
        self.report = null;
        return report;
    }

    pub fn clearReport(self: *PendingExtensionUi) void {
        if (self.report) |*report| report.deinit(self.allocator);
        self.report = null;
    }

    pub fn publishPrompt(self: *PendingExtensionUi, prompt: extension_ui.PromptRequest) !void {
        var cloned = try extension_ui.PromptRequest.clone(self.allocator, prompt);
        errdefer cloned.deinit(self.allocator);
        try self.prompts.append(self.allocator, cloned);
    }

    pub fn promptCount(self: *const PendingExtensionUi) usize {
        return self.prompts.items.len;
    }

    pub fn clearPrompts(self: *PendingExtensionUi) void {
        for (self.prompts.items) |*prompt| prompt.deinit(self.allocator);
        self.prompts.deinit(self.allocator);
        self.prompts = .empty;
    }

    pub fn publishUi(self: *PendingExtensionUi, update: extension_ui.UiPublication) !void {
        var cloned = try extension_ui.UiPublication.clone(self.allocator, update);
        errdefer cloned.deinit(self.allocator);
        try self.ui_publications.append(self.allocator, cloned);
    }

    pub fn takeUiPublications(self: *PendingExtensionUi, allocator: std.mem.Allocator) ![]extension_ui.UiPublication {
        const out = try allocator.alloc(extension_ui.UiPublication, self.ui_publications.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*update| update.deinit(allocator);
        }
        for (self.ui_publications.items, 0..) |update, i| {
            out[i] = try extension_ui.UiPublication.clone(allocator, update);
            initialized += 1;
        }
        self.clearUiPublications();
        return out;
    }

    pub fn clearUiPublications(self: *PendingExtensionUi) void {
        for (self.ui_publications.items) |*update| update.deinit(self.allocator);
        self.ui_publications.deinit(self.allocator);
        self.ui_publications = .empty;
    }

    pub fn publishEditorAction(self: *PendingExtensionUi, action: extension_ui.EditorAction) !void {
        var cloned = try extension_ui.EditorAction.clone(self.allocator, action);
        errdefer cloned.deinit(self.allocator);
        try self.editor_actions.append(self.allocator, cloned);
    }

    pub fn takeEditorActions(self: *PendingExtensionUi, allocator: std.mem.Allocator) ![]extension_ui.EditorAction {
        const out = try allocator.alloc(extension_ui.EditorAction, self.editor_actions.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |*action| action.deinit(allocator);
        }
        for (self.editor_actions.items, 0..) |action, i| {
            out[i] = try extension_ui.EditorAction.clone(allocator, action);
            initialized += 1;
        }
        self.clearEditorActions();
        return out;
    }

    pub fn clearEditorActions(self: *PendingExtensionUi) void {
        for (self.editor_actions.items) |*action| action.deinit(self.allocator);
        self.editor_actions.deinit(self.allocator);
        self.editor_actions = .empty;
    }
};
