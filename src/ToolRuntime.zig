const std = @import("std");
const agent = @import("agent/root.zig");
const tool = @import("tool/root.zig");

const Read = tool.Read.Read;
const Edit = tool.Edit.Edit;
const Write = tool.Write.Write;
const Bash = tool.Bash.Bash;
const TaskRegistry = tool.TaskRegistry.TaskRegistry;
const TaskWait = tool.TaskWait.TaskWait;
const Tool = tool.Tool.Tool;
const Loop = agent.Loop;
const Session = agent.Session.Session;

pub const InitError = error{ OutOfMemory, InvalidConfig };
pub const BindingError = error{ Reentrant, PendingDurability };
pub const FinishError = agent.Session.Error || tool.TaskRegistry.Error || error{
    PendingDurability,
    HookFailed,
    HookIndeterminate,
};

/// Explicit process snapshots and per-tool policy used to build one runtime.
/// All slices and `environ` are borrowed only for `init`. The allocator, `std.Io`
/// userdata, Bash clock context, and task clock/poller contexts must outlive the
/// Owner. None of those callbacks may reenter this Owner or deinitialize it.
pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    home: ?[]const u8,
    path_env: ?[]const u8,
    clock: ?tool.TaskRegistry.Clock = null,
    poller: ?tool.TaskRegistry.Poller = null,
    task_config: tool.TaskRegistry.Config = .{},
    read_config: tool.Read.Config = .{},
    edit_config: tool.Edit.Config = .{},
    write_config: tool.Write.Config = .{},
    bash_config: tool.Bash.Config = .{},
    run_selection: ?tool.Bash.RunSelection = null,
    parent_subagent_depth: u8 = 0,
    enable_tools: bool = true,
    enable_tasks: bool = true,
};

const TaskNotesState = struct {
    registry: *TaskRegistry,
    seam: ?Loop.SeamHook = null,
    seam_configured: bool = false,
    session: ?*Session = null,
    pending_note: ?tool.TaskRegistry.Note = null,
    pending_flush: bool = false,
    active: bool = false,

    fn deinit(self: *TaskNotesState, allocator: std.mem.Allocator) void {
        if (self.pending_note) |*note| note.deinit(allocator);
        self.* = undefined;
    }

    pub fn call(self: *TaskNotesState, session: *Session) Loop.HookError!void {
        self.enter(session) catch return error.Failed;
        defer self.active = false;

        if (self.pending_flush) {
            try flushTaskNote(self.seam, session);
            self.pending_flush = false;
        }

        if (self.pending_note == null) {
            self.pending_note = self.registry.collectNotes() catch |err| return mapTaskHookError(err);
        }
        if (self.pending_note) |*note| {
            session.addTaskNote(note.text) catch |err| return mapSessionHookError(err);
            note.deinit(self.registry.allocator);
            self.pending_note = null;
            self.pending_flush = true;
            try flushTaskNote(self.seam, session);
            self.pending_flush = false;
        }
        return;
    }

    fn configureSeam(self: *TaskNotesState, seam: ?Loop.SeamHook) BindingError!void {
        if (self.active) return error.Reentrant;
        if (!self.seam_configured) {
            self.seam = seam;
            self.seam_configured = true;
            return;
        }
        if (!sameSeam(self.seam, seam)) return error.PendingDurability;
    }

    fn enter(self: *TaskNotesState, session: *Session) BindingError!void {
        if (self.active) return error.Reentrant;
        if (self.session) |bound| {
            if (bound != session) return error.PendingDurability;
        } else {
            self.session = session;
        }
        self.active = true;
    }
};

/// Heap-stable, move-only composition of the built-in tools. Move this handle,
/// but do not copy it or deinitialize two copies. Erased tool and hook handles
/// borrow heap objects owned here and become invalid after `deinit`.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    home: ?[]u8,
    path_env: ?[]u8,
    read: *Read,
    edit: *Edit,
    write: *Write,
    bash: *Bash,
    registry: ?*TaskRegistry,
    task_wait: ?*TaskWait,
    task_notes: ?*TaskNotesState,
    tool_handles: [5]Tool,
    tool_count: usize,

    /// Returns the enabled tools in exact advertised order.
    pub fn tools(self: *Owner) []const Tool {
        return self.tool_handles[0..self.tool_count];
    }

    /// Returns Bash's resolved command shell borrowed until `deinit`.
    /// The slice remains stable when this move-only Owner handle is moved.
    pub fn commandShell(self: *const Owner) []const u8 {
        return self.bash.commandShell();
    }

    /// Returns a borrowed registry for observation and job adoption. The caller
    /// must not call `deinit`; this Owner retains shutdown and destruction rights.
    pub fn taskRegistry(self: *Owner) ?*TaskRegistry {
        return self.registry;
    }

    /// Returns a stable erased pre-request hook and permanently binds its seam
    /// identity. Repeating the same seam is allowed; replacing it, including
    /// with/from null, is rejected because prior mutation may still need flush.
    pub fn taskNotesHook(
        self: *Owner,
        seam: ?Loop.SeamHook,
    ) BindingError!?Loop.PreRequestHook {
        const state = self.task_notes orelse return null;
        try state.configureSeam(seam);
        return Loop.PreRequestHook.from(state);
    }

    /// Idempotently terminates all tasks. This runs before Bash teardown.
    /// Reentry from a runtime callback is rejected without touching the registry.
    pub fn shutdown(self: *Owner) tool.TaskRegistry.Error!void {
        if (self.task_notes) |state| if (state.active) return error.Reentrant;
        if (self.registry) |registry| try registry.shutdown();
    }

    /// Collects the terminal task note, durably flushes it, and always shuts
    /// down tasks. A durability-indeterminate result takes precedence over a
    /// later shutdown error; otherwise the first note/flush error is retained.
    pub fn finish(self: *Owner, session: *Session, seam: ?Loop.SeamHook) FinishError!void { // ziglint-ignore: Z015
        if (self.task_notes) |state| {
            try state.configureSeam(seam);
            if (state.active) return error.Reentrant;
            if (state.session) |bound| {
                if (bound != session) return error.PendingDurability;
            } else {
                state.session = session;
            }
        }

        var work_error: ?FinishError = null;
        self.finishNotes(session) catch |err| {
            work_error = err;
        };

        var shutdown_error: ?tool.TaskRegistry.Error = null;
        self.shutdown() catch |err| {
            shutdown_error = err;
        };

        if (work_error) |err| return err;
        if (shutdown_error) |err| return err;
    }

    fn finishNotes(self: *Owner, session: *Session) FinishError!void {
        const state = self.task_notes orelse return;
        try state.enter(session);
        defer state.active = false;
        if (state.pending_flush) {
            try flushFinish(state.seam, session);
            state.pending_flush = false;
        }
        if (state.pending_note) |*pending| {
            try session.addTaskNote(pending.text);
            pending.deinit(self.allocator);
            state.pending_note = null;
            state.pending_flush = true;
            try flushFinish(state.seam, session);
            state.pending_flush = false;
        }

        state.pending_note = try state.registry.exitNote();
        if (state.pending_note) |*note| {
            try session.addTaskNote(note.text);
            note.deinit(self.allocator);
            state.pending_note = null;
            state.pending_flush = true;
            try flushFinish(state.seam, session);
            state.pending_flush = false;
        }
    }

    /// Destroys the registry before Bash, as required by Bash's borrowed
    /// registry contract. Call `shutdown` first when its typed error matters.
    /// Calling this from any injected callback is a programmer bug and panics
    /// before any owned memory is freed.
    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        if (self.task_notes) |state| if (state.active) {
            @panic("ToolRuntime.Owner.deinit called from a runtime callback");
        };
        if (self.task_notes) |state| {
            state.deinit(self.allocator);
            self.allocator.destroy(state);
        }
        if (self.task_wait) |task_wait| self.allocator.destroy(task_wait);
        if (self.registry) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
        }
        self.bash.deinit();
        self.allocator.destroy(self.bash);
        self.allocator.destroy(self.write);
        self.allocator.destroy(self.edit);
        self.allocator.destroy(self.read);
        if (self.path_env) |path_env| self.allocator.free(path_env);
        if (self.home) |home| self.allocator.free(home);
        self.* = undefined;
    }
};

pub fn init(inputs: Inputs) InitError!Owner {
    const home = if (inputs.home) |value| try inputs.allocator.dupe(u8, value) else null;
    errdefer if (home) |value| inputs.allocator.free(value);
    const path_env = if (inputs.path_env) |value| try inputs.allocator.dupe(u8, value) else null;
    errdefer if (path_env) |value| inputs.allocator.free(value);

    const tasks_enabled = inputs.enable_tools and inputs.enable_tasks;
    const registry = if (tasks_enabled) blk: {
        const clock = inputs.clock orelse return error.InvalidConfig;
        const poller = inputs.poller orelse return error.InvalidConfig;
        const value = tool.TaskRegistry.TaskRegistry.init(
            inputs.allocator,
            clock,
            poller,
            inputs.task_config,
        ) catch return error.InvalidConfig;
        const pointer = try inputs.allocator.create(TaskRegistry);
        pointer.* = value;
        break :blk pointer;
    } else null;
    errdefer if (registry) |value| {
        value.deinit();
        inputs.allocator.destroy(value);
    };

    const read = try inputs.allocator.create(Read);
    errdefer inputs.allocator.destroy(read);
    var read_config = inputs.read_config;
    read_config.home = home;
    read_config.path_env = path_env;
    read.* = .{ .config = read_config };

    const edit = try inputs.allocator.create(Edit);
    errdefer inputs.allocator.destroy(edit);
    var edit_config = inputs.edit_config;
    edit_config.home = home;
    edit.* = .{ .config = edit_config };

    const write = try inputs.allocator.create(Write);
    errdefer inputs.allocator.destroy(write);
    var write_config = inputs.write_config;
    write_config.home = home;
    write.* = .{ .config = write_config };

    const task_wait = if (registry) |value| blk: {
        const pointer = try inputs.allocator.create(TaskWait);
        pointer.* = .{ .registry = value };
        break :blk pointer;
    } else null;
    errdefer if (task_wait) |value| inputs.allocator.destroy(value);

    const task_notes = if (registry) |value| blk: {
        const pointer = try inputs.allocator.create(TaskNotesState);
        pointer.* = .{ .registry = value };
        break :blk pointer;
    } else null;
    errdefer if (task_notes) |value| inputs.allocator.destroy(value);

    const bash = try inputs.allocator.create(Bash);
    errdefer inputs.allocator.destroy(bash);
    var bash_config = inputs.bash_config;
    bash_config.environment = inputs.environ;
    bash_config.run_selection = inputs.run_selection;
    bash_config.parent_subagent_depth = inputs.parent_subagent_depth;
    bash_config.task_registry = registry;
    bash.* = try Bash.init(inputs.allocator, inputs.io, bash_config);

    var handles: [5]Tool = undefined;
    var count: usize = 0;
    if (inputs.enable_tools) {
        handles[count] = read.tool();
        count += 1;
        handles[count] = edit.tool();
        count += 1;
        handles[count] = write.tool();
        count += 1;
        handles[count] = bash.tool();
        count += 1;
        if (task_wait) |value| {
            handles[count] = value.tool();
            count += 1;
        }
    }

    return .{
        .allocator = inputs.allocator,
        .home = home,
        .path_env = path_env,
        .read = read,
        .edit = edit,
        .write = write,
        .bash = bash,
        .registry = registry,
        .task_wait = task_wait,
        .task_notes = task_notes,
        .tool_handles = handles,
        .tool_count = count,
    };
}

fn sameSeam(a: ?Loop.SeamHook, b: ?Loop.SeamHook) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.context == b.?.context and a.?.call_fn == b.?.call_fn;
}

fn flushTaskNote(seam: ?Loop.SeamHook, session: *const Session) Loop.HookError!void {
    const hook = seam orelse return;
    try hook.call(session, .task_note, true);
}

fn flushFinish(seam: ?Loop.SeamHook, session: *const Session) FinishError!void {
    const hook = seam orelse return;
    hook.call(session, .task_note, false) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.HookFailed,
        error.Indeterminate => error.HookIndeterminate,
    };
}

fn mapTaskHookError(err: tool.TaskRegistry.Error) Loop.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

fn mapSessionHookError(err: agent.Session.Error) Loop.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

const TestClock = struct {
    now_ms: i64 = 0,

    pub fn nowMs(self: *TestClock) i64 {
        return self.now_ms;
    }
};

const TestPoller = struct {
    pub fn wait(_: *TestPoller, _: u64) void {}
};

fn testInputs(allocator: std.mem.Allocator) Inputs {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .home = "/tmp/home",
        .path_env = "/bin:/usr/bin",
        .enable_tasks = false,
    };
}

test "owner advertises exact fixed order and disabled modes are empty or synchronous" {
    var synchronous = try init(testInputs(std.testing.allocator));
    defer synchronous.deinit();
    try std.testing.expectEqual(@as(usize, 4), synchronous.tools().len);
    for (synchronous.tools(), [_][]const u8{ "read", "edit", "write", "bash" }) |handle, name| {
        try std.testing.expectEqualStrings(name, handle.advertised().?.name);
    }
    try std.testing.expectEqual(@as(usize, 2), synchronous.tools()[3].definition.parameters.len);
    try std.testing.expect(synchronous.taskRegistry() == null);
    try std.testing.expect((try synchronous.taskNotesHook(null)) == null);

    var disabled_inputs = testInputs(std.testing.allocator);
    disabled_inputs.enable_tools = false;
    disabled_inputs.enable_tasks = true;
    var disabled = try init(disabled_inputs);
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 0), disabled.tools().len);
    try std.testing.expect(disabled.taskRegistry() == null);
}

test "task mode appends task wait and owner moves without invalidating erased addresses" {
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    var inputs = testInputs(std.testing.allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(&clock);
    inputs.poller = tool.TaskRegistry.Poller.from(&poller);
    const original = try init(inputs);
    const read_address = original.read;
    const bash_address = original.bash;
    const shell = original.commandShell();
    const shell_address = shell.ptr;
    const registry_address = original.registry.?;
    var moved = original;
    defer moved.deinit();

    try std.testing.expectEqual(@as(usize, 5), moved.tools().len);
    for (moved.tools(), [_][]const u8{ "read", "edit", "write", "bash", "task_wait" }) |handle, name| {
        try std.testing.expectEqualStrings(name, handle.advertised().?.name);
    }
    try std.testing.expectEqual(@intFromPtr(read_address), @intFromPtr(moved.tools()[0].context));
    try std.testing.expectEqual(@intFromPtr(bash_address), @intFromPtr(moved.tools()[3].context));
    try std.testing.expectEqualStrings(shell, moved.commandShell());
    try std.testing.expectEqual(@intFromPtr(shell_address), @intFromPtr(moved.commandShell().ptr));
    try std.testing.expectEqual(@intFromPtr(registry_address), @intFromPtr(moved.taskRegistry().?));
    try std.testing.expectEqual(@as(usize, 4), moved.tools()[3].definition.parameters.len);
}

test "pre-request hook appends notes before durability and never duplicates after hook failure" {
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        fail: bool = true,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: Loop.SeamKind,
            next_action: bool,
        ) Loop.HookError!void {
            if (kind != .task_note or !next_action) return error.Failed;
            if (session.items().len != 1) return error.Failed;
            if (session.items()[0] != .user_message) return error.Failed;
            if (session.items()[0].user_message.origin != .task_note) return error.Failed;
            self.calls += 1;
            if (self.fail) return error.Failed;
        }
    };
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    var inputs = testInputs(std.testing.allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(&clock);
    inputs.poller = tool.TaskRegistry.Poller.from(&poller);
    var owner = try init(inputs);
    defer owner.deinit();
    owner.task_notes.?.pending_note = .{
        .text = try std.testing.allocator.dupe(u8, "[task t1 exited 0]"),
    };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var seam: Seam = .{};
    const hook = (try owner.taskNotesHook(Loop.SeamHook.from(&seam))).?;
    try std.testing.expectError(error.Failed, hook.call(&session));
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    seam.fail = false;
    try hook.call(&session);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expectEqual(@as(usize, 2), seam.calls);
}

fn exerciseInitAllocationFailures(allocator: std.mem.Allocator) !void {
    var owner = try init(testInputs(allocator));
    owner.deinit();
}

test "initialization releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInitAllocationFailures,
        .{},
    );
}

fn exerciseTaskInitAllocationFailures(
    allocator: std.mem.Allocator,
    clock: *TestClock,
    poller: *TestPoller,
) !void {
    var inputs = testInputs(allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(clock);
    inputs.poller = tool.TaskRegistry.Poller.from(poller);
    var owner = try init(inputs);
    owner.deinit();
}

test "task-enabled initialization releases every partial allocation" {
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTaskInitAllocationFailures,
        .{ &clock, &poller },
    );
}

test "task hook permanently binds seam and session identities" {
    const Seam = struct {
        const Self = @This();
        identity: u8,
        pub fn call(_: *Self, _: *const Session, _: Loop.SeamKind, _: bool) Loop.HookError!void {}
    };
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    var inputs = testInputs(std.testing.allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(&clock);
    inputs.poller = tool.TaskRegistry.Poller.from(&poller);
    var owner = try init(inputs);
    defer owner.deinit();
    var seam_a: Seam = .{ .identity = 1 };
    var seam_b: Seam = .{ .identity = 2 };
    const erased_a = Loop.SeamHook.from(&seam_a);
    const hook = (try owner.taskNotesHook(erased_a)).?;
    _ = try owner.taskNotesHook(erased_a);
    try std.testing.expectError(error.PendingDurability, owner.taskNotesHook(Loop.SeamHook.from(&seam_b)));
    try std.testing.expectError(error.PendingDurability, owner.taskNotesHook(null));

    var session_a = try Session.init(std.testing.allocator, .{});
    defer session_a.deinit();
    var session_b = try Session.init(std.testing.allocator, .{});
    defer session_b.deinit();
    try hook.call(&session_a);
    try std.testing.expectError(error.Failed, hook.call(&session_b));
    try std.testing.expectError(error.PendingDurability, owner.finish(&session_b, erased_a));
}

test "nested finish is typed reentry and does not invalidate the outer task callback" {
    const Seam = struct {
        const Self = @This();
        owner: *Owner,
        session: *Session,
        erased: ?Loop.SeamHook = null,
        nested_error: ?FinishError = null,

        pub fn call(
            self: *Self,
            _: *const Session,
            kind: Loop.SeamKind,
            next_action: bool,
        ) Loop.HookError!void {
            if (kind != .task_note or !next_action) return error.Failed;
            self.owner.finish(self.session, self.erased) catch |err| {
                self.nested_error = err;
                return;
            };
            return error.Failed;
        }
    };
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    var inputs = testInputs(std.testing.allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(&clock);
    inputs.poller = tool.TaskRegistry.Poller.from(&poller);
    var owner = try init(inputs);
    defer owner.deinit();
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var seam: Seam = .{ .owner = &owner, .session = &session };
    seam.erased = Loop.SeamHook.from(&seam);
    const hook = (try owner.taskNotesHook(seam.erased)).?;
    owner.task_notes.?.pending_note = .{
        .text = try std.testing.allocator.dupe(u8, "[task t1 exited 0]"),
    };
    try hook.call(&session);
    try std.testing.expectEqual(error.Reentrant, seam.nested_error.?);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try owner.shutdown();
}

test "terminal indeterminate flush wins and retry does not duplicate the note" {
    const Seam = struct {
        const Self = @This();
        fail: bool = true,
        calls: usize = 0,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: Loop.SeamKind,
            next_action: bool,
        ) Loop.HookError!void {
            if (kind != .task_note or next_action) return error.Failed;
            if (session.items().len != 1) return error.Failed;
            self.calls += 1;
            if (self.fail) return error.Indeterminate;
        }
    };
    var clock: TestClock = .{};
    var poller: TestPoller = .{};
    var inputs = testInputs(std.testing.allocator);
    inputs.enable_tasks = true;
    inputs.clock = tool.TaskRegistry.Clock.from(&clock);
    inputs.poller = tool.TaskRegistry.Poller.from(&poller);
    var owner = try init(inputs);
    defer owner.deinit();
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var seam: Seam = .{};
    const erased = Loop.SeamHook.from(&seam);
    _ = try owner.taskNotesHook(erased);
    owner.task_notes.?.pending_note = .{
        .text = try std.testing.allocator.dupe(u8, "[task t1 killed at exit]"),
    };
    try std.testing.expectError(error.HookIndeterminate, owner.finish(&session, erased));
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    seam.fail = false;
    try owner.finish(&session, erased);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expectEqual(@as(usize, 2), seam.calls);
}
