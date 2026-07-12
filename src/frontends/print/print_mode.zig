const std = @import("std");

const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const runtime = @import("../../runtime/root.zig");

pub const OutputMode = enum { text, json };

pub const Options = struct {
    prompt: []const u8,
    output: OutputMode = .text,
};

const OutputSink = struct {
    writer: *std.Io.Writer,
    mode: OutputMode,
    active_assistant_had_text_delta: bool = false,

    fn listener(_: std.Io, context: ?*anyopaque, event: coding_agent.AgentSession.AgentSessionEvent) anyerror!void {
        const self: *OutputSink = @ptrCast(@alignCast(context.?));
        try self.write(event);
    }

    fn write(self: *OutputSink, event: coding_agent.AgentSession.AgentSessionEvent) !void {
        switch (self.mode) {
            .json => {
                try std.json.Stringify.value(event, .{}, self.writer);
                try self.writer.writeByte('\n');
                try self.writer.flush();
            },
            .text => try self.writeText(event),
        }
    }

    fn writeText(self: *OutputSink, event: coding_agent.AgentSession.AgentSessionEvent) !void {
        switch (event) {
            .message_start => |payload| if (payload.message == .assistant) {
                self.active_assistant_had_text_delta = false;
            },
            .message_update => |payload| switch (payload.assistant_message_event) {
                .text_delta => |text| {
                    self.active_assistant_had_text_delta = true;
                    try self.writer.writeAll(text.delta);
                    try self.writer.flush();
                },
                else => {},
            },
            .message_end => |payload| if (payload.message == .assistant and !self.active_assistant_had_text_delta) {
                for (payload.message.assistant.content) |content| switch (content) {
                    .text => |text| try self.writer.writeAll(text.text),
                    else => {},
                };
                try self.writer.flush();
            },
            else => {},
        }
    }
};

const Driver = struct {
    prompt: []const u8,
    overflow_count_before: usize,
    overflow_retry_used: bool = false,

    fn run(
        self: *Driver,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
    ) !bool {
        var handle = try session.startPromptHandle(self.prompt, &.{});
        handle.setWake(io, wake);
        while (true) {
            const verdict = try self.driveHandle(session, io, wake, &handle);
            switch (verdict) {
                .completed => {
                    try self.runThresholdCompaction(session, io, wake);
                    return true;
                },
                .failed => return false,
                .retry => |retry| handle = try self.startRetry(session, io, wake, retry),
                .compact => |compaction_run| {
                    handle = coding_agent.AgentSession.RunHandle.compaction(compaction_run);
                    handle.setWake(io, wake);
                },
            }
        }
    }

    fn runThresholdCompaction(
        self: *Driver,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
    ) !void {
        if (!session.shouldRunThresholdCompaction()) return;
        // Threshold compaction is post-success maintenance, matching the TUI:
        // it may update durable context, but it does not fail an already
        // successful prompt.
        var maybe = try session.startCompactionHandle(.threshold, false, null);
        if (maybe) |*handle| {
            handle.setWake(io, wake);
            _ = try self.driveHandle(session, io, wake, handle);
        }
    }

    fn driveHandle(
        self: *Driver,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        handle: *coding_agent.AgentSession.RunHandle,
    ) !coding_agent.AgentSession.SettleVerdict {
        var handle_consumed = false;
        errdefer if (!handle_consumed) {
            _ = handle.cancelRequest(session);
            handle.deinitAfterSettled(session);
        };
        while (true) {
            switch (try handle.poll(session)) {
                .live => {},
                .empty => {
                    try wake.wait(io);
                    wake.reset();
                },
                .settled => break,
            }
        }
        const verdict = try handle.settle(session, .{
            .overflow_count_before = self.overflow_count_before,
            .overflow_retry_used = self.overflow_retry_used,
        });
        handle.deinitAfterSettled(session);
        handle_consumed = true;
        return verdict;
    }

    fn startRetry(
        self: *Driver,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        retry: coding_agent.AgentSession.SettleVerdict.Retry,
    ) !coding_agent.AgentSession.RunHandle {
        if (retry.delay_ms > 0) try runtime.sleep(io, .fromMilliseconds(@intCast(retry.delay_ms)));
        if (retry.overflow) self.overflow_retry_used = true;
        var handle = try session.startContinueHandle();
        handle.setWake(io, wake);
        return handle;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    _: *coding_agent.runtime_services.RuntimeServices,
    session: *coding_agent.AgentSession,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    opts: Options,
) !u8 {
    _ = gpa;
    if (opts.output == .json) {
        try std.json.Stringify.value(session.sessionHeader(), .{}, stdout);
        try stdout.writeByte('\n');
        try stdout.flush();
    }

    var sink: OutputSink = .{ .writer = stdout, .mode = opts.output };
    const listener = try session.subscribe(.{ .context = &sink, .call_fn = OutputSink.listener });
    defer session.unsubscribe(listener);

    var wake: runtime.WakeEvent = .init;
    var driver: Driver = .{
        .prompt = opts.prompt,
        .overflow_count_before = session.contextOverflowCount(),
    };
    errdefer session.emitAgentSettled() catch {};
    const success = try driver.run(session, io, &wake);
    try session.emitAgentSettled();
    try stdout.flush();
    if (!success and opts.output == .text) {
        if (session.latestAssistantError()) |message| try stderr.print("error: {s}\n", .{message});
        try stderr.flush();
    }
    return if (success or opts.output == .json) 0 else 1;
}

fn textContent(value: []const u8) ai.AssistantContent {
    return .{ .text = .{ .text = value } };
}

test "print mode streams text deltas" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const content = [_]ai.AssistantContent{textContent("print mode ok\n")};
    const message = ai.faux.assistantMessage(&content, .{});
    try services.faux_provider.?.setResponses(&.{message});

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(
        std.testing.allocator,
        &services,
        stamp.date(),
        .{ .create = .{ .session_id = "print-test", .timestamp = stamp.timestamp() } },
        .{},
    );
    defer {
        session.requestShutdown();
        session.deinit();
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var err_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_output.deinit();
    const status = try run(
        std.testing.allocator,
        &services,
        &session,
        services.io,
        &output.writer,
        &err_output.writer,
        .{ .prompt = "hi" },
    );
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("print mode ok\n", output.written());
}

test "print mode json assistant failure remains a successful process stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const message = ai.faux.assistantMessage(&.{}, .{
        .stop_reason = .error_,
        .error_message = "provider failure",
        .operational_failure = .{
            .category = .unknown,
            .message = "provider failure",
            .retryable = .no,
        },
    });
    try services.faux_provider.?.setResponses(&.{message});

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(
        std.testing.allocator,
        &services,
        stamp.date(),
        .{ .create = .{ .session_id = "json-failure-test", .timestamp = stamp.timestamp() } },
        .{},
    );
    defer {
        session.requestShutdown();
        session.deinit();
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var err_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_output.deinit();
    const status = try run(
        std.testing.allocator,
        &services,
        &session,
        services.io,
        &output.writer,
        &err_output.writer,
        .{ .prompt = "hi", .output = .json },
    );
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("", err_output.written());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"stopReason\":\"error\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "{\"type\":\"agent_settled\"}\n"));
}

test "print mode writer failure drains the active run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const content = [_]ai.AssistantContent{textContent("x" ** 2048)};
    const message = ai.faux.assistantMessage(&content, .{});
    try services.faux_provider.?.setResponses(&.{message});
    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(
        std.testing.allocator,
        &services,
        stamp.date(),
        .{ .create = .{ .session_id = "json-writer-failure", .timestamp = stamp.timestamp() } },
        .{},
    );
    defer {
        session.requestShutdown();
        session.deinit();
    }

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var err_output: std.Io.Writer.Discarding = .init(&.{});
    var failed = false;
    _ = run(
        std.testing.allocator,
        &services,
        &session,
        services.io,
        &output,
        &err_output.writer,
        .{ .prompt = "hi", .output = .json },
    ) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    try std.testing.expect(session.agent.waitForIdle());
}

test "print mode writes json events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const content = [_]ai.AssistantContent{textContent("json mode ok")};
    const message = ai.faux.assistantMessage(&content, .{});
    try services.faux_provider.?.setResponses(&.{message});

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(
        std.testing.allocator,
        &services,
        stamp.date(),
        .{ .create = .{ .session_id = "json-print-test", .timestamp = stamp.timestamp() } },
        .{},
    );
    defer {
        session.requestShutdown();
        session.deinit();
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var err_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_output.deinit();
    const status = try run(
        std.testing.allocator,
        &services,
        &session,
        services.io,
        &output.writer,
        &err_output.writer,
        .{ .prompt = "hi", .output = .json },
    );
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\n"));
    const expected_types = [_][]const u8{
        "session",
        "agent_start",
        "turn_start",
        "message_start",
        "message_end",
        "message_start",
        "message_update",
        "message_update",
        "message_update",
        "message_end",
        "turn_end",
        "agent_end",
        "agent_settled",
    };
    var lines = std.mem.splitScalar(u8, output.written(), '\n');
    var index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        try std.testing.expect(index < expected_types.len);
        var parsed = try runtime.JsonOwned(std.json.Value).parseJson(std.testing.allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings(expected_types[index], object.get("type").?.string);
        if (index == 0) {
            try std.testing.expectEqual(@as(i64, 3), object.get("version").?.integer);
            try std.testing.expectEqualStrings("json-print-test", object.get("id").?.string);
            try std.testing.expectEqualStrings(stamp.timestamp(), object.get("timestamp").?.string);
            try std.testing.expectEqualStrings("repo", object.get("cwd").?.string);
        }
        if (std.mem.eql(u8, expected_types[index], "message_update")) {
            try std.testing.expect(object.contains("message"));
            try std.testing.expect(object.contains("assistantMessageEvent"));
        }
        if (std.mem.eql(u8, expected_types[index], "turn_end")) {
            try std.testing.expect(object.contains("message"));
            try std.testing.expect(object.contains("toolResults"));
        }
        if (std.mem.eql(u8, expected_types[index], "agent_end")) {
            try std.testing.expect(object.contains("messages"));
            try std.testing.expectEqual(false, object.get("willRetry").?.bool);
        }
        index += 1;
    }
    try std.testing.expectEqual(expected_types.len, index);
    try std.testing.expectEqualStrings("", err_output.written());
}
