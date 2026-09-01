//! Provider- and configuration-independent synchronous one-shot execution.
//!
//! Startup owns resolution and process policy. This module only coordinates one
//! already-materialized session, provider, lifecycle seams, and borrowed writers.

const std = @import("std");
const DiagnosticText = @import("DiagnosticText.zig");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");

pub const max_turns: usize = 100;
pub const catalog_drain_ms: u64 = 3_000;

const ansi_dim = "\x1b[2m";
const ansi_reset = "\x1b[0m";

pub const CallbackError = error{
    OutOfMemory,
    Failed,
    Indeterminate,
    InvalidPlan,
};

pub const RenderError = CallbackError || std.Io.Writer.Error;
pub const Error = agent.Session.Error || agent.Loop.Error || CallbackError || std.Io.Writer.Error;

/// Borrowed values used by both the start banner and the final resume hint.
pub const SessionInfo = struct {
    preset: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    provider_autoselected: bool = false,
    resumed: bool = false,
    /// Set only after the session has a durable, externally resumable identity.
    materialized_session: ?[]const u8 = null,
};

/// May materialize a lazy session identity. Returned slices remain borrowed
/// until `run` returns. This callback runs after the prompt durability seam.
pub const SessionInfoHook = struct {
    context: *anyopaque,
    get_fn: *const fn (*anyopaque) CallbackError!SessionInfo,

    pub fn get(self: SessionInfoHook) CallbackError!SessionInfo {
        return self.get_fn(self.context);
    }

    pub fn from(implementation: anytype) SessionInfoHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("SessionInfoHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn get(context: *anyopaque) CallbackError!SessionInfo {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.get();
            }
        };
        return .{ .context = implementation, .get_fn = Adapter.get };
    }
};

pub const PrefetchOutcome = union(enum) {
    started,
    unavailable,
    warning: []const u8,
};

/// Starts catalog refresh without waiting. Refresh failure is advisory and
/// never changes the one-shot exit status. Warning text is synchronously borrowed.
///
/// The erased context and its asynchronous owner must outlive `run`. `drain`
/// is idempotent and only waits; it does not destroy the owner. The production
/// caller must unconditionally cancel/join/shutdown the catalog after provider
/// teardown on every return path. That cleanup order does not belong here.
pub const CatalogHook = struct {
    context: *anyopaque,
    prefetch_fn: *const fn (*anyopaque) CallbackError!PrefetchOutcome,
    drain_fn: *const fn (*anyopaque, u64) CallbackError!?ai.ModelMeta.Metadata,
    current_metadata_fn: *const fn (*anyopaque) ?ai.ModelMeta.Metadata,

    pub fn prefetch(self: CatalogHook) CallbackError!PrefetchOutcome {
        return self.prefetch_fn(self.context);
    }

    pub fn drain(self: CatalogHook, maximum_wait_ms: u64) CallbackError!?ai.ModelMeta.Metadata {
        return self.drain_fn(self.context, maximum_wait_ms);
    }

    pub fn currentMetadata(self: CatalogHook) ?ai.ModelMeta.Metadata {
        return self.current_metadata_fn(self.context);
    }

    pub fn from(implementation: anytype) CatalogHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("CatalogHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn prefetch(context: *anyopaque) CallbackError!PrefetchOutcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.prefetch();
            }

            fn drain(
                context: *anyopaque,
                maximum_wait_ms: u64,
            ) CallbackError!?ai.ModelMeta.Metadata {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.drain(maximum_wait_ms);
            }

            fn currentMetadata(context: *anyopaque) ?ai.ModelMeta.Metadata {
                if (!@hasDecl(Implementation, "currentMetadata")) return null;
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.currentMetadata();
            }
        };
        return .{
            .context = implementation,
            .prefetch_fn = Adapter.prefetch,
            .drain_fn = Adapter.drain,
            .current_metadata_fn = Adapter.currentMetadata,
        };
    }
};

/// Finalizes task notes, their durability, and task shutdown as one lifecycle
/// operation. Implementations must always attempt shutdown, even when note
/// collection or durability fails, and must report durability ambiguity as
/// `error.Indeterminate`.
///
/// Error precedence is explicit: a terminal-only error is returned. When an
/// earlier operation already failed, terminal `Indeterminate` wins; every other
/// terminal error leaves the original error intact. `finish` is called exactly once.
pub const TerminalHook = struct {
    context: *anyopaque,
    finish_fn: *const fn (
        *anyopaque,
        *agent.Session.Session,
        ?agent.Loop.SeamHook,
    ) CallbackError!void,

    pub fn finish(
        self: TerminalHook,
        session: *agent.Session.Session,
        seam_hook: ?agent.Loop.SeamHook,
    ) CallbackError!void {
        return self.finish_fn(self.context, session, seam_hook);
    }

    pub fn from(implementation: anytype) TerminalHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("TerminalHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn finish(
                context: *anyopaque,
                session: *agent.Session.Session,
                seam_hook: ?agent.Loop.SeamHook,
            ) CallbackError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.finish(session, seam_hook);
            }
        };
        return .{ .context = implementation, .finish_fn = Adapter.finish };
    }
};

/// Renders one complete stats line. When `style_diagnostics` is true the
/// implementation may emit ANSI dim/reset. On renderer failure the kernel makes
/// a best-effort reset so a partial escape sequence does not leak terminal state.
pub const StatsRenderer = struct {
    context: *anyopaque,
    render_fn: *const fn (
        *anyopaque,
        *std.Io.Writer,
        *const agent.UsageStats.UsageStats,
        u64,
        bool,
    ) RenderError!void,

    // ziglint-ignore: Z015
    pub fn render(
        self: StatsRenderer,
        writer: *std.Io.Writer,
        stats: *const agent.UsageStats.UsageStats,
        elapsed_ms: u64,
        style_diagnostics: bool,
    ) RenderError!void {
        return self.render_fn(self.context, writer, stats, elapsed_ms, style_diagnostics);
    }

    pub fn from(implementation: anytype) StatsRenderer {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("StatsRenderer.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn render(
                context: *anyopaque,
                writer: *std.Io.Writer,
                stats: *const agent.UsageStats.UsageStats,
                elapsed_ms: u64,
                style_diagnostics: bool,
            ) RenderError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.render(writer, stats, elapsed_ms, style_diagnostics);
            }
        };
        return .{ .context = implementation, .render_fn = Adapter.render };
    }
};

pub const Inputs = struct {
    session: *agent.Session.Session,
    provider: ai.Provider.Provider,
    model: []const u8,
    model_metadata: ai.ModelMeta.Metadata = .{},
    model_metadata_source: ?agent.ModelMetadataSource.ModelMetadataSource = null,
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool = &.{},
    effort: ?[]const u8 = null,
    image_input: ai.Provider.ImageInput = .unknown,
    image_input_source: ?agent.ImageInputSource.ImageInputSource = null,
    prompt: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    seam_hook: ?agent.Loop.SeamHook = null,
    pre_request_hook: ?agent.Loop.PreRequestHook = null,
    continuation_hook: ?agent.Loop.ContinuationHook = null,
    usage_stats: *agent.UsageStats.UsageStats,
    session_info_hook: ?SessionInfoHook = null,
    catalog_hook: ?CatalogHook = null,
    terminal_hook: ?TerminalHook = null,
    stats_renderer: ?StatsRenderer = null,
    style_diagnostics: bool = false,
};

/// Returns the process exit status. A completed empty response is successful.
// ziglint-ignore: Z015
pub fn run(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) Error!u8 {
    const before = runBeforeFinish(allocator, io, inputs) catch |original_error| {
        if (inputs.terminal_hook) |terminal| {
            terminal.finish(inputs.session, inputs.seam_hook) catch |finish_error| {
                if (finish_error == error.Indeterminate) return error.Indeterminate;
            };
        }
        return original_error;
    };

    if (inputs.terminal_hook) |terminal| {
        try terminal.finish(inputs.session, inputs.seam_hook);
    }

    // Catalog completion is advisory. It may improve pricing, but cannot erase
    // an already completed answer or a provider diagnostic.
    if (inputs.catalog_hook) |catalog| {
        const catalog_wait_ms: u64 = if (inputs.usage_stats.has_unpriced) catalog_drain_ms else 0;
        const refreshed = catalog.drain(catalog_wait_ms) catch |err| refresh: {
            ignoreCatalogError(err);
            break :refresh null;
        };
        if (refreshed) |metadata| inputs.usage_stats.reprice(&metadata);
    }

    // Keep answers ahead of diagnostics when both writers share a destination.
    try inputs.stdout.flush();
    const have_stats = inputs.usage_stats.last_ordinary_context_tokens != null or
        inputs.usage_stats.spend_usd > 0;
    if (have_stats or before.info.materialized_session != null) {
        try inputs.stderr.writeByte('\n');
        if (have_stats) if (inputs.stats_renderer) |renderer| {
            const finished_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
            const elapsed_ms: u64 = @intCast(@max(0, finished_ns - before.started_ns) / std.time.ns_per_ms);
            renderer.render(
                inputs.stderr,
                inputs.usage_stats,
                elapsed_ms,
                inputs.style_diagnostics,
            ) catch |err| {
                if (inputs.style_diagnostics) resetBestEffort(inputs.stderr);
                return err;
            };
        };
        if (before.info.materialized_session) |hint| {
            try printResumeHint(inputs.stderr, hint, inputs.style_diagnostics);
        }
    }
    return before.exit_code;
}

const BeforeFinish = struct {
    exit_code: u8,
    info: SessionInfo,
    started_ns: i128,
};

fn runBeforeFinish(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) Error!BeforeFinish {
    const stable_effort = if (inputs.effort) |effort| try allocator.dupe(u8, effort) else null;
    defer if (stable_effort) |effort| allocator.free(effort);

    // addUser reserves and commits both items together. If it fails, no partial
    // prompt is visible. A seam error after it remains intentionally ambiguous.
    try inputs.session.addUser(inputs.prompt);
    try callSeam(inputs, .prompt);

    const info = if (inputs.session_info_hook) |hook| try hook.get() else SessionInfo{};
    try printBanner(inputs, info);

    const started_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var model_metadata = inputs.model_metadata;
    if (inputs.catalog_hook) |catalog| {
        const prefetch = catalog.prefetch() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Indeterminate => return error.Indeterminate,
            error.Failed => null,
            error.InvalidPlan => return error.InvalidPlan,
        };
        if (prefetch) |outcome| switch (outcome) {
            .started, .unavailable => {},
            .warning => |warning| {
                try inputs.stderr.writeAll("zi: warning: ");
                try DiagnosticText.write(inputs.stderr, warning);
                try inputs.stderr.writeByte('\n');
            },
        };
        if (catalog.currentMetadata()) |metadata| model_metadata = metadata;
    }

    var loop_result = try agent.Loop.run(allocator, io, .{
        .session = inputs.session,
        .provider = inputs.provider,
        .model = inputs.model,
        .model_metadata = model_metadata,
        .model_metadata_source = inputs.model_metadata_source,
        .system_prompt = inputs.system_prompt,
        .tools = inputs.tools,
        .effort = stable_effort,
        .image_input = inputs.image_input,
        .image_input_source = inputs.image_input_source,
        .max_turns = max_turns,
        .seam_hook = inputs.seam_hook,
        .usage_observer = agent.Loop.UsageObserver.from(inputs.usage_stats),
        .pre_request_hook = inputs.pre_request_hook,
        .continuation_hook = inputs.continuation_hook,
    });
    defer loop_result.deinit(allocator);

    const exit_code: u8 = switch (loop_result.outcome) {
        .complete => complete: {
            try printFinalMessages(inputs.stdout, inputs.session.items(), loop_result);
            break :complete 0;
        },
        .provider_error => failure: {
            try inputs.stderr.writeAll("zi: provider error: ");
            try DiagnosticText.write(inputs.stderr, loop_result.diagnostic orelse "(no message)");
            try inputs.stderr.writeByte('\n');
            break :failure 1;
        },
        .max_turns => failure: {
            try inputs.stderr.print("zi: max turns ({d}) exceeded; aborting\n", .{max_turns});
            break :failure 1;
        },
        .interrupted, .paused => 1,
    };
    return .{ .exit_code = exit_code, .info = info, .started_ns = started_ns };
}

fn ignoreCatalogError(err: CallbackError) void {
    switch (err) {
        error.OutOfMemory, error.Failed, error.Indeterminate, error.InvalidPlan => {},
    }
}

fn callSeam(inputs: Inputs, kind: agent.Loop.SeamKind) Error!void {
    const seam = inputs.seam_hook orelse return;
    _ = seam.call(inputs.session, kind, false) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.Failed,
        error.Indeterminate => error.Indeterminate,
    };
}

fn printBanner(inputs: Inputs, info: SessionInfo) std.Io.Writer.Error!void {
    const selection = inputs.session.currentSelection();
    const preset = info.preset orelse selection.preset;
    const provider_name = info.provider_name orelse inputs.provider.id;
    const model_label = info.model_label orelse selection.model_label orelse inputs.model;
    const effort = info.effort orelse inputs.effort orelse selection.effort;

    var style_open = false;
    if (inputs.style_diagnostics) {
        try inputs.stderr.writeAll(ansi_dim);
        style_open = true;
    }
    errdefer if (style_open) resetBestEffort(inputs.stderr);
    if (preset) |value| {
        if (value.len > 0) {
            try inputs.stderr.writeAll("zi [");
            try DiagnosticText.write(inputs.stderr, value);
            try inputs.stderr.writeAll("]: ");
            try DiagnosticText.write(inputs.stderr, provider_name);
            try inputs.stderr.writeAll(" · ");
            try DiagnosticText.write(inputs.stderr, model_label);
        } else {
            try inputs.stderr.writeAll("zi: ");
            try DiagnosticText.write(inputs.stderr, provider_name);
            try inputs.stderr.writeAll(" · ");
            try DiagnosticText.write(inputs.stderr, model_label);
        }
    } else {
        try inputs.stderr.writeAll("zi: ");
        try DiagnosticText.write(inputs.stderr, provider_name);
        try inputs.stderr.writeAll(" · ");
        try DiagnosticText.write(inputs.stderr, model_label);
    }
    if (effort) |value| if (value.len > 0) {
        try inputs.stderr.writeAll(" · ");
        try DiagnosticText.write(inputs.stderr, value);
    };
    if (info.provider_autoselected) {
        try inputs.stderr.writeAll(" (auto-selected)");
    } else if (info.resumed) {
        try inputs.stderr.writeAll(" (resumed)");
    }
    if (info.materialized_session) |session_id| {
        try inputs.stderr.writeAll(" · session ");
        try DiagnosticText.write(inputs.stderr, session_id);
    }
    if (style_open) {
        try inputs.stderr.writeAll(ansi_reset);
        style_open = false;
    }
    try inputs.stderr.writeAll("\n\n");
}

fn printResumeHint(
    writer: *std.Io.Writer,
    hint: []const u8,
    styled: bool,
) std.Io.Writer.Error!void {
    var style_open = false;
    if (styled) {
        try writer.writeAll(ansi_dim);
        style_open = true;
    }
    errdefer if (style_open) resetBestEffort(writer);
    try writer.writeAll("resume with: zi --resume=");
    try DiagnosticText.write(writer, hint);
    if (style_open) {
        try writer.writeAll(ansi_reset);
        style_open = false;
    }
    try writer.writeByte('\n');
}

fn resetBestEffort(writer: *std.Io.Writer) void {
    writer.writeAll(ansi_reset) catch |err| switch (err) {
        error.WriteFailed => {},
    };
}

fn printFinalMessages(
    writer: *std.Io.Writer,
    items: []const ai.Item.Item,
    result: agent.Loop.Result,
) std.Io.Writer.Error!void {
    for (items[result.final_items_from..result.final_items_to]) |item| switch (item) {
        .assistant_message => |message| {
            if (message.text.len == 0) continue;
            try writer.writeAll(message.text);
            if (message.text[message.text.len - 1] != '\n') try writer.writeByte('\n');
        },
        else => {},
    };
}

test "golden one-shot orders durability, final output, tasks, catalog, and notes" {
    const Provider = struct {
        const Self = @This();
        order: *std.ArrayList(u8),

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (request.context.items.len < 2) return error.InvalidRequest;
            if (request.context.items[1] != .user_message or
                !std.mem.eql(u8, "hello", request.context.items[1].user_message.text))
            {
                return error.InvalidRequest;
            }
            self.order.append(std.testing.allocator, 'N') catch return error.OutOfMemory;
            try sink.emit(.{ .text_delta = "first" });
            try sink.emit(.{ .reasoning_item = .{ .opaque_json = "{}" } });
            try sink.emit(.{ .text_delta = "second\n" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1, .output_tokens = 1 } } });
        }
    };
    const Seam = struct {
        const Self = @This();
        order: *std.ArrayList(u8),

        pub fn call(
            self: *Self,
            session: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!agent.Loop.SeamDisposition {
            const byte: ?u8 = switch (kind) {
                .prompt => 'P',
                .completion => 'L',
                .task_note => 'D',
                else => null,
            };
            if (kind == .prompt) {
                if (session.items().len != 2) return error.Failed;
                if (session.items()[0] != .turn_boundary) return error.Failed;
            }
            if (byte) |value| self.order.append(std.testing.allocator, value) catch return error.OutOfMemory;
            return .synchronized;
        }
    };
    const Info = struct {
        const Self = @This();
        order: *std.ArrayList(u8),

        pub fn get(self: *Self) CallbackError!SessionInfo {
            self.order.append(std.testing.allocator, 'I') catch return error.OutOfMemory;
            return .{
                .preset = "work",
                .provider_name = "Fake",
                .model_label = "Model",
                .effort = "high",
                .provider_autoselected = true,
                .materialized_session = "abc",
            };
        }
    };
    const Catalog = struct {
        const Self = @This();
        order: *std.ArrayList(u8),

        pub fn prefetch(self: *Self) CallbackError!PrefetchOutcome {
            self.order.append(std.testing.allocator, 'C') catch return error.OutOfMemory;
            return .started;
        }

        pub fn drain(self: *Self, wait_ms: u64) CallbackError!?ai.ModelMeta.Metadata {
            if (wait_ms != catalog_drain_ms) return error.Failed;
            self.order.append(std.testing.allocator, 'R') catch return error.OutOfMemory;
            return null;
        }
    };
    const Terminal = struct {
        const Self = @This();
        order: *std.ArrayList(u8),

        pub fn finish(
            self: *Self,
            session: *agent.Session.Session,
            seam_hook: ?agent.Loop.SeamHook,
        ) CallbackError!void {
            self.order.append(std.testing.allocator, 'T') catch return error.OutOfMemory;
            const item: ai.Item.Item = .{ .user_message = .{
                .text = @constCast("[task t1 killed at exit]"),
                .origin = .task_note,
            } };
            session.appendCopy(&item) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
            if (seam_hook) |seam| _ = seam.call(session, .task_note, false) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Failed => error.Failed,
                error.Indeterminate => error.Indeterminate,
            };
            self.order.append(std.testing.allocator, 'S') catch return error.OutOfMemory;
        }
    };
    const Renderer = struct {
        const Self = @This();

        fn render(
            _: *Self,
            writer: *std.Io.Writer,
            stats: *const agent.UsageStats.UsageStats,
            _: u64,
            _: bool,
        ) RenderError!void {
            if (!stats.has_unpriced) return error.Failed;
            try writer.writeAll("stats\n");
        }
    };

    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var provider: Provider = .{ .order = &order };
    var seam: Seam = .{ .order = &order };
    var info: Info = .{ .order = &order };
    var catalog: Catalog = .{ .order = &order };
    var terminal: Terminal = .{ .order = &order };
    var renderer: Renderer = .{};
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var stdout_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_allocating.deinit();
    var stderr_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_allocating.deinit();

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "fake-model",
        .system_prompt = "system",
        .prompt = "hello",
        .stdout = &stdout_allocating.writer,
        .stderr = &stderr_allocating.writer,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
        .usage_stats = &stats,
        .session_info_hook = SessionInfoHook.from(&info),
        .catalog_hook = CatalogHook.from(&catalog),
        .terminal_hook = TerminalHook.from(&terminal),
        .stats_renderer = StatsRenderer.from(&renderer),
    });
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("first\nsecond\n", stdout_allocating.written());
    try std.testing.expectEqualStrings(
        "zi [work]: Fake · Model · high (auto-selected) · session abc\n\n" ++
            "\nstats\nresume with: zi --resume=abc\n",
        stderr_allocating.written(),
    );
    try std.testing.expectEqualStrings("PICNLTDSR", order.items);
}

test "empty completion is success and failing stdout still shuts down tasks" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .done = .{} });
        }
    };
    const Terminal = struct {
        const Self = @This();
        shutdown_called: bool = false,

        pub fn finish(
            self: *Self,
            _: *agent.Session.Session,
            _: ?agent.Loop.SeamHook,
        ) CallbackError!void {
            self.shutdown_called = true;
        }
    };

    var provider: Provider = .{};
    var terminal: Terminal = .{};
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var stdout_buffer: [1]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .prompt = "x",
        .stdout = &stdout,
        .stderr = &stderr,
        .usage_stats = &stats,
        .terminal_hook = TerminalHook.from(&terminal),
        .style_diagnostics = true,
    }));
    try std.testing.expect(terminal.shutdown_called);
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("\x1b[2mzi: fake · model\x1b[0m\n\n", stderr.buffered());
}

test "assistant output failure still shuts down terminal tasks" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Terminal = struct {
        const Self = @This();
        shutdown_called: bool = false,

        pub fn finish(
            self: *Self,
            _: *agent.Session.Session,
            _: ?agent.Loop.SeamHook,
        ) CallbackError!void {
            self.shutdown_called = true;
            return error.Indeterminate;
        }
    };

    var provider: Provider = .{};
    var terminal: Terminal = .{};
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var stdout_buffer: [0]u8 = .{};
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    try std.testing.expectError(error.Indeterminate, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .prompt = "x",
        .stdout = &stdout,
        .stderr = &stderr,
        .usage_stats = &stats,
        .terminal_hook = TerminalHook.from(&terminal),
    }));
    try std.testing.expect(terminal.shutdown_called);
}

test "provider failure is diagnostic and exits one" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .failure = .{ .message = "quota\n\x1b\u{9b}\u{202e}" } });
        }
    };

    var provider: Provider = .{};
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var stdout_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_allocating.deinit();
    var stderr_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_allocating.deinit();
    try std.testing.expectEqual(@as(u8, 1), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .prompt = "x",
        .stdout = &stdout_allocating.writer,
        .stderr = &stderr_allocating.writer,
        .usage_stats = &stats,
    }));
    try std.testing.expectEqualStrings("", stdout_allocating.written());
    try std.testing.expectEqualStrings(
        "zi: fake · model\n\nzi: provider error: quota\\n\\x1b\\u{9b}\\u{202e}\n",
        stderr_allocating.written(),
    );
}

test "catalog advisory outcomes and errors never erase completion" {
    const Mode = enum {
        warning,
        unavailable,
        prefetch_error,
        prefetch_oom,
        prefetch_indeterminate,
        prefetch_invalid_plan,
        drain_error,
        priced,
        already_priced,
        preflight_priced,
    };
    const Provider = struct {
        const Self = @This();
        expected_effort: ?[]const u8 = null,
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.expected_effort) |expected| {
                const actual = request.context.effort orelse return error.InvalidRequest;
                if (!std.mem.eql(u8, expected, actual)) return error.InvalidRequest;
            }
            try sink.emit(.{ .text_delta = "ok" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1, .output_tokens = 1 } } });
        }
    };
    const Catalog = struct {
        const Self = @This();
        mode: Mode,
        prefetch_calls: usize = 0,
        drain_calls: usize = 0,

        pub fn prefetch(self: *Self) CallbackError!PrefetchOutcome {
            self.prefetch_calls += 1;
            return switch (self.mode) {
                .warning => .{ .warning = "stale catalog" },
                .unavailable, .drain_error, .priced, .already_priced => .unavailable,
                .preflight_priced => .started,
                .prefetch_error => error.Failed,
                .prefetch_oom => error.OutOfMemory,
                .prefetch_indeterminate => error.Indeterminate,
                .prefetch_invalid_plan => error.InvalidPlan,
            };
        }

        pub fn currentMetadata(self: *Self) ?ai.ModelMeta.Metadata {
            if (self.mode != .preflight_priced) return null;
            return .{ .rates = .{ .input = 1_000_000, .output = 1_000_000 } };
        }

        pub fn drain(self: *Self, wait_ms: u64) CallbackError!?ai.ModelMeta.Metadata {
            const expected_wait: u64 = if (self.mode == .already_priced or self.mode == .preflight_priced)
                0
            else
                catalog_drain_ms;
            if (wait_ms != expected_wait) return error.Failed;
            self.drain_calls += 1;
            if (self.mode == .drain_error) return error.Failed;
            if (self.mode == .priced) return .{ .rates = .{
                .input = 1_000_000,
                .output = 1_000_000,
            } };
            return null;
        }
    };

    for ([_]Mode{
        .warning,
        .unavailable,
        .prefetch_error,
        .prefetch_oom,
        .prefetch_indeterminate,
        .drain_error,
        .priced,
        .already_priced,
        .preflight_priced,
    }) |mode| {
        var provider: Provider = .{
            .expected_effort = if (mode == .preflight_priced) "high" else null,
        };
        var catalog: Catalog = .{ .mode = mode };
        var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
        defer stats.deinit();
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var stdout_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stdout_allocating.deinit();
        var stderr_allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr_allocating.deinit();

        const inputs: Inputs = .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .model_metadata = if (mode == .already_priced) .{ .rates = .{
                .input = 1,
                .output = 1,
            } } else .{},
            .effort = if (mode == .preflight_priced) "high" else null,
            .system_prompt = "",
            .prompt = "x",
            .stdout = &stdout_allocating.writer,
            .stderr = &stderr_allocating.writer,
            .usage_stats = &stats,
            .catalog_hook = CatalogHook.from(&catalog),
        };
        const expected_error: ?CallbackError = switch (mode) {
            .prefetch_oom => error.OutOfMemory,
            .prefetch_indeterminate => error.Indeterminate,
            .prefetch_invalid_plan => error.InvalidPlan,
            else => null,
        };
        if (expected_error) |expected| {
            try std.testing.expectError(expected, run(std.testing.allocator, std.testing.io, inputs));
            try std.testing.expectEqual(@as(usize, 0), provider.calls);
            try std.testing.expectEqual(@as(usize, 0), catalog.drain_calls);
            continue;
        }
        try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, inputs));
        try std.testing.expectEqualStrings("ok\n", stdout_allocating.written());
        try std.testing.expectEqual(@as(usize, 1), catalog.prefetch_calls);
        try std.testing.expectEqual(@as(usize, 1), catalog.drain_calls);
        if (mode == .priced or mode == .preflight_priced) {
            try std.testing.expect(!stats.has_unpriced);
            try std.testing.expectApproxEqAbs(@as(f64, 2), stats.spend_usd, 1e-15);
        }
        if (mode == .warning) {
            try std.testing.expect(std.mem.indexOf(u8, stderr_allocating.written(), "stale catalog") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, stderr_allocating.written(), "warning:") == null);
        }
    }
}

fn exerciseOneShotAllocations(allocator: std.mem.Allocator) !void {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Info = struct {
        const Self = @This();

        pub fn get(_: *Self) CallbackError!SessionInfo {
            return .{ .materialized_session = "allocation-session" };
        }
    };
    const Renderer = struct {
        const Self = @This();

        fn render(
            _: *Self,
            writer: *std.Io.Writer,
            _: *const agent.UsageStats.UsageStats,
            _: u64,
            _: bool,
        ) RenderError!void {
            try writer.writeAll("stats\n");
        }
    };

    var provider: Provider = .{};
    var info: Info = .{};
    var renderer: Renderer = .{};
    var stats = try agent.UsageStats.UsageStats.init(allocator, 16);
    defer stats.deinit();
    stats.last_ordinary_context_tokens = 1;
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    var stdout_buffer: [128]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const exit_code = try run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .prompt = "allocation prompt",
        .stdout = &stdout,
        .stderr = &stderr,
        .usage_stats = &stats,
        .session_info_hook = SessionInfoHook.from(&info),
        .stats_renderer = StatsRenderer.from(&renderer),
    });
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "one-shot session info renderer and loop paths are allocation safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOneShotAllocations,
        .{},
    );
}

test "terminal finish is exact once with documented error precedence" {
    const TerminalMode = enum { success, failed, indeterminate };
    const Provider = struct {
        const Self = @This();
        emit_text: bool,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (self.emit_text) try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Terminal = struct {
        const Self = @This();
        mode: TerminalMode,
        calls: usize = 0,

        pub fn finish(
            self: *Self,
            _: *agent.Session.Session,
            _: ?agent.Loop.SeamHook,
        ) CallbackError!void {
            self.calls += 1;
            return switch (self.mode) {
                .success => {},
                .failed => error.Failed,
                .indeterminate => error.Indeterminate,
            };
        }
    };

    const Case = struct {
        output_fails: bool,
        terminal: TerminalMode,
        expected: enum { success, write_failed, failed, indeterminate },
    };
    for ([_]Case{
        .{ .output_fails = false, .terminal = .success, .expected = .success },
        .{ .output_fails = false, .terminal = .failed, .expected = .failed },
        .{ .output_fails = false, .terminal = .indeterminate, .expected = .indeterminate },
        .{ .output_fails = true, .terminal = .success, .expected = .write_failed },
        .{ .output_fails = true, .terminal = .failed, .expected = .write_failed },
        .{ .output_fails = true, .terminal = .indeterminate, .expected = .indeterminate },
    }) |case| {
        var provider: Provider = .{ .emit_text = case.output_fails };
        var terminal: Terminal = .{ .mode = case.terminal };
        var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 16);
        defer stats.deinit();
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var stdout_buffer: [0]u8 = .{};
        var stdout: std.Io.Writer = .fixed(&stdout_buffer);
        var stderr_buffer: [128]u8 = undefined;
        var stderr: std.Io.Writer = .fixed(&stderr_buffer);
        const result = run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "",
            .prompt = "x",
            .stdout = &stdout,
            .stderr = &stderr,
            .usage_stats = &stats,
            .terminal_hook = TerminalHook.from(&terminal),
        });
        switch (case.expected) {
            .success => try std.testing.expectEqual(@as(u8, 0), try result),
            .write_failed => try std.testing.expectError(error.WriteFailed, result),
            .failed => try std.testing.expectError(error.Failed, result),
            .indeterminate => try std.testing.expectError(error.Indeterminate, result),
        }
        try std.testing.expectEqual(@as(usize, 1), terminal.calls);
    }
}

test "banner and resume hint sanitize untrusted fields inside style wrappers" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {}
    };
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var usage = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer usage.deinit();
    const inputs: Inputs = .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fallback"),
        .model = "fallback",
        .system_prompt = "",
        .prompt = "",
        .stdout = &output.writer,
        .stderr = &output.writer,
        .usage_stats = &usage,
        .style_diagnostics = true,
    };
    try printBanner(inputs, .{
        .preset = "p\n",
        .provider_name = "provider\x1b",
        .model_label = "model\u{9b}",
        .effort = "high\u{202e}",
        .materialized_session = "id\u{2067}",
    });
    try printResumeHint(&output.writer, "id\n\x1b", true);
    try std.testing.expectEqualStrings(
        "\x1b[2mzi [p\\n]: provider\\x1b · model\\u{9b} · high\\u{202e} · session id\\u{2067}\x1b[0m\n\n" ++
            "\x1b[2mresume with: zi --resume=id\\n\\x1b\x1b[0m\n",
        output.written(),
    );
}
