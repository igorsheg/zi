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
    self.refreshHeaderVisibility();
    self.refreshPendingImageBanner();
    self.status_line.setStatusData(&self.status_data);
    self.status_line.setTheme(self.theme);
    self.status_container.addChild(self.status_line.component());
    self.editor_container.addChild(self.active_editor.component());
    self.editor_container.focused_child_index = 0;
    self.composer_below_container.addChild(self.extension_ui_state.statusComponent());

    self.tui.setFocus(self.active_editor.component());

    self.transcript_container.addChild(self.transcript.component());
    self.transcript_container.addChild(self.transcript_bottom_padding.component());
    self.transcript_container.flex_child_index = 0;

    self.tui.root.addChild(self.transcript_container.component());
    self.tui.root.addChild(self.pending_container.component());
    self.tui.root.addChild(self.status_container.component());
    self.tui.root.addChild(self.header_container.component());
    self.tui.root.addChild(self.composer_above_container.component());
    self.tui.root.addChild(self.editor_container.component());
    self.tui.root.addChild(self.composer_below_container.component());
    self.tui.root.flex_child_index = 0;
    self.tui.root.focused_child_index = 5;
}

fn onEditorChange(_: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    self.refreshHeaderVisibility();
    self.tui.dirty = true;
}
