const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../../logging.zig");
const json_util = @import("../../ai/json_util.zig");
const request_mod = @import("../../coding_agent/request.zig");
const oauth_mod = @import("../../coding_agent/auth/oauth.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const runtime_process = @import("../../zio/root.zig").process;

const Interactive = @import("../interactive.zig").Interactive;
const PickerSelection = list_picker_mod.Selection;

pub fn clearEntries(self: *Interactive) void {
    var i: usize = 0;
    while (i < self.login_picker_count) : (i += 1) {
        self.login_picker_entries[i].deinit(self.msg_allocator);
    }
    self.login_picker_count = 0;
}

pub fn showPicker(self: *Interactive) void {
    clearEntries(self);

    const providers = oauth_mod.listProviders(self.msg_allocator) catch {
        self.status_line.setPrimary("failed to load OAuth providers", self.theme.fg(.@"error"));
        return;
    };
    defer self.msg_allocator.free(providers);

    var count: usize = 0;
    for (providers) |provider| {
        if (count >= self.login_picker_items.len) {
            var dropped = provider;
            dropped.deinit(self.msg_allocator);
            continue;
        }
        self.login_picker_entries[count] = provider;
        self.login_picker_items[count] = .{
            .value = provider.id,
            .label = provider.name,
            .description = null,
        };
        count += 1;
    }
    self.login_picker_count = count;

    if (count == 0) {
        self.status_line.setPrimary("no OAuth providers available", self.theme.fg(.muted));
        return;
    }

    self.configureSimplePicker(
        &self.login_picker,
        "Login",
        8,
        self.login_picker_items[0..count],
        &onProviderSelected,
        &onPickerCancel,
    );
    self.showSimplePickerOverlay(&self.login_picker_handle, &self.login_picker);
}

pub fn start(self: *Interactive, provider_id: []const u8) void {
    if (self.login_thread != null) {
        self.status_line.setPrimary("login already in progress", self.theme.fg(.warning));
        return;
    }

    const provider = oauth_mod.findProvider(provider_id) orelse {
        self.status_line.setPrimary("unknown OAuth provider", self.theme.fg(.@"error"));
        return;
    };

    self.login_cancelled.store(false, .release);

    self.status_line.setPrimary("starting login...", self.theme.fg(.muted));
    self.tui.dirty = true;

    const login_ctx = self.msg_allocator.create(Context) catch {
        self.status_line.setPrimary("failed to start login", self.theme.fg(.@"error"));
        return;
    };
    login_ctx.* = .{
        .interactive = self,
        .provider = provider,
    };

    self.login_thread = std.Thread.spawn(.{}, threadFn, .{login_ctx}) catch {
        self.msg_allocator.destroy(login_ctx);
        self.status_line.setPrimary("failed to spawn login thread", self.theme.fg(.@"error"));
        return;
    };
}

fn onProviderSelected(selection: PickerSelection, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    self.hideSimplePickerOverlay(&self.login_picker_handle);
    start(self, selection.item.value);
}

fn onPickerCancel(ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    self.hideSimplePickerOverlay(&self.login_picker_handle);
}

const Context = struct {
    interactive: *Interactive,
    provider: oauth_mod.OAuthProvider,
};

fn threadFn(ctx: *Context) void {
    logging.setThreadLabel(.login);

    const self = ctx.interactive;
    const provider = ctx.provider;
    self.msg_allocator.destroy(ctx);

    const result: oauth_mod.LoginResult = if (!provider.kind.usesExtensionLogin())
        oauth_mod.login(
            self.msg_allocator,
            provider,
            .{
                .on_auth = &onAuth,
                .on_progress = &onProgress,
                .ctx = @ptrCast(self),
            },
            &self.login_cancelled,
        )
    else blk: {
        var response: request_mod.ExtensionOAuthLoginResponse = .{};
        const provider_copy = self.msg_allocator.dupe(u8, provider.id) catch break :blk .{ .err = "out of memory" };
        switch (self.request_queue.trySend(.{ .extension_oauth_login = .{
            .provider_id = provider_copy,
            .callbacks = .{
                .on_auth = &onAuth,
                .on_progress = &onProgress,
                .ctx = @ptrCast(self),
            },
            .response = &response,
        } })) {
            .ok => {},
            .full => |rejected| {
                var req = rejected;
                req.deinit(self.msg_allocator);
                break :blk .{ .err = "login request queue is full" };
            },
            .closed => |rejected| {
                var req = rejected;
                req.deinit(self.msg_allocator);
                break :blk .{ .err = "login request queue is closed" };
            },
            .oom => break :blk .{ .err = "out of memory" },
            .dropped => unreachable,
        }
        const result_from_agent: oauth_mod.LoginResult = switch (response.wait()) {
            .success => |cred| .{ .success = cred },
            .cancelled => .cancelled,
            .err => |msg| .{ .err = msg },
            .unsupported => .{ .err = "extension OAuth login is unsupported for this provider" },
        };
        break :blk result_from_agent;
    };

    const provider_id = self.msg_allocator.dupe(u8, provider.id) catch return;
    switch (result) {
        .success => |cred| {
            self.auth_storage.set(provider.id, .{ .oauth = cred });
            self.msg_allocator.free(cred.refresh);
            self.msg_allocator.free(cred.access);
            var extras = cred.extras;
            var eit = extras.iterator();
            while (eit.next()) |e| {
                self.msg_allocator.free(e.key_ptr.*);
                json_util.freeJsonValue(self.msg_allocator, e.value_ptr.*);
            }
            extras.deinit(self.msg_allocator);
            _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                .provider_id = provider_id,
                .success = true,
                .message = self.msg_allocator.dupe(u8, "logged in") catch return,
            } });
        },
        .cancelled => {
            _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                .provider_id = provider_id,
                .success = false,
                .message = self.msg_allocator.dupe(u8, "login cancelled") catch return,
            } });
        },
        .err => |msg| {
            _ = self.publishLifecycleUiEvent(.{ .login_complete = .{
                .provider_id = provider_id,
                .success = false,
                .message = self.msg_allocator.dupe(u8, msg) catch return,
            } });
        },
    }
}

// These run on the login thread. They must not touch TUI-owned state directly;
// publish UI events for the TUI thread to consume instead.
fn onAuth(url: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));

    var result = runtime_process.run(std.heap.page_allocator, std.Options.debug_io, .{
        .argv = if (builtin.os.tag == .macos)
            &.{ "open", url }
        else
            &.{ "xdg-open", url },
        .capture_stdout = false,
        .capture_stderr = false,
        .timeout_ms = 5000,
    });
    defer result.deinit(std.heap.page_allocator);

    const msg = self.msg_allocator.dupe(u8, "login: check your browser") catch return;
    _ = self.publishSnapshotUiEvent(.{ .login_progress = .{ .message = msg, .kind = .auth_url } });
}

fn onProgress(msg: []const u8, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    const owned = self.msg_allocator.dupe(u8, msg) catch return;
    _ = self.publishSnapshotUiEvent(.{ .login_progress = .{ .message = owned, .kind = .info } });
}
