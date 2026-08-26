const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const render = @import("../render/root.zig");
const terminal = @import("../terminal/root.zig");
const tool = @import("../tool/root.zig");
const text = @import("../text/root.zig");
const DiagnosticText = @import("DiagnosticText.zig");
const Args = @import("Args.zig");

comptime {
    std.debug.assert(terminal.max_prompt_bytes == Args.max_prompt_bytes);
}

pub const BeforeFirstSendError = error{
    OutOfMemory,
    Indeterminate,
    InvalidPlan,
    WriteFailed,
};

pub const BeforeFirstSend = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) BeforeFirstSendError!void,

    pub fn call(self: BeforeFirstSend) BeforeFirstSendError!void {
        return self.call_fn(self.context);
    }

    pub fn from(implementation: anytype) BeforeFirstSend {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("BeforeFirstSend.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(context: *anyopaque) BeforeFirstSendError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.call();
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

pub const EffortSource = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque) ?[]const u8,

    pub fn resolve(self: EffortSource) ?[]const u8 {
        return self.resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) EffortSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("EffortSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(context: *anyopaque) ?[]const u8 {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
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
    effort_source: ?EffortSource = null,
    image_input: ai.Provider.ImageInput = .unknown,
    image_input_source: ?agent.ImageInputSource.ImageInputSource = null,
    reader: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    show_prompt: bool,
    seam_hook: ?agent.Loop.SeamHook = null,
    checkpoint: ?agent.Loop.Checkpoint = null,
    pre_request_hook: ?agent.Loop.PreRequestHook = null,
    continuation_hook: ?agent.Loop.ContinuationHook = null,
    usage_observer: ?agent.Loop.UsageObserver = null,
    max_turns: usize = agent.Loop.maximum_max_turns,
    before_first_send: ?BeforeFirstSend = null,
};

const ResumeState = enum {
    none,
    clean,
    marked,
};

fn resumeState(abort_marker_placed: bool) ResumeState {
    return if (abort_marker_placed) .marked else .clean;
}

/// Runs a bounded cooked-line REPL around the shared provider-independent agent loop.
/// Provider failures are turn-local and return control to the next prompt.
pub fn run(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) !u8 {
    var line_input = terminal.CookedLineInput.init(allocator, inputs.reader);
    var resume_state: ResumeState = .none;
    var first_send = true;
    while (true) {
        if (inputs.show_prompt) {
            try inputs.stdout.writeAll("> ");
            try inputs.stdout.flush();
        }

        var line_result = line_input.read() catch |err| switch (err) {
            error.LineTooLong => {
                try inputs.stderr.print(
                    "zi: prompt exceeds the {d}-byte limit\n",
                    .{terminal.max_prompt_bytes},
                );
                try inputs.stderr.flush();
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        defer line_result.deinit(allocator);

        const submitted = switch (line_result) {
            .eof => {
                if (inputs.show_prompt) {
                    try inputs.stdout.writeByte('\n');
                    try inputs.stdout.flush();
                }
                return 0;
            },
            .submit => |line| line.bytes,
        };
        const resuming = submitted.len == 0 and resume_state != .none;
        if (submitted.len == 0 and !resuming) continue;
        const continuing = resuming and resume_state == .clean;

        var sanitized: ?[]u8 = null;
        defer if (sanitized) |bytes| allocator.free(bytes);
        if (resuming and resume_state == .marked) {
            try inputs.session.addContinuation();
            if (inputs.seam_hook) |seam| try seam.call(inputs.session, .prompt, false);
        } else if (!resuming) {
            sanitized = text.Utf8.sanitize(allocator, submitted, terminal.max_prompt_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResultTooLarge => {
                    try inputs.stderr.print(
                        "zi: prompt exceeds the {d}-byte limit after UTF-8 sanitation\n",
                        .{terminal.max_prompt_bytes},
                    );
                    try inputs.stderr.flush();
                    continue;
                },
            };
            try inputs.session.addUser(sanitized.?);
            if (inputs.seam_hook) |seam| try seam.call(inputs.session, .prompt, false);
        }
        resume_state = .none;
        if (first_send) {
            if (inputs.before_first_send) |hook| try hook.call();
            first_send = false;
        }

        const effort = if (inputs.effort_source) |source| source.resolve() else inputs.effort;
        var stream_renderer = render.StreamRenderer.init(inputs.stdout);
        var loop_result = agent.Loop.run(allocator, io, .{
            .session = inputs.session,
            .provider = inputs.provider,
            .model = inputs.model,
            .model_metadata = inputs.model_metadata,
            .model_metadata_source = inputs.model_metadata_source,
            .system_prompt = inputs.system_prompt,
            .tools = inputs.tools,
            .effort = effort,
            .image_input = inputs.image_input,
            .image_input_source = inputs.image_input_source,
            .max_turns = inputs.max_turns,
            .continued = continuing,
            .checkpoint = inputs.checkpoint,
            .observer = stream_renderer.observer(),
            .usage_observer = inputs.usage_observer,
            .seam_hook = inputs.seam_hook,
            .pre_request_hook = inputs.pre_request_hook,
            .continuation_hook = inputs.continuation_hook,
        }) catch |loop_error| {
            stream_renderer.close(.failure);
            try stream_renderer.check();
            return loop_error;
        };
        defer loop_result.deinit(allocator);

        switch (loop_result.outcome) {
            .complete => stream_renderer.close(.complete),
            .provider_error => {
                stream_renderer.close(.failure);
                try inputs.stderr.writeAll("zi: provider error: ");
                try DiagnosticText.write(inputs.stderr, loop_result.diagnostic orelse "(no message)");
                try inputs.stderr.writeByte('\n');
                try inputs.stderr.flush();
                resume_state = resumeState(loop_result.abort_marker_placed);
            },
            .max_turns => {
                stream_renderer.close(.failure);
                try inputs.stderr.print(
                    "zi: max turns ({d}) exceeded; submit an empty prompt to continue\n",
                    .{inputs.max_turns},
                );
                try inputs.stderr.flush();
                resume_state = .clean;
            },
            .paused => {
                stream_renderer.close(.interrupted);
                resume_state = .clean;
            },
            .interrupted => {
                stream_renderer.close(.interrupted);
                resume_state = resumeState(loop_result.abort_marker_placed);
            },
        }
        try stream_renderer.check();
    }
}

test "interactive reuses one session across prompts and exits on EOF" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            const expected_user_count: usize = self.calls;
            var user_count: usize = 0;
            for (request.context.items) |item| {
                if (item == .user_message) user_count += 1;
            }
            if (user_count != expected_user_count) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = if (self.calls == 1) "first" else "second" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,
        completions: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            switch (kind) {
                .prompt => self.prompts += 1,
                .completion => self.completions += 1,
                else => {},
            }
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 2), seam.prompts);
    try std.testing.expectEqual(@as(usize, 2), seam.completions);
    try std.testing.expectEqualStrings("first\nsecond\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "provider failure is turn-local and the next prompt still runs" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .failure = .{ .message = "temporary" } });
                return;
            }
            try sink.emit(.{ .text_delta = "recovered" });
            try sink.emit(.{ .done = .{} });
        }
    };

    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    }));
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqualStrings("recovered\n", stdout.written());
    try std.testing.expectEqualStrings("zi: provider error: temporary\n", stderr.written());
}

test "empty submit resumes a failed turn without adding another user message" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            var users: usize = 0;
            for (request.context.items) |item| {
                if (item == .user_message) users += 1;
            }
            if (users != 1) return error.InvalidRequest;
            if (self.calls == 1) {
                try sink.emit(.{ .failure = .{ .message = "retry me" } });
            } else {
                try sink.emit(.{ .text_delta = "resumed" });
                try sink.emit(.{ .done = .{} });
            }
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            if (kind == .prompt) self.prompts += 1;
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), seam.prompts);
    try std.testing.expectEqualStrings("resumed\n", stdout.written());
}

test "submitted input is UTF-8 and NUL sanitized before session storage" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            const expected = "a" ++ "\xef\xbf\xbd" ** 2 ++ "b";
            const user = request.context.items[1].user_message.text;
            if (!std.mem.eql(u8, expected, user)) return error.InvalidRequest;
            try sink.emit(.{ .done = .{} });
        }
    };

    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    const bytes = [_]u8{ 'a', 0, 0xff, 'b', '\n' };
    var reader = std.Io.Reader.fixed(&bytes);
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    });
}

test "configured turn bound pauses and empty submit continues the tool tail" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .done = .{} });
            } else {
                try sink.emit(.{ .text_delta = "done" });
                try sink.emit(.{ .done = .{} });
            }
        }
    };

    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .max_turns = 1,
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqualStrings("done\n", stdout.written());
    try std.testing.expectEqualStrings(
        "zi: max turns (1) exceeded; submit an empty prompt to continue\n",
        stderr.written(),
    );
}

test "marked partial failure resumes through a durable continuation item" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .text_delta = "partial" });
                try sink.emit(.{ .failure = .{ .message = "retry me" } });
                return;
            }
            var have_continuation = false;
            for (request.context.items) |item| {
                if (item == .user_message and item.user_message.origin == .continuation) {
                    have_continuation = true;
                }
            }
            if (!have_continuation) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = "resumed" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            if (kind == .prompt) self.prompts += 1;
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 2), seam.prompts);
    try std.testing.expectEqualStrings("partial\nresumed\n", stdout.written());
}

test "before-first-send hook is lazy and runs once" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            try sink.emit(.{ .done = .{} });
        }
    };
    const Hook = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self) BeforeFirstSendError!void {
            self.calls += 1;
        }
    };

    var provider: Provider = .{};
    var hook: Hook = .{};
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    var empty_session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer empty_session.deinit();
    var empty_reader = std.Io.Reader.fixed("");
    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &empty_session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &empty_reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&hook),
    });
    try std.testing.expectEqual(@as(usize, 0), hook.calls);

    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&hook),
    });
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
}

test "effort source resolves after the lazy first-send hook" {
    const State = struct {
        const Self = @This();
        effort: []const u8 = "old",

        pub fn resolve(self: *Self) ?[]const u8 {
            return self.effort;
        }

        pub fn call(self: *Self) BeforeFirstSendError!void {
            self.effort = "new";
        }
    };
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (!std.mem.eql(u8, request.context.effort orelse "", "new")) return error.InvalidRequest;
            try sink.emit(.{ .done = .{} });
        }
    };

    var state: State = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .effort = "old",
        .effort_source = EffortSource.from(&state),
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&state),
    });
}
