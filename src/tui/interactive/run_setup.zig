const std = @import("std");
const editor_mod = @import("../components/editor.zig");
const editor_iface_mod = @import("../editor_iface.zig");
const autocomplete_mod = @import("../autocomplete.zig");
const runtime_loop = @import("runtime_loop.zig");
const composer_flow = @import("composer_flow.zig");

const Interactive = @import("../interactive.zig").Interactive;
const EditorInterface = editor_iface_mod.EditorInterface;
const CombinedAutocompleteProvider = autocomplete_mod.CombinedAutocompleteProvider;

pub fn prepareTerminal(self: *Interactive) !void {
    try self.tui.terminal.enterRawMode();
    self.tui.terminal.installSignalHandlers();
    self.tui.terminal.hideCursor();
    self.tui.terminal.enableBracketedPaste();
    self.tui.terminal.enableModifyOtherKeys();
    self.tui.terminal.queryKittyProtocol();
    self.tui.terminal.enableMouseTracking();
    self.kitty_deadline_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + 150_000_000;
}

pub fn suspendTerminalForExternalProcess(self: *Interactive) void {
    self.tui.terminal.showCursor();
    self.tui.terminal.disableMouseTracking();
    self.tui.terminal.disableBracketedPaste();
    if (self.tui.terminal.kitty_active) self.tui.terminal.disableKittyProtocol();
    if (self.tui.terminal.modify_other_keys_active) self.tui.terminal.disableModifyOtherKeys();
    self.tui.terminal.exitRawMode();
}

pub fn resumeTerminalAfterExternalProcess(self: *Interactive) !void {
    try self.tui.terminal.enterRawMode();
    self.tui.terminal.installSignalHandlers();
    self.tui.terminal.hideCursor();
    self.tui.terminal.enableBracketedPaste();
    self.tui.terminal.enableModifyOtherKeys();
    self.tui.terminal.queryKittyProtocol();
    self.tui.terminal.enableMouseTracking();
    self.tui.terminal.updateSize();
    self.tui.terminal.clearScreen();
    self.tui.renderer.forceRedraw();
    self.tui.dirty = true;
    self.kitty_deadline_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + 150_000_000;
}

pub fn bindEditor(self: *Interactive) void {
    self.active_editor = EditorInterface.init(editor_mod.Editor, &self.editor);
    self.active_editor_bound = true;
    self.active_editor.setOnSubmit(&composer_flow.onEditorSubmit, @ptrCast(self));
    self.active_editor.setOnChange(&onEditorChange, @ptrCast(self));
    self.active_editor.setTheme(self.theme);
    self.active_editor.setCwd(self.cwd);
    self.active_editor.setPaddingX(@intCast(self.settings_manager.getEditorPaddingX()));
    self.active_editor.setAutocompleteMaxVisible(@intCast(self.settings_manager.getAutocompleteMaxVisible()));
    self.active_editor.setStatusData(&self.status_data);
}

pub fn bindRuntimeEvents(self: *Interactive) void {
    self.agent_event_token = self.runtime_host.subscribeAgentEvents(&Interactive.agentEventCallback, @ptrCast(self));
    self.session_event_token = self.runtime_host.subscribeEvents(&Interactive.sessionEventCallback, @ptrCast(self));
    self.runtime_host.setExtensionOAuthRefreshDispatcher(.{
        .func = &runtime_loop.dispatchExtensionOAuthRefresh,
        .ctx = @ptrCast(self),
    });
}

pub fn bindAutocomplete(self: *Interactive) void {
    self.autocomplete_provider = CombinedAutocompleteProvider.init(self.allocator, self.io, &self.command_registry, self.cwd);
    self.autocomplete_provider_bound = true;
    self.active_editor.setAutocompleteProvider(self.autocomplete_provider.provider());
}

pub fn mountInitialTree(self: *Interactive) void {
    self.refreshPendingImageBanner();
    self.status_line.setStatusData(&self.status_data);
    self.status_line.setTheme(self.theme);

    self.tui.setFocus(self.active_editor.component());

    self.tui.root.add(self.transcript.component(), .{ .height = .{ .flex = 1 } });
    self.tui.root.addSpace(.{ .height = .{ .points = 1 } });
    self.tui.root.add(self.pending_image_banner.component(), .{});
    self.tui.root.add(self.status_line.component(), .{});
    self.tui.root.add(self.greeter.component(), .{ .visible = !self.greeter_dismissed });
    self.tui.root.add(self.extension_ui_state.editorBorderTopComponent(), .{});
    self.tui.root.add(self.active_editor.component(), .{});
    self.tui.root.add(self.extension_ui_state.editorBorderBottomComponent(), .{});
    self.tui.root.add(self.extension_ui_state.statusComponent(), .{});
}

fn onEditorChange(_: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    self.refreshHeaderVisibility();
    self.tui.dirty = true;
}
