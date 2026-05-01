const std = @import("std");
const posix = std.posix;
const ai_protocol = @import("../ai/protocol.zig");
const auth_types = @import("auth/types.zig");
const extension_runner = @import("extensions/runner.zig");
const extension_ui = @import("extensions/ui.zig");
const message_memory = @import("../agent/message_memory.zig");
const mailbox_mod = @import("../zio/root.zig").mailbox;

/// AgentRequest — mailbox payload for the TUI → agent mutation channel.
///
/// This is one of zi's two cross-thread mailbox-backed channels:
/// request queue here (TUI → agent) and event queue in the TUI
/// integration (agent/helper → TUI). See `docs/runtime.md`.
///
/// Direction:
///
///   TUI thread                       agent thread
///   ──────────                       ────────────
///   trySend/push(AgentRequest) ───▶  drainInto([])
///                                    dispatch by tag
///                                    publish result via UiEvent queue
///
/// Active request variants:
///   - prompt
///   - resume_session
///   - new_session
///   - set_model
///   - set_model_by_pattern
///   - set_thinking_level
///   - refresh_status_snapshot
///   - compact
///   - shutdown
///
/// Queued-message submits (steering / follow-up) do NOT go through this
/// inbox — they hit `RuntimeHost.enqueueQueuedText` on the agent's
/// run-control mailbox directly from the TUI thread, so they become
/// observable mid-stream without waiting for the owner loop to return
/// from `runUserContent`. See `docs/runtime.md` on run-scoped controls.
///
/// Ordered agent teardown uses `.shutdown` as the in-band terminal request.
/// `Interactive.deinit` enqueues that sentinel first so already-queued work
/// drains in order, then closes the mailbox transport to stop future sends and
/// wake the owner loop if it is idle.
///
/// Allocator rule (doctrine R3): every payload slice carried by an
/// AgentRequest MUST be allocated from the thread-safe `msg_allocator`,
/// not from the TUI-local state allocator or `agent_arena`. The
/// agent-thread consumer frees with the same allocator after dispatch
/// via `deinit`.
pub const ExtensionOAuthLoginCallbacks = struct {
    on_auth: *const fn (url: []const u8, ctx: ?*anyopaque) void,
    on_progress: ?*const fn (msg: []const u8, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const ExtensionPromptResponse = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: bool = false,
    result: ?Result = null,

    pub const OwnedValue = struct {
        text: []const u8,
        allocator: std.mem.Allocator,
        label: ?[]const u8 = null,
        description: ?[]const u8 = null,
        search: ?[]const u8 = null,
        preview: ?[]const u8 = null,

        pub fn deinit(self: OwnedValue) void {
            self.allocator.free(self.text);
            if (self.label) |value| self.allocator.free(value);
            if (self.description) |value| self.allocator.free(value);
            if (self.search) |value| self.allocator.free(value);
            if (self.preview) |value| self.allocator.free(value);
        }
    };

    pub const Result = union(enum) {
        confirm: bool,
        value: ?OwnedValue,
        timeout,

        pub fn deinit(self: *Result) void {
            switch (self.*) {
                .value => |maybe| if (maybe) |value| value.deinit(),
                .confirm, .timeout => {},
            }
            self.* = undefined;
        }
    };

    pub fn defaultFor(kind: extension_ui.PromptKind) Result {
        return switch (kind) {
            .confirm => .{ .confirm = false },
            .select, .input, .editor => .{ .value = null },
        };
    }

    pub fn finish(self: *ExtensionPromptResponse, result: Result) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (self.completed) return;
        self.result = result;
        self.completed = true;
        self.condition.broadcast(std.Options.debug_io);
    }

    pub fn wait(self: *ExtensionPromptResponse) Result {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        while (!self.completed) self.condition.waitUncancelable(std.Options.debug_io, &self.mutex);
        return self.result.?;
    }
};

pub const ExtensionOAuthLoginResponse = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: bool = false,
    result: ?Result = null,

    pub const Result = union(enum) {
        success: auth_types.OAuthCredential,
        cancelled,
        err: []const u8,
        unsupported,

        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .success => |*cred| auth_types.deinitOAuthCredential(allocator, cred),
                .err => |msg| allocator.free(msg),
                .cancelled, .unsupported => {},
            }
            self.* = undefined;
        }
    };

    pub fn finish(self: *ExtensionOAuthLoginResponse, result: Result) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        std.debug.assert(!self.completed);
        self.result = result;
        self.completed = true;
        self.condition.broadcast(std.Options.debug_io);
    }

    pub fn wait(self: *ExtensionOAuthLoginResponse) Result {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        while (!self.completed) {
            self.condition.waitUncancelable(std.Options.debug_io, &self.mutex);
        }
        return self.result.?;
    }
};

pub const ExtensionOAuthRefreshResponse = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: bool = false,
    result: ?Result = null,

    pub const Result = union(enum) {
        success: auth_types.OAuthCredential,
        err: []const u8,
        unsupported,

        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .success => |*cred| auth_types.deinitOAuthCredential(allocator, cred),
                .err, .unsupported => {},
            }
            self.* = undefined;
        }
    };

    pub fn finish(self: *ExtensionOAuthRefreshResponse, result: Result) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        std.debug.assert(!self.completed);
        self.result = result;
        self.completed = true;
        self.condition.broadcast(std.Options.debug_io);
    }

    pub fn wait(self: *ExtensionOAuthRefreshResponse) Result {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        while (!self.completed) {
            self.condition.waitUncancelable(std.Options.debug_io, &self.mutex);
        }
        return self.result.?;
    }
};

pub const AgentRequest = union(enum) {
    prompt: struct { content: ai_protocol.UserMessage.UserMessageContent },
    resume_session: struct {
        path: []const u8,
        restore_session_model: bool = true,
    },
    fork_session: struct {
        entry_id: []const u8,
    },
    new_session: void,
    set_model: struct { model: ai_protocol.Model },
    set_model_by_pattern: struct { pattern: []const u8 },
    set_thinking_level: struct { level: @import("../agent/types.zig").ThinkingLevel },
    refresh_status_snapshot: void,
    /// Manual compaction request — /compact. Mirrors pi-mono's
    /// `agentSession.compact(customInstructions)`. Lifecycle runs through
    /// the session-layer compaction owner path; results publish via
    /// `UiEvent`/snapshots like any other request.
    compact: struct {
        custom_instructions: ?[]const u8 = null,
    },
    /// Extension slash-command dispatch. Visible invocation name + args.
    /// Owned strings (msg_allocator); deinit frees them.
    extension_command: struct {
        name: []const u8,
        args: []const u8,
    },
    extension_keybinding: struct {
        id: []const u8,
    },
    extension_oauth_login: struct {
        provider_id: []const u8,
        callbacks: ExtensionOAuthLoginCallbacks,
        response: *ExtensionOAuthLoginResponse,
    },
    extension_oauth_refresh: struct {
        provider_id: []const u8,
        credential: auth_types.OAuthCredential,
        result_allocator: std.mem.Allocator,
        response: *ExtensionOAuthRefreshResponse,
    },
    extension_async_result: struct {
        id: extension_runner.AsyncOpId,
        result: extension_runner.AsyncResult,
    },
    shutdown: void,

    pub fn deinit(self: *AgentRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .prompt => |*p| message_memory.freeUserContent(allocator, &p.content),
            .resume_session => |r| allocator.free(r.path),
            .fork_session => |f| allocator.free(f.entry_id),
            .new_session => {},
            .set_model => {},
            .set_model_by_pattern => |m| allocator.free(m.pattern),
            .set_thinking_level => {},
            .refresh_status_snapshot => {},
            .compact => |c| if (c.custom_instructions) |ci| allocator.free(ci),
            .extension_command => |ec| {
                allocator.free(ec.name);
                allocator.free(ec.args);
            },
            .extension_keybinding => |ek| allocator.free(ek.id),
            .extension_oauth_login => |oauth| allocator.free(oauth.provider_id),
            .extension_oauth_refresh => |oauth| {
                allocator.free(oauth.provider_id);
                auth_types.freeOAuthCredential(allocator, oauth.credential);
            },
            .extension_async_result => |*async_result| async_result.result.deinit(allocator),
            .shutdown => {},
        }
    }
};

pub const request_queue_capacity: usize = 64;

pub const RequestQueue = mailbox_mod.Mailbox(AgentRequest, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = request_queue_capacity, .on_full = .reject } },
    .wakeup = .pipe,
});

test "RequestQueue round-trips a set_model_by_pattern payload" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    const pattern = try allocator.dupe(u8, "proxy-a/proxy-model");
    q.push(.{ .set_model_by_pattern = .{ .pattern = pattern } });

    var buf: [2]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("proxy-a/proxy-model", buf[0].set_model_by_pattern.pattern);
    buf[0].deinit(allocator);
}

test "RequestQueue round-trips a resume_session payload and restore policy" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    const path = try allocator.dupe(u8, "/tmp/some/session.jsonl");
    q.push(.{ .resume_session = .{
        .path = path,
        .restore_session_model = false,
    } });

    var buf: [4]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("/tmp/some/session.jsonl", buf[0].resume_session.path);
    try std.testing.expect(!buf[0].resume_session.restore_session_model);
    buf[0].deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), q.drainInto(&buf));
}

test "RequestQueue shutdown sentinel round-trips as an ordered terminal request" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    const text = try allocator.dupe(u8, "hello");
    try std.testing.expectEqual(.ok, q.trySend(.{ .prompt = .{ .content = .{ .text = text } } }));
    try std.testing.expectEqual(.ok, q.trySend(.{ .new_session = {} }));
    try std.testing.expectEqual(.ok, q.trySend(.{ .shutdown = {} }));

    var buf: [3]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    switch (buf[0].prompt.content) {
        .text => |payload| try std.testing.expectEqualStrings("hello", payload),
        else => return error.UnexpectedResult,
    }
    switch (buf[1]) {
        .new_session => {},
        else => return error.UnexpectedResult,
    }
    switch (buf[2]) {
        .shutdown => {},
        else => return error.UnexpectedResult,
    }
    for (buf[0..n]) |*req| req.deinit(allocator);
}

test "RequestQueue bounded policy rejects after capacity without disturbing pending work" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    var sent: usize = 0;
    errdefer {
        var cleanup: [request_queue_capacity]AgentRequest = undefined;
        const count = q.drainInto(&cleanup);
        for (cleanup[0..count]) |*req| req.deinit(allocator);
    }
    while (sent < request_queue_capacity) : (sent += 1) {
        const text = try std.fmt.allocPrint(allocator, "msg-{d}", .{sent});
        switch (q.trySend(.{ .prompt = .{ .content = .{ .text = text } } })) {
            .ok => {},
            .dropped, .closed, .full, .oom => unreachable,
        }
    }

    const overflow_text = try allocator.dupe(u8, "overflow");
    switch (q.trySend(.{ .prompt = .{ .content = .{ .text = overflow_text } } })) {
        .full => |rejected| {
            var failed = rejected;
            failed.deinit(allocator);
        },
        else => return error.UnexpectedResult,
    }

    const stats = q.stats();
    try std.testing.expectEqual(request_queue_capacity, stats.pending_depth);
    try std.testing.expectEqual(request_queue_capacity, stats.high_water_depth);
    try std.testing.expectEqual(request_queue_capacity, stats.send_count);
    try std.testing.expectEqual(@as(usize, 1), stats.rejected_count);
}

test "RequestQueue wake pipe stays readable until the long-lived owner drains requests" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    q.push(.{ .prompt = .{ .content = .{ .text = try allocator.dupe(u8, "hello") } } });

    var pfd = [1]posix.pollfd{.{
        .fd = q.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));
    try std.testing.expect(try q.waitReadable(0));

    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&pfd, 0));

    var buf: [2]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    switch (buf[0].prompt.content) {
        .text => |text| try std.testing.expectEqualStrings("hello", text),
        else => return error.UnexpectedResult,
    }
    buf[0].deinit(allocator);

    pfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&pfd, 0));
}

test "RequestQueue extension_command round-trips owned name and args" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    const name = try allocator.dupe(u8, "my-cmd:1");
    const args = try allocator.dupe(u8, "hello world");
    q.push(.{ .extension_command = .{ .name = name, .args = args } });

    var buf: [2]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("my-cmd:1", buf[0].extension_command.name);
    try std.testing.expectEqualStrings("hello world", buf[0].extension_command.args);
    buf[0].deinit(allocator);
}

test "RequestQueue extension_oauth_login round-trips provider id and response cell" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    var response: ExtensionOAuthLoginResponse = .{};
    const provider_id = try allocator.dupe(u8, "corp-ai");
    q.push(.{ .extension_oauth_login = .{ .provider_id = provider_id, .callbacks = .{ .on_auth = undefined }, .response = &response } });

    var buf: [2]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("corp-ai", buf[0].extension_oauth_login.provider_id);
    try std.testing.expect(buf[0].extension_oauth_login.response == &response);
    buf[0].deinit(allocator);
}

test "RequestQueue extension_oauth_refresh round-trips provider id and credential" {
    const allocator = std.testing.allocator;
    var q = try RequestQueue.init(allocator);
    defer q.deinit();

    var extras: std.json.ObjectMap = .{};
    defer extras.deinit(allocator);
    var response: ExtensionOAuthRefreshResponse = .{};
    const provider_id = try allocator.dupe(u8, "corp-ai");
    q.push(.{ .extension_oauth_refresh = .{
        .provider_id = provider_id,
        .credential = .{
            .refresh = try allocator.dupe(u8, "rt-1"),
            .access = try allocator.dupe(u8, "at-1"),
            .expires = 42,
            .extras = extras.move(),
        },
        .result_allocator = allocator,
        .response = &response,
    } });

    var buf: [2]AgentRequest = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("corp-ai", buf[0].extension_oauth_refresh.provider_id);
    try std.testing.expectEqualStrings("rt-1", buf[0].extension_oauth_refresh.credential.refresh);
    try std.testing.expect(buf[0].extension_oauth_refresh.response == &response);
    buf[0].deinit(allocator);
}

test "ExtensionOAuthLoginResponse lets a worker wait for agent-thread completion" {
    const WaitCtx = struct {
        response: *ExtensionOAuthLoginResponse,
        result: ?ExtensionOAuthLoginResponse.Result = null,
    };

    const waiter = struct {
        fn run(ctx: *WaitCtx) void {
            ctx.result = ctx.response.wait();
        }
    };

    var response: ExtensionOAuthLoginResponse = .{};
    var ctx = WaitCtx{ .response = &response };
    const thread = try std.Thread.spawn(.{}, waiter.run, .{&ctx});

    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(5 * std.time.ns_per_ms)), .awake) catch {};
    response.finish(.unsupported);
    thread.join();

    try std.testing.expect(ctx.result != null);
    switch (ctx.result.?) {
        .unsupported => {},
        else => return error.UnexpectedResult,
    }
}
