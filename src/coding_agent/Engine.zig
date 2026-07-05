const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const client_protocol = @import("client_protocol.zig");
const engine_drain = @import("engine_drain.zig");
const file_completion = @import("file_completion.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_listing = @import("session_listing.zig");
const session_manager = @import("session_manager.zig");
const settings_mod = @import("settings.zig");
const slash_commands = @import("slash_commands.zig");
const vm = @import("view_model.zig");

const prompt_progress_events_per_turn_max: usize = 16;
const active_work_poll_interval_ms: u64 = 16;
const SessionStats = client_protocol.PromptCommandSessionStats;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    services: RuntimeServices = undefined,
    services_initialized: bool = false,
    session: AgentSession = undefined,
    task_runtime: *runtime.Runtime = undefined,
    dir: std.Io.Dir = .cwd(),
    initialized: bool = false,
    init_state: std.atomic.Value(u8) = .init(0), // 0 initing, 1 ready, 2 failed
    init_error: ?anyerror = null,
    view_model: vm.ViewModel,
    drain: engine_drain.EngineDrain,
    mailbox_storage: []client_protocol.CommandEnvelope,
    mailbox: client_protocol.CommandQueue,
    mailbox_mutex: runtime.SharedMutex = .{},
    accepting: std.atomic.Value(bool) = .init(true),
    stop_requested: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    wake_pipe: [2]std.c.fd_t = .{ -1, -1 },
    owner_wake: runtime.WakeEvent = .init,
    reader_fds: [vm.reader_wake_list_max]std.c.fd_t = undefined,
    reader_fds_len: usize = 0,
    reader_mutex: runtime.SharedMutex = .{},
    active: ?ActiveOperation = null,
    file_index: ?file_completion.Index = null,
    session_open: ?SessionOpenLoad = null,
    next_operation_id: u64 = 1,

    const SessionOpenLoad = struct {
        selector: []u8,
        create: bool = false,
    };

    const ActiveOperation = struct {
        handle: ?AgentSession.RunHandle,
        retry_wait: ?RetryWait = null,
        prompt_text: []u8,
        prompt_images: []ai.ImageContent,
        overflow_count_before: usize,
        overflow_retry_used: bool = false,
        cancel_requested: bool = false,

        const RetryWait = struct {
            kind: AgentSession.SettleVerdict.Retry.Kind,
            resume_at_ms: i64,
        };
    };

    pub const Open = union(enum) {
        none,
        create: struct { session_id: []const u8, timestamp: []const u8 },
        resume_existing: struct { session_file_name: []const u8 },
    };

    pub const Options = struct {
        cwd: []const u8 = ".",
        agent_dir_override: ?[]const u8 = null,
        current_date: []const u8,
        open: Open = .none,
        model: ?ai.Model = null,
        thinking_level: ?agent_mod.ThinkingLevel = null,
        stream: ?ai.StreamFunction = null,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
        home_dir: ?[]const u8 = null,
        task_runtime: ?*runtime.Runtime = null,
        allow_paths_outside_cwd: bool = true,
        public_event_capacity: usize = AgentSession.public_event_capacity_default,
        command_capacity: usize = client_protocol.command_queue_capacity_default,
    };

    pub const SessionStamp = struct {
        text: [20]u8,
        nanoseconds: i96,

        pub fn now(io: std.Io) SessionStamp {
            const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
            const seconds_total = @divFloor(nanoseconds, std.time.ns_per_s);
            const epoch_seconds: std.time.epoch.EpochSeconds = .{
                .secs = if (seconds_total > 0) @intCast(seconds_total) else 0,
            };
            const year_day = epoch_seconds.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_seconds = epoch_seconds.getDaySeconds();
            var self: SessionStamp = .{ .text = undefined, .nanoseconds = nanoseconds };
            _ = std.fmt.bufPrint(&self.text, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            }) catch unreachable;
            return self;
        }

        pub fn date(self: *const SessionStamp) []const u8 {
            return self.text[0..10];
        }

        pub fn timestamp(self: *const SessionStamp) []const u8 {
            return &self.text;
        }
    };

    pub const SubmitError = error{ Full, ShuttingDown };

    pub fn start(allocator: std.mem.Allocator, process_runtime: ?*runtime.Runtime, options: Options) !*Engine {
        _ = process_runtime;
        const wake_pipe = try createPipe();
        errdefer closePipe(wake_pipe);
        const command_capacity = if (options.command_capacity == 0) client_protocol.command_queue_capacity_default else options.command_capacity;
        const mailbox_storage = try allocator.alloc(client_protocol.CommandEnvelope, command_capacity);
        errdefer allocator.free(mailbox_storage);

        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        var view_model = try vm.ViewModel.init(allocator);
        errdefer view_model.deinit(allocator);
        self.* = .{
            .allocator = allocator,
            .view_model = view_model,
            .drain = undefined,
            .dir = options.dir,
            .mailbox_storage = mailbox_storage,
            .mailbox = client_protocol.CommandQueue.init(mailbox_storage),
            .wake_pipe = wake_pipe,
        };
        self.drain = engine_drain.EngineDrain.init(allocator, &self.view_model);
        self.drain.home_dir = options.home_dir;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{ self, options });
        while (self.init_state.load(.acquire) == 0) std.Thread.yield() catch {};
        if (self.init_state.load(.acquire) == 2) {
            const err = self.init_error orelse error.EngineInitFailed;
            self.thread.?.join();
            self.thread = null;
            self.deinitPartial();
            return err;
        }
        return self;
    }

    pub fn submit(self: *Engine, envelope: client_protocol.CommandEnvelope) SubmitError!void {
        if (!self.accepting.load(.acquire)) return error.ShuttingDown;
        self.mailbox_mutex.lock();
        defer self.mailbox_mutex.unlock();
        if (!self.accepting.load(.acquire)) return error.ShuttingDown;
        self.mailbox.push(envelope) catch return error.Full;
        wakeFd(self.wake_pipe[1]);
    }

    pub fn viewModel(self: *Engine) *vm.ViewModel {
        return &self.view_model;
    }

    pub fn attachReaderWakeFd(self: *Engine, fd: std.c.fd_t) !void {
        self.reader_mutex.lock();
        defer self.reader_mutex.unlock();
        if (self.reader_fds_len >= self.reader_fds.len) return error.Full;
        self.reader_fds[self.reader_fds_len] = fd;
        self.reader_fds_len += 1;
    }

    pub fn requestShutdown(self: *Engine) void {
        if (!self.accepting.swap(false, .acq_rel)) return;
        self.stop_requested.store(true, .release);
        wakeFd(self.wake_pipe[1]);
    }

    pub fn join(self: *Engine) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.deinit();
    }

    fn deinit(self: *Engine) void {
        const allocator = self.allocator;
        self.drain.deinit();
        self.view_model.deinit(allocator);
        while (self.mailbox.pop()) |envelope| {
            var owned = envelope;
            owned.deinit(allocator);
        }
        if (self.active) |active| self.destroyActive(active);
        if (self.file_index) |*index| index.deinit(std.heap.page_allocator);
        if (self.session_open) |load| self.allocator.free(load.selector);
        if (self.initialized) shutdownAndDeinitSession(&self.session);
        if (self.services_initialized) {
            self.services.deinit();
            self.task_runtime.deinit();
        }
        allocator.free(self.mailbox_storage);
        closePipe(self.wake_pipe);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn deinitPartial(self: *Engine) void {
        const allocator = self.allocator;
        self.drain.deinit();
        self.view_model.deinit(allocator);
        allocator.free(self.mailbox_storage);
        closePipe(self.wake_pipe);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn threadMain(self: *Engine, options: Options) void {
        self.initInThread(options) catch |err| {
            self.init_error = err;
            self.init_state.store(2, .release);
            return;
        };
        self.init_state.store(1, .release);
        self.run() catch |err| self.drain.notice(.err, .operation_failed, @errorName(err));
    }

    fn initInThread(self: *Engine, options: Options) !void {
        self.task_runtime = try runtime.Runtime.init(self.allocator, .{});
        errdefer self.task_runtime.deinit();
        const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
            agent_dir_override
        else
            try paths_mod.resolveGlobalAgentDirFromEnv(self.allocator, options.environ);
        defer if (options.agent_dir_override == null) self.allocator.free(resolved_agent_dir);
        const resolved_cwd = if (std.mem.eql(u8, options.cwd, ".")) blk: {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = try options.dir.realPathFile(self.task_runtime.io(), options.cwd, &buffer);
            break :blk try self.allocator.dupe(u8, buffer[0..len]);
        } else try self.allocator.dupe(u8, options.cwd);
        defer self.allocator.free(resolved_cwd);
        self.services = try RuntimeServices.init(self.allocator, .{
            .cwd = resolved_cwd,
            .agent_dir = resolved_agent_dir,
            .dir = options.dir,
            .environ = options.environ,
            .task_runtime = self.task_runtime,
        });
        self.services_initialized = true;
        errdefer {
            self.services.deinit();
            self.services_initialized = false;
        }
        if (options.open != .none) {
            self.session = try openSession(self.allocator, &self.services, options, &self.drain);
            errdefer shutdownAndDeinitSession(&self.session);
            self.initialized = true;
            self.publishChrome();
        } else {
            var chrome: vm.Chrome = .{};
            chrome.cwd.set(self.services.cwd);
            self.drain.setChrome(chrome);
        }
    }

    fn run(self: *Engine) !void {
        while (true) {
            self.drainWakePipe();
            try self.drainMailbox();
            self.finishSessionOpen() catch |err| self.drain.notice(.warn, .operation_failed, @errorName(err));
            try self.stepActive();
            self.wakeReadersIfDirty();

            if (self.stop_requested.load(.acquire)) {
                self.accepting.store(false, .release);
                self.drain.shuttingDown();
                if (self.active != null) {
                    self.requestActiveCancel();
                    self.waitForWork();
                    continue;
                }
                if (self.initialized) self.session.requestShutdown();
                self.drain.stopped();
                self.wakeReadersIfDirty();
                return;
            }

            if (!self.hasImmediateWork()) self.waitForWork();
        }
    }

    fn drainMailbox(self: *Engine) !void {
        while (true) {
            self.mailbox_mutex.lock();
            const maybe = self.mailbox.pop();
            self.mailbox_mutex.unlock();
            var envelope = maybe orelse break;
            defer envelope.deinit(self.allocator);
            if (!self.accepting.load(.acquire) and envelope.command != .shutdown) continue;
            try self.applyCommand(envelope);
        }
    }

    fn applyCommand(self: *Engine, envelope: client_protocol.CommandEnvelope) !void {
        switch (envelope.command) {
            .submit => |prompt| {
                if (!self.initialized) {
                    try self.startNewSession();
                    self.drain.notice(.warn, .generic, "opening session; submit again");
                    return;
                }
                if (slash_commands.dispatch(prompt.text)) |action| {
                    try self.applySlashCommand(action);
                    return;
                }
                if (self.active != null) {
                    self.drain.notice(.warn, .queue_full, "operation already active");
                    return;
                }
                const prompt_text = try self.allocator.dupe(u8, prompt.text);
                errdefer self.allocator.free(prompt_text);
                const prompt_images = try client_protocol.copySubmitImages(self.allocator, prompt.images);
                errdefer client_protocol.freeSubmitImages(self.allocator, prompt_images);
                var handle = self.session.startPromptHandle(prompt.text, prompt.images) catch |err| {
                    self.drain.notice(.err, .operation_failed, @errorName(err));
                    return;
                };
                handle.setWake(self.services.io, &self.owner_wake);
                self.active = .{
                    .handle = handle,
                    .prompt_text = prompt_text,
                    .prompt_images = prompt_images,
                    .overflow_count_before = self.session.contextOverflowCount(),
                };
                self.drain.operationRunning(self.nextOperationId());
            },
            .cancel => {
                if (self.active == null) {
                    self.drain.notice(.warn, .operation_failed, "cancel target not active");
                    return;
                }
                self.requestActiveCancel();
            },
            .shutdown => self.requestShutdown(),
            .queue => |queue_command| switch (queue_command) {
                .clear => if (self.initialized) self.session.clearQueue(),
            },
            .completion_snapshot => try self.publishCompletionSnapshot(envelope.id orelse 0),
            .file_completion => |request| try self.publishFileCompletion(envelope.id orelse 0, request.query),
            .switch_session => |request| try self.startSwitchSession(request.session_file_name),
            .history_tail => self.drain.closeHistory(),
            .history_page => |request| try self.publishHistoryPage(request.before_entry_id),
            .snapshot,
            .replay,
            => self.drain.notice(.warn, .operation_failed, "command not implemented in Engine run B"),
        }
    }

    fn applySlashCommand(self: *Engine, action: slash_commands.Action) !void {
        switch (action) {
            .help => {
                var buffer: [160]u8 = undefined;
                self.drain.notice(.info, .generic, slash_commands.formatAvailable(&buffer));
            },
            .new_session => try self.startNewSession(),
            .compact => try self.startManualCompaction(),
            .resume_session => |selector| if (selector.len > 0) try self.startSwitchSession(selector),
            .model => |name| {
                if (self.active != null) return self.drain.notice(.warn, .queue_full, "operation already active");
                const slash = std.mem.indexOfScalar(u8, name, '/') orelse return self.drain.notice(.warn, .operation_failed, "unknown model");
                const model = ai.getModel(name[0..slash], name[slash + 1 ..]) orelse return self.drain.notice(.warn, .operation_failed, "unknown model");
                const stream = if (self.services.provider_registry.get(model.api)) |provider| provider.stream_simple else null;
                try self.session.setModel(model, stream);
                self.publishChrome();
            },
            .thinking_level => |level| try self.applySessionSetting(level, null),
            .hide_thinking => |hidden| try self.applySessionSetting(null, hidden),
            .session => try self.publishSessionInfo(),
            .settings => self.drain.notice(.info, .generic, "choose a setting"),
            .unknown => |name| self.drain.notice(.warn, .operation_failed, name),
        }
    }

    fn applySessionSetting(self: *Engine, level: ?agent_mod.ThinkingLevel, hidden: ?bool) !void {
        if (self.active != null) return self.drain.notice(.warn, .queue_full, "operation already active");
        if (level) |value| try self.session.setThinkingLevel(value);
        if (hidden) |value| {
            try self.services.settings_manager.setHideThinkingBlock(
                self.services.io,
                self.dir,
                value,
            );
            try self.session.setHideThinking(value);
        }
        self.publishChrome();
    }

    fn publishCompletionSnapshot(self: *Engine, query_id: u64) !void {
        if (query_id == 3) return self.publishResumeCompletion(query_id);
        self.drain.startCompletion(query_id, .model);
        var items = std.ArrayList(vm.CompletionItem).empty;
        defer items.deinit(self.allocator);
        outer: for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (items.items.len == vm.completion_items_max) break :outer;
                var item: vm.CompletionItem = .{};
                const id = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider, model.id });
                defer self.allocator.free(id);
                item.id.set(id);
                item.label.set(id);
                item.detail.set(model.name);
                try items.append(self.allocator, item);
            }
        }
        try self.drain.setCompletion(query_id, .model, items.items);
    }

    fn publishResumeCompletion(self: *Engine, query_id: u64) !void {
        self.drain.startCompletion(query_id, .resume_session);
        var summaries = try session_listing.listRuntimeSessionSummaries(self.allocator, self.services.io, .{
            .cwd = self.services.cwd,
            .agent_dir_override = self.services.agent_dir,
            .dir = self.dir,
            .environ = self.services.environ,
        });
        defer summaries.deinit(self.allocator);
        var items = std.ArrayList(vm.CompletionItem).empty;
        defer items.deinit(self.allocator);
        for (summaries.items) |summary| {
            if (items.items.len == vm.completion_items_max) break;
            var item: vm.CompletionItem = .{};
            item.id.set(summary.file_name);
            item.label.set(summary.title);
            item.detail.set(summary.detail);
            try items.append(self.allocator, item);
        }
        try self.drain.setCompletion(query_id, .resume_session, items.items);
    }

    fn publishFileCompletion(self: *Engine, query_id: u64, query: []const u8) !void {
        self.drain.startCompletion(query_id, .file);
        if (self.file_index == null) self.file_index = try buildProjectFileIndex(self.dir, self.services.cwd);
        const result = try self.file_index.?.query(std.heap.page_allocator, query);
        defer result.destroy(std.heap.page_allocator);
        var items: [file_completion.item_count_max]vm.CompletionItem = undefined;
        var count: usize = 0;
        for (result.items[0..result.item_len]) |*source| {
            items[count] = .{};
            items[count].id.set(source.idSlice());
            items[count].label.set(source.label[0..source.label_len]);
            items[count].detail.set(source.detail[0..source.detail_len]);
            count += 1;
        }
        try self.drain.setCompletion(query_id, .file, items[0..count]);
    }

    fn publishHistoryPage(self: *Engine, before_entry_id: []const u8) !void {
        if (!self.initialized) return self.drain.notice(.warn, .operation_failed, "no session");
        var page = client_protocol.HistoryPage.beforeEntry(
            self.allocator,
            self.session.manager,
            before_entry_id,
        ) catch |err| {
            self.drain.notice(.warn, .operation_failed, @errorName(err));
            return;
        };
        defer page.deinit(self.allocator);
        try self.drain.publishHistoryPage(page);
    }

    fn publishSessionInfo(self: *Engine) !void {
        if (!self.initialized) return self.drain.notice(.warn, .operation_failed, "no session");
        var buffer: [2048]u8 = undefined;
        const stats = collectSessionStats(self.session.manager);
        const text = formatSessionInfo(
            &buffer,
            if (self.session.store) |store| store.file_name else null,
            self.session.manager.header.id,
            stats,
        );
        try self.drain.transcriptCustom("Session Info", text, true);
    }

    fn startSwitchSession(self: *Engine, selector: []const u8) !void {
        if (self.session_open != null) {
            self.drain.notice(.warn, .queue_full, "session open already loading");
            return;
        }
        self.session_open = .{ .selector = try self.allocator.dupe(u8, selector) };
    }

    fn startNewSession(self: *Engine) !void {
        var buffer: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&buffer, "session-{d}", .{nowMs()}) catch "session-new";
        if (self.session_open != null) {
            self.drain.notice(.warn, .queue_full, "session open already loading");
            return;
        }
        self.session_open = .{ .selector = try self.allocator.dupe(u8, id), .create = true };
    }

    fn finishSessionOpen(self: *Engine) !void {
        const load = self.session_open orelse return;
        self.session_open = null;
        defer self.allocator.free(load.selector);
        if (self.active != null) {
            self.drain.notice(.warn, .queue_full, "cancel active operation before resume");
            return;
        }
        var next_services = try RuntimeServices.init(self.allocator, .{
            .cwd = self.services.cwd,
            .agent_dir = self.services.agent_dir,
            .dir = self.dir,
            .environ = self.services.environ,
            .task_runtime = self.task_runtime,
        });
        errdefer next_services.deinit();
        var next_drain = engine_drain.EngineDrain.init(self.allocator, &self.view_model);
        errdefer next_drain.deinit();
        const stamp = SessionStamp.now(self.services.io);
        const open: Open = if (load.create)
            .{ .create = .{ .session_id = load.selector, .timestamp = stamp.timestamp() } }
        else
            .{ .resume_existing = .{ .session_file_name = load.selector } };
        const current_model = if (self.initialized) self.session.agent.state.model else agent_mod.Agent.defaultModel();
        const current_thinking = if (self.initialized) self.session.agent.state.thinking_level else agent_mod.ThinkingLevel.off;
        const current_stream = if (self.initialized) self.session.agent.loopConfig().stream else null;
        var next_session = try openSession(self.allocator, &next_services, .{
            .cwd = self.services.cwd,
            .agent_dir_override = self.services.agent_dir,
            .current_date = stamp.date(),
            .open = open,
            .model = current_model,
            .thinking_level = current_thinking,
            .stream = current_stream,
            .dir = self.dir,
            .environ = self.services.environ,
        }, &next_drain);
        errdefer shutdownAndDeinitSession(&next_session);
        var old_session = self.session;
        var old_services = self.services;
        const had_session = self.initialized;
        self.session = next_session;
        self.services = next_services;
        self.initialized = true;
        self.drain.deinit();
        self.drain = next_drain;
        if (had_session) shutdownAndDeinitSession(&old_session);
        old_services.deinit();
        self.drain.bumpEpoch();
        self.drain.notice(.info, .generic, if (load.create) "started new session" else "resumed session");
        self.publishChrome();
    }

    fn startManualCompaction(self: *Engine) !void {
        if (self.active != null) {
            self.drain.notice(.warn, .queue_full, "operation already active");
            return;
        }
        var handle = try self.session.startCompactionHandle(.manual, false, null) orelse {
            self.drain.notice(.info, .generic, "nothing to compact");
            return;
        };
        handle.setWake(self.services.io, &self.owner_wake);
        const prompt_text = try self.allocator.dupe(u8, "");
        self.active = .{
            .handle = handle,
            .prompt_text = prompt_text,
            .prompt_images = &.{},
            .overflow_count_before = self.session.contextOverflowCount(),
        };
        self.drain.compactionStart(.manual);
    }

    fn stepActive(self: *Engine) !void {
        var count: usize = 0;
        while (count < prompt_progress_events_per_turn_max) : (count += 1) {
            const active = if (self.active) |*active| active else return;
            if (active.handle) |*handle| {
                switch (try handle.poll(&self.session)) {
                    .live => {},
                    .empty => {
                        if (handle.kind == .prompt) runtime.yield() catch {};
                        return;
                    },
                    .settled => try self.settleActive(active, handle),
                }
                if (self.drain.isDirty()) return;
                continue;
            }
            const wait = active.retry_wait orelse return;
            if (nowMs() < wait.resume_at_ms) return;
            var handle = switch (wait.kind) {
                .resubmit_prompt => try self.session.startPromptHandle(active.prompt_text, active.prompt_images),
                .continue_run => try self.session.startContinueHandle(),
            };
            handle.setWake(self.services.io, &self.owner_wake);
            active.retry_wait = null;
            active.handle = handle;
            self.drain.operationRunning(self.nextOperationId());
            if (self.drain.isDirty()) return;
        }
    }

    fn settleActive(self: *Engine, active: *ActiveOperation, handle: *AgentSession.RunHandle) !void {
        const verdict = handle.settle(&self.session, .{
            .overflow_count_before = active.overflow_count_before,
            .overflow_retry_used = active.overflow_retry_used,
        }) catch |err| {
            handle.deinitAfterSettled(&self.session);
            active.handle = null;
            self.finishActiveFailed(@errorName(err));
            return;
        };
        handle.deinitAfterSettled(&self.session);
        active.handle = null;
        switch (verdict) {
            .completed => if (active.cancel_requested) self.finishActiveCanceled() else self.finishActiveCompleted(),
            .failed => if (active.cancel_requested) self.finishActiveCanceled() else self.finishActiveFailed("operation failed"),
            .retry => |retry| active.retry_wait = .{
                .kind = retry.kind,
                .resume_at_ms = nowMs() + @as(i64, @intCast(retry.delay_ms)),
            },
            .compact => |compaction_run| {
                active.overflow_retry_used = true;
                active.handle = AgentSession.RunHandle.compaction(compaction_run);
                active.handle.?.setWake(self.services.io, &self.owner_wake);
            },
        }
    }

    fn finishActiveCompleted(self: *Engine) void {
        const active = self.takeActive() orelse return;
        self.freeActive(active);
        self.drain.operationIdle();
    }

    fn finishActiveCanceled(self: *Engine) void {
        const active = self.takeActive() orelse return;
        self.freeActive(active);
        self.drain.cancelStreaming();
        self.drain.operationIdle();
    }

    fn finishActiveFailed(self: *Engine, message: []const u8) void {
        const active = self.takeActive() orelse return;
        self.freeActive(active);
        if (self.session.latestOperationalFailure()) |failure| {
            self.drain.operationalFailure(failure);
        } else {
            self.drain.notice(.err, .operation_failed, message);
        }
        self.drain.operationIdle();
    }

    fn takeActive(self: *Engine) ?ActiveOperation {
        const active = self.active orelse return null;
        self.active = null;
        return active;
    }

    fn requestActiveCancel(self: *Engine) void {
        if (self.active) |*active| {
            if (active.cancel_requested) return;
            active.cancel_requested = true;
            if (active.handle) |*handle| {
                handle.cancelRequest(&self.session);
            } else if (active.retry_wait != null) {
                self.session.cancelRetryWait();
                active.retry_wait = null;
            }
            self.drain.operationCancelRequested();
            self.drain.cancelStreaming();
        }
    }

    fn destroyActive(self: *Engine, active: ActiveOperation) void {
        var owned = active;
        if (owned.handle) |*handle| handle.deinitAfterSettled(&self.session);
        if (owned.retry_wait != null) self.session.cancelRetryWait();
        self.freeActive(owned);
    }

    fn freeActive(self: *Engine, active: ActiveOperation) void {
        self.allocator.free(active.prompt_text);
        client_protocol.freeSubmitImages(self.allocator, active.prompt_images);
    }

    fn hasImmediateWork(self: *Engine) bool {
        self.mailbox_mutex.lock();
        const mail = self.mailbox.count() > 0;
        self.mailbox_mutex.unlock();
        return mail or self.active != null or self.stop_requested.load(.acquire);
    }

    fn waitForWork(self: *Engine) void {
        if (self.active != null) {
            self.owner_wake.waitTimeout(self.services.io, .{ .duration = .{ .raw = .fromMilliseconds(active_work_poll_interval_ms), .clock = .awake } }) catch {};
            if (self.owner_wake.isSet()) self.owner_wake.reset();
            return;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = self.wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 30_000) catch {};
    }

    fn wakeReadersIfDirty(self: *Engine) void {
        if (!self.drain.takeDirty()) return;
        self.reader_mutex.lock();
        defer self.reader_mutex.unlock();
        for (self.reader_fds[0..self.reader_fds_len]) |fd| wakeFd(fd);
    }

    fn publishChrome(self: *Engine) void {
        self.drain.setChrome(self.session.chrome(self.services.cwd));
    }

    fn nextOperationId(self: *Engine) u64 {
        defer self.next_operation_id +%= 1;
        return self.next_operation_id;
    }

    fn drainWakePipe(self: *Engine) void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            _ = std.posix.poll(&fds, 0) catch return;
            if ((fds[0].revents & std.posix.POLL.IN) == 0) return;
            var buf: [64]u8 = undefined;
            const n = std.posix.read(self.wake_pipe[0], &buf) catch return;
            if (n == 0 or n < buf.len) return;
            fds[0].revents = 0;
        }
    }
};

fn collectSessionStats(manager: *const session_manager.SessionManager) SessionStats {
    var stats: SessionStats = .{};
    for (manager.entries.items) |entry| switch (entry) {
        .compaction, .model_change, .thinking_level_change => {},
        .message => |message_entry| {
            stats.total_messages += 1;
            switch (message_entry.message) {
                .user => stats.user_messages += 1,
                .assistant => |assistant| {
                    stats.assistant_messages += 1;
                    stats.input_tokens +|= assistant.usage.input;
                    stats.output_tokens +|= assistant.usage.output;
                    stats.cache_read_tokens +|= assistant.usage.cache_read;
                    stats.cache_write_tokens +|= assistant.usage.cache_write;
                    stats.total_tokens +|= assistant.usage.input +|
                        assistant.usage.output +|
                        assistant.usage.cache_read +|
                        assistant.usage.cache_write;
                    stats.cost += assistant.usage.cost.total;
                    for (assistant.content) |content| switch (content) {
                        .tool_call => stats.tool_calls += 1,
                        .text, .thinking => {},
                    };
                },
                .tool_result => stats.tool_results += 1,
                .custom => {},
            }
        },
    };
    return stats;
}

fn formatSessionInfo(buffer: []u8, file: ?[]const u8, id: []const u8, stats: SessionStats) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (file) |path| {
        writer.print("File: {s}\n", .{path}) catch return "session status unavailable";
    } else {
        writer.writeAll("File: In-memory\n") catch return "session status unavailable";
    }
    writer.print("ID: {s}\n\n", .{id}) catch return "session status unavailable";
    writer.writeAll("**Messages**\n") catch return "session status unavailable";
    writer.print("User: {d}\n", .{stats.user_messages}) catch return "session status unavailable";
    writer.print("Assistant: {d}\n", .{stats.assistant_messages}) catch return "session status unavailable";
    writer.print("Tool Calls: {d}\n", .{stats.tool_calls}) catch return "session status unavailable";
    writer.print("Tool Results: {d}\n", .{stats.tool_results}) catch return "session status unavailable";
    writer.print("Total: {d}\n\n", .{stats.total_messages}) catch return "session status unavailable";
    writer.writeAll("**Tokens**\n") catch return "session status unavailable";
    writer.print("Input: {d}\n", .{stats.input_tokens}) catch return "session status unavailable";
    writer.print("Output: {d}\n", .{stats.output_tokens}) catch return "session status unavailable";
    if (stats.cache_read_tokens > 0) {
        writer.print("Cache Read: {d}\n", .{stats.cache_read_tokens}) catch return "session status unavailable";
    }
    if (stats.cache_write_tokens > 0) {
        writer.print("Cache Write: {d}\n", .{stats.cache_write_tokens}) catch return "session status unavailable";
    }
    writer.print("Total: {d}", .{stats.total_tokens}) catch return "session status unavailable";
    if (stats.cost > 0) {
        writer.print("\n\n**Cost**\nTotal: {d:.4}", .{stats.cost}) catch return "session status unavailable";
    }
    return writer.buffered();
}

fn openSession(
    allocator: std.mem.Allocator,
    services: *RuntimeServices,
    options: Engine.Options,
    drain: *engine_drain.EngineDrain,
) !AgentSession {
    const sessions_dir = try (paths_mod.PersistencePaths{ .global_dir = services.agent_dir, .cwd = services.cwd }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);

    const snapshot = services.settings_manager.current();
    const project = settingsValue(snapshot.project);
    const global = settingsValue(snapshot.global);
    var retry: AgentSession.RetrySettings = .{};
    const retry_settings = project.retry orelse global.retry;
    if (retry_settings) |value| {
        if (value.enabled) |enabled| retry.enabled = enabled;
        if (value.max_retries) |attempts| retry.max_attempts = std.math.lossyCast(u8, attempts);
        if (value.base_delay_ms) |delay| retry.base_delay_ms = delay;
    }

    // Startup resolution: explicit option -> project settings -> global
    // settings -> first authed model -> default. Provider and model are
    // scope-atomic: they resolve as a pair from one scope, never mixed.
    const model = options.model orelse model: {
        const pair = if (project.default_provider != null or project.default_model != null) project else global;
        if (pair.default_provider) |provider_name| {
            if (pair.default_model) |model_id| {
                if (ai.getModel(provider_name, model_id)) |model| {
                    if (services.auth_manager.hasAuth(model.provider) and
                        services.provider_registry.get(model.api) != null) break :model model;
                }
            }
        }
        for (ai.getProviders()) |provider_name| {
            for (ai.getModels(provider_name)) |model| {
                if (services.auth_manager.hasAuth(model.provider) and
                    services.provider_registry.get(model.api) != null) break :model model;
            }
        }
        break :model agent_mod.Agent.defaultModel();
    };
    const thinking_level = options.thinking_level orelse level: {
        if (project.default_thinking_level orelse global.default_thinking_level) |text| {
            if (parseThinkingLevel(text)) |parsed| break :level parsed;
        }
        break :level .off;
    };
    const hide_thinking = project.hide_thinking_block orelse global.hide_thinking_block orelse true;

    var session_options: AgentSession.Options = .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .session_id = "",
        .timestamp = "",
        .model = model,
        .thinking_level = thinking_level,
        .hide_thinking = hide_thinking,
        .stream = options.stream,
        .get_api_key = services.auth_manager.hook(),
        .dir = options.dir,
        .environ = options.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
        .retry_settings = retry,
        .view_sink = drain,
        .task_runtime = services.task_runtime,
    };
    if (session_options.stream == null) {
        if (services.provider_registry.get(session_options.model.api)) |provider| session_options.stream = provider.stream_simple;
    }

    switch (options.open) {
        .none => return error.SessionRequired,
        .create => |create| {
            var store = try session_manager.SessionStore.createDeferred(allocator, services.io, options.dir, .{
                .sessions_dir = sessions_dir,
                .cwd = services.cwd,
                .session_id = create.session_id,
                .timestamp = create.timestamp,
            });
            errdefer store.deinit();
            session_options.session_id = create.session_id;
            session_options.timestamp = create.timestamp;
            session_options.store = .{ .create = store };
            return AgentSession.init(allocator, services.io, session_options);
        },
        .resume_existing => |resume_open| {
            const selected = try session_listing.selectRuntimeSession(allocator, services.io, .{
                .cwd = services.cwd,
                .agent_dir_override = services.agent_dir,
                .dir = options.dir,
                .environ = options.environ,
                .selector = resume_open.session_file_name,
            }) orelse return error.SessionNotFound;
            defer allocator.free(selected);
            const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, selected });
            errdefer allocator.free(file_name);
            session_options.store = .{ .restore = .{
                .allocator = allocator,
                .dir = options.dir,
                .file_name = file_name,
            } };
            return AgentSession.init(allocator, services.io, session_options);
        },
    }
}

fn settingsValue(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

fn parseThinkingLevel(text: []const u8) ?agent_mod.ThinkingLevel {
    inline for (@typeInfo(agent_mod.ThinkingLevel).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @field(agent_mod.ThinkingLevel, field.name);
    }
    return null;
}

fn shutdownAndDeinitSession(session: *AgentSession) void {
    session.requestShutdown();
    session.deinit();
}

fn buildProjectFileIndex(dir: std.Io.Dir, cwd: []const u8) !file_completion.Index {
    const project_fd = try std.posix.openat(dir.handle, cwd, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    defer _ = std.c.close(project_fd);
    const project_dir: std.Io.Dir = .{ .handle = project_fd };
    return file_completion.Index.build(std.heap.page_allocator, project_dir);
}

fn nowMs() i64 {
    return @intCast(@divFloor(@import("../runtime/root.zig").SharedMutexHoldTimer.start().start_ns, std.time.ns_per_ms));
}

fn createPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    if (fds[0] >= 0) _ = std.c.close(fds[0]);
    if (fds[1] >= 0) _ = std.c.close(fds[1]);
}

fn wakeFd(fd: std.c.fd_t) void {
    if (fd < 0) return;
    const byte: [1]u8 = .{1};
    _ = std.c.write(fd, &byte, byte.len);
}

fn engineTestOptions(tmp: *std.testing.TmpDir, provider: *ai.FauxProvider) !Engine.Options {
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    return .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-07-04",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-07-04T00:00:00Z" } },
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    };
}

test "engine prompt publishes final committed assistant item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "pong" } }};
    const replies = [_]ai.AssistantMessage{ai.faux.assistantMessage(&content, .{ .stop_reason = .stop })};
    try provider.setResponses(&replies);
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "ping", .auto));
    try waitForAssistant(engine, "pong", true);
}

test "engine submit while running emits busy notice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "busy" } }};
    const replies = [_]ai.AssistantMessage{ai.faux.assistantMessage(&content, .{ .stop_reason = .stop })};
    try provider.setResponses(&replies);
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "one", .auto));
    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "two", .auto));
    try waitForNotice(engine, .queue_full);
}

test "engine cancel marks streaming items canceled and op idle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "cancel" } }};
    const replies = [_]ai.AssistantMessage{ai.faux.assistantMessage(&content, .{ .stop_reason = .stop })};
    try provider.setResponses(&replies);
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "one", .auto));
    try engine.submit(.{ .id = 2, .command = .{ .cancel = .{} } });
    try waitForCanceledIdle(engine);
}

const RetryStream = struct {
    var calls: usize = 0;

    fn reset() void {
        calls = 0;
    }

    fn stream(_: ?*anyopaque, request: ai.StreamRequest) ai.AssistantMessageEventStream {
        calls += 1;
        var out = ai.AssistantMessageEventStream.initBuffered();
        const sink = out.sink();
        if (calls == 1) {
            var message = ai.protocol.emptyAssistantMessageFromRequest(request, .error_, "rate limit");
            message.operational_failure = .{
                .category = .rate_limited,
                .message = "rate limit",
                .retryable = .yes,
                .provider = request.model.provider,
                .model = request.model.id,
            };
            sink.endError(request.io, .error_, message) catch unreachable;
        } else {
            sink.endDone(request.io, .stop, .{
                .content = &.{.{ .text = .{ .text = "recovered" } }},
                .api = request.model.api,
                .provider = request.model.provider,
                .model = request.model.id,
                .usage = ai.protocol.emptyUsage(),
                .stop_reason = .stop,
                .timestamp = 0,
            }) catch unreachable;
        }
        return out;
    }
};

test "engine retry wait phase visible then resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var options = try engineTestOptions(&tmp, &provider);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/settings.json", .data = "{\"retry\":{\"enabled\":true,\"maxRetries\":2,\"baseDelayMs\":1}}" });
    options.stream = .{ .call_fn = RetryStream.stream };
    RetryStream.reset();
    const engine = try Engine.start(std.testing.allocator, null, options);
    defer engine.join();
    defer engine.requestShutdown();
    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "ping", .auto));
    try waitForRetryWait(engine);
    try waitForAssistant(engine, "recovered", true);
}

test "engine slash session publishes transcript info" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "/session", .auto));
    try waitForCustom(engine, "Session Info", "**Messages**");
}

test "engine file completion publishes latest slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/a.zig", .data = "" });
    const engine = try Engine.start(std.testing.allocator, null, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-07-04",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-07-04T00:00:00Z" } },
        .dir = tmp.dir,
        .model = provider.getModel(),
        .stream = provider.apiProvider().stream,
    });
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initFileCompletion(std.testing.allocator, 42, "src/a"));
    try waitForCompletion(engine, 42, .file, "src/a.zig");
}

test "engine new session bumps epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 9, "/new", .auto));
    try waitForEpoch(engine, 1);
}

test "engine session open while in flight rejects busy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    defer engine.requestShutdown();

    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "/new", .auto));
    try engine.submit(try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "/new", .auto));
    try waitForNotice(engine, .queue_full);
}

test "engine submit after shutdown rejects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = try ai.FauxProvider.init(std.testing.allocator, .{});
    defer provider.deinit();
    const engine = try Engine.start(std.testing.allocator, null, try engineTestOptions(&tmp, &provider));
    defer engine.join();
    engine.requestShutdown();
    try std.testing.expectError(error.ShuttingDown, engine.submit(.{ .command = .snapshot }));
}

fn waitForAssistant(engine: *Engine, text: []const u8, committed: bool) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        for (sample.items.items) |item| {
            if (item.kind == .assistant and item.text_len == text.len and (!committed or item.entry_id != null)) return;
        }
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForRetryWait(engine: *Engine) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        if (sample.op.phase == .retry_wait) return;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForCustom(engine: *Engine, title: []const u8, needle: []const u8) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        for (sample.items.items) |item| {
            if (item.kind == .banner and item.title.eql(title) and std.mem.indexOf(u8, item.text_suffix, needle) != null) return;
        }
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForCompletion(engine: *Engine, query_id: u64, kind: vm.CompletionSlot.Kind, id: []const u8) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        if (sample.completion) |completion| {
            if (completion.query_id == query_id and completion.kind == kind) {
                for (completion.items.items) |item| if (std.mem.eql(u8, item.id.slice(), id)) return;
            }
        }
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForEpoch(engine: *Engine, epoch: u32) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        if (sample.session_epoch >= epoch) return;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForNotice(engine: *Engine, semantic: vm.NoticeSemantic) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        for (sample.notices.items) |notice| if (notice.semantic == semantic) return;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}

fn waitForCanceledIdle(engine: *Engine) !void {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var saw_canceled = false;
    var iterations: usize = 0;
    while (iterations < 4000) : (iterations += 1) {
        var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(std.testing.allocator);
        for (sample.items.items) |item| {
            if (item.state == .canceled) saw_canceled = true;
        }
        if (saw_canceled and sample.op.phase == .idle) return;
        std.Thread.yield() catch {};
    }
    return error.Timeout;
}
