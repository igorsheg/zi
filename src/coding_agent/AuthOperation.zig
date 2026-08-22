const std = @import("std");
const ai = @import("../ai/root.zig");
const CredentialManager = @import("CredentialManager.zig");
const ModelConfigSnapshot = @import("ModelConfigSnapshot.zig");
const ZiPaths = @import("ZiPaths.zig");

const AuthOperation = @This();

pub const Limits = struct {
    max_facts: usize = 16,
    max_fact_bytes: usize = 16 * 1024,
    max_queued_fact_bytes: usize = 64 * 1024,
    max_answer_bytes: usize = 64 * 1024,
};

pub const StartError = error{
    OutOfMemory,
    InvalidPath,
    Cancelled,
    InvalidLimits,
    ThreadQuotaExceeded,
    SystemResources,
    LockedMemoryLimitExceeded,
    Unexpected,
};

pub const AnswerError = error{
    OutOfMemory,
    EmptyAnswer,
    AnswerTooLarge,
    NotAwaitingAnswer,
    Cancelled,
};

pub const Failure = enum {
    out_of_memory,
    invalid_credential_file,
    unsupported_version,
    unsafe_path,
    read_failed,
    lock_failed,
    write_failed,
    commit_indeterminate,
    timed_out,
    invalid_url,
    invalid_request,
    connection_failed,
    invalid_response,
    response_too_large,
    consumer_stopped,
    rejected,
    invalid_model_configuration,
    authentication_unavailable,
    refresh_unavailable,
};

pub const Outcome = union(enum) {
    succeeded,
    cancelled,
    failed: Failure,
};

/// Every string borrows an AuthOperation batch for the synchronous sink call.
pub const Fact = union(enum) {
    auth_url: struct {
        url: []const u8,
        instructions: []const u8,
    },
    device_code: struct {
        user_code: []const u8,
        verification_uri: []const u8,
        interval_seconds: u64,
        expires_in_seconds: u64,
    },
    prompt: struct {
        message: []const u8,
        placeholder: ?[]const u8,
    },
};

const OwnedFact = union(enum) {
    auth_url: struct {
        url: []u8,
        instructions: []u8,
    },
    device_code: struct {
        user_code: []u8,
        verification_uri: []u8,
        interval_seconds: u64,
        expires_in_seconds: u64,
    },
    prompt: struct {
        message: []u8,
        placeholder: ?[]u8,
    },

    fn initEvent(
        allocator: std.mem.Allocator,
        event: ai.oauth.Event,
        max_bytes: usize,
    ) error{ OutOfMemory, FactTooLarge }!OwnedFact {
        return switch (event) {
            .auth_url => |value| result: {
                try admitFactBytes(max_bytes, &.{ value.url, value.instructions });
                const url = try allocator.dupe(u8, value.url);
                errdefer allocator.free(url);
                break :result .{ .auth_url = .{
                    .url = url,
                    .instructions = try allocator.dupe(u8, value.instructions),
                } };
            },
            .device_code => |value| result: {
                try admitFactBytes(max_bytes, &.{ value.user_code, value.verification_uri });
                const user_code = try allocator.dupe(u8, value.user_code);
                errdefer allocator.free(user_code);
                break :result .{ .device_code = .{
                    .user_code = user_code,
                    .verification_uri = try allocator.dupe(u8, value.verification_uri),
                    .interval_seconds = value.interval_seconds,
                    .expires_in_seconds = value.expires_in_seconds,
                } };
            },
        };
    }

    fn initPrompt(
        allocator: std.mem.Allocator,
        request: ai.oauth.Prompt,
        max_bytes: usize,
    ) error{ OutOfMemory, FactTooLarge }!OwnedFact {
        try admitFactBytes(max_bytes, &.{ request.message, request.placeholder orelse "" });
        const message = try allocator.dupe(u8, request.message);
        errdefer allocator.free(message);
        return .{ .prompt = .{
            .message = message,
            .placeholder = if (request.placeholder) |value| try allocator.dupe(u8, value) else null,
        } };
    }

    fn view(self: *const OwnedFact) Fact {
        return switch (self.*) {
            .auth_url => |value| .{ .auth_url = .{
                .url = value.url,
                .instructions = value.instructions,
            } },
            .device_code => |value| .{ .device_code = .{
                .user_code = value.user_code,
                .verification_uri = value.verification_uri,
                .interval_seconds = value.interval_seconds,
                .expires_in_seconds = value.expires_in_seconds,
            } },
            .prompt => |value| .{ .prompt = .{
                .message = value.message,
                .placeholder = value.placeholder,
            } },
        };
    }

    fn retainedBytes(self: *const OwnedFact) usize {
        return switch (self.*) {
            .auth_url => |value| value.url.len + value.instructions.len,
            .device_code => |value| value.user_code.len + value.verification_uri.len,
            .prompt => |value| value.message.len + if (value.placeholder) |text| text.len else 0,
        };
    }

    fn deinit(self: *OwnedFact, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .auth_url => |value| {
                allocator.free(value.instructions);
                allocator.free(value.url);
            },
            .device_code => |value| {
                allocator.free(value.verification_uri);
                allocator.free(value.user_code);
            },
            .prompt => |value| {
                if (value.placeholder) |text| allocator.free(text);
                allocator.free(value.message);
            },
        }
        self.* = undefined;
    }
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    facts: std.ArrayList(OwnedFact),
    outcome: ?Outcome,

    pub fn len(self: *const Batch) usize {
        return self.facts.items.len;
    }

    pub fn fact(self: *const Batch, index: usize) Fact {
        return self.facts.items[index].view();
    }

    pub fn deinit(self: *Batch) void {
        for (self.facts.items) |*fact_value| fact_value.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.* = undefined;
    }
};

const TransportOwner = union(enum) {
    http: ai.transport.HttpTransport,
    borrowed: ai.transport.Transport,

    fn view(self: *TransportOwner) ai.transport.Transport {
        return switch (self.*) {
            .http => |*http| http.transport(),
            .borrowed => |transport| transport,
        };
    }
};

pub const Inputs = struct {
    startup_cwd: []const u8,
    home: []const u8,
    provider_id: []const u8,
    method: ai.oauth.LoginMethod,
    now_ms: u64,
    limits: Limits = .{},
};

allocator: std.mem.Allocator,
io: std.Io,
paths: ZiPaths,
snapshot: ModelConfigSnapshot,
provider_id: []u8,
method: ai.oauth.LoginMethod,
now_ms: u64,
limits: Limits,
transport: TransportOwner,
thread: std.Thread,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
facts: std.ArrayList(OwnedFact) = .empty,
queued_fact_bytes: usize = 0,
pending_answer: ?[]u8 = null,
awaiting_prompt: bool = false,
cancellation: ai.model.CancellationToken = .{},
finished: bool = false,
outcome: Outcome = .cancelled,
outcome_taken: bool = false,

pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
) StartError!*AuthOperation {
    return startOwned(allocator, io, inputs, .{ .http = ai.transport.HttpTransport.init(allocator) });
}

pub fn startWithTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    transport: ai.transport.Transport,
) StartError!*AuthOperation {
    return startOwned(allocator, io, inputs, .{ .borrowed = transport });
}

fn startOwned(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    transport: TransportOwner,
) StartError!*AuthOperation {
    if (inputs.limits.max_facts == 0 or
        inputs.limits.max_fact_bytes == 0 or
        inputs.limits.max_queued_fact_bytes == 0 or
        inputs.limits.max_answer_bytes == 0)
    {
        return error.InvalidLimits;
    }
    const self = try allocator.create(AuthOperation);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .paths = ZiPaths.init(allocator, inputs.startup_cwd, inputs.home) catch |failure| {
            return switch (failure) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidPath => error.InvalidPath,
            };
        },
        .snapshot = undefined,
        .provider_id = undefined,
        .method = inputs.method,
        .now_ms = inputs.now_ms,
        .limits = inputs.limits,
        .transport = transport,
        .thread = undefined,
    };
    errdefer self.paths.deinit();
    self.snapshot = try ModelConfigSnapshot.load(allocator, io, &self.paths);
    errdefer self.snapshot.deinit();
    self.provider_id = try allocator.dupe(u8, inputs.provider_id);
    errdefer allocator.free(self.provider_id);
    try self.facts.ensureTotalCapacity(allocator, inputs.limits.max_facts);
    errdefer self.facts.deinit(allocator);
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    return self;
}

pub fn provider(self: *const AuthOperation) []const u8 {
    return self.provider_id;
}

pub fn loginMethod(self: *const AuthOperation) ai.oauth.LoginMethod {
    return self.method;
}

pub fn isAwaitingAnswer(self: *AuthOperation) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.awaiting_prompt and !self.finished and !self.cancellation.isCancelled();
}

pub fn answer(self: *AuthOperation, source: []const u8) AnswerError!void {
    const value = std.mem.trim(u8, source, " \t\r\n");
    if (value.len == 0) return error.EmptyAnswer;
    if (value.len > self.limits.max_answer_bytes) return error.AnswerTooLarge;
    const owned = try self.allocator.dupe(u8, value);
    var owned_live = true;
    defer if (owned_live) {
        std.crypto.secureZero(u8, owned);
        self.allocator.free(owned);
    };

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.cancellation.isCancelled()) return error.Cancelled;
    if (!self.awaiting_prompt or self.finished or self.pending_answer != null) return error.NotAwaitingAnswer;
    self.pending_answer = owned;
    owned_live = false;
    self.condition.broadcast(self.io);
}

pub fn requestCancel(self: *AuthOperation) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.finished or self.cancellation.isCancelled()) return false;
    self.cancellation.cancel();
    self.condition.broadcast(self.io);
    return true;
}

pub fn hasPending(self: *AuthOperation) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.facts.items.len != 0 or (self.finished and !self.outcome_taken);
}

pub fn takeBatch(self: *AuthOperation) error{OutOfMemory}!Batch {
    var replacement: std.ArrayList(OwnedFact) = .empty;
    errdefer replacement.deinit(self.allocator);
    try replacement.ensureTotalCapacity(self.allocator, self.limits.max_facts);

    self.mutex.lockUncancelable(self.io);
    const facts = self.facts;
    self.facts = replacement;
    self.queued_fact_bytes = 0;
    const outcome = if (self.finished and !self.outcome_taken) value: {
        self.outcome_taken = true;
        break :value self.outcome;
    } else null;
    self.condition.broadcast(self.io);
    self.mutex.unlock(self.io);
    return .{ .allocator = self.allocator, .facts = facts, .outcome = outcome };
}

// Heap destruction follows explicit field invalidation.
// ziglint-ignore: Z030
pub fn deinit(self: *AuthOperation) void {
    _ = self.requestCancel();
    self.thread.join();
    if (self.pending_answer) |answer_value| wipeAndFree(self.allocator, answer_value);
    for (self.facts.items) |*fact_value| fact_value.deinit(self.allocator);
    self.facts.deinit(self.allocator);
    self.allocator.free(self.provider_id);
    self.snapshot.deinit();
    self.paths.deinit();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn threadMain(self: *AuthOperation) void {
    const interaction: ai.oauth.Interaction = .{
        .context = self,
        .vtable = &.{ .notify = notify, .prompt = prompt },
    };
    const result = CredentialManager.login(
        self.allocator,
        self.io,
        &self.paths,
        self.transport.view(),
        self.snapshot.view(),
        .{
            .provider_id = self.provider_id,
            .method = self.method,
            .interaction = interaction,
            .now_ms = self.now_ms,
            .cancellation = &self.cancellation,
        },
    );
    const outcome: Outcome = if (result) |_| .succeeded else |failure| outcome: {
        if (self.cancellation.isCancelled() or failure == error.Cancelled) break :outcome .cancelled;
        break :outcome .{ .failed = mapFailure(failure) };
    };

    self.mutex.lockUncancelable(self.io);
    self.awaiting_prompt = false;
    if (self.pending_answer) |answer_value| {
        wipeAndFree(self.allocator, answer_value);
        self.pending_answer = null;
    }
    self.outcome = outcome;
    self.finished = true;
    self.condition.broadcast(self.io);
    self.mutex.unlock(self.io);
}

fn notify(context: *anyopaque, event: ai.oauth.Event) anyerror!void {
    const self: *AuthOperation = @ptrCast(@alignCast(context));
    var owned = OwnedFact.initEvent(self.allocator, event, self.limits.max_fact_bytes) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.FactTooLarge => error.ConsumerStopped,
        };
    };
    try self.enqueue(&owned, false);
}

// Context leads because this callback implements the erased OAuth interaction ABI.
// ziglint-ignore: Z023
fn prompt(
    context: *anyopaque,
    _: std.mem.Allocator, // ziglint-ignore: Z023
    request: ai.oauth.Prompt,
) anyerror![]u8 {
    const self: *AuthOperation = @ptrCast(@alignCast(context));
    var owned = OwnedFact.initPrompt(self.allocator, request, self.limits.max_fact_bytes) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.FactTooLarge => error.ConsumerStopped,
        };
    };
    try self.enqueue(&owned, true);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (self.pending_answer == null and !self.cancellation.isCancelled()) {
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
    if (self.cancellation.isCancelled()) return error.Cancelled;
    const answer_value = self.pending_answer.?;
    self.pending_answer = null;
    self.awaiting_prompt = false;
    return answer_value;
}

fn enqueue(self: *AuthOperation, owned: *OwnedFact, marks_prompt: bool) anyerror!void {
    var owned_live = true;
    defer if (owned_live) owned.deinit(self.allocator);
    const retained_bytes = owned.retainedBytes();
    if (retained_bytes > self.limits.max_queued_fact_bytes) return error.ConsumerStopped;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while ((self.facts.items.len >= self.limits.max_facts or
        retained_bytes > self.limits.max_queued_fact_bytes -| self.queued_fact_bytes) and
        !self.cancellation.isCancelled())
    {
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
    if (self.cancellation.isCancelled()) return error.Cancelled;
    if (marks_prompt) self.awaiting_prompt = true;
    self.facts.appendAssumeCapacity(owned.*);
    self.queued_fact_bytes += retained_bytes;
    owned_live = false;
    self.condition.broadcast(self.io);
}

fn admitFactBytes(max_bytes: usize, values: []const []const u8) error{FactTooLarge}!void {
    var total: usize = 0;
    for (values) |value| {
        total = std.math.add(usize, total, value.len) catch return error.FactTooLarge;
        if (total > max_bytes) return error.FactTooLarge;
    }
}

fn wipeAndFree(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn mapFailure(failure: CredentialManager.Error) Failure {
    return switch (failure) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidCredentialFile => .invalid_credential_file,
        error.UnsupportedVersion => .unsupported_version,
        error.UnsafePath => .unsafe_path,
        error.ReadFailed => .read_failed,
        error.LockFailed => .lock_failed,
        error.WriteFailed => .write_failed,
        error.CommitIndeterminate => .commit_indeterminate,
        error.Cancelled => unreachable,
        error.TimedOut => .timed_out,
        error.InvalidUrl => .invalid_url,
        error.InvalidRequest => .invalid_request,
        error.ConnectionFailed => .connection_failed,
        error.InvalidResponse => .invalid_response,
        error.ResponseTooLarge => .response_too_large,
        error.ConsumerStopped => .consumer_stopped,
        error.Rejected => .rejected,
        error.InvalidModelConfiguration => .invalid_model_configuration,
        error.AuthenticationUnavailable => .authentication_unavailable,
        error.RefreshUnavailable => .refresh_unavailable,
    };
}

fn testAccessToken(allocator: std.mem.Allocator) ![]u8 {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"account\"}}";
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
}

test "browser OAuth publishes bounded owned prompts and accepts an asynchronous answer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const access = try testAccessToken(std.testing.allocator);
    defer std.testing.allocator.free(access);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(body);
    const exchanges = [_]ai.transport_testing.Exchange{.{ .response = .{ .status = 200, .body = body } }};
    var fake = ai.transport_testing.FakeTransport.init(&exchanges);
    const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root,
        .home = root,
        .provider_id = "openai-codex",
        .method = .browser,
        .now_ms = 1000,
    }, fake.transport());
    defer operation.deinit();

    var saw_url = false;
    var saw_prompt = false;
    var succeeded = false;
    for (0..5_000) |_| {
        if (operation.hasPending()) {
            var batch = try operation.takeBatch();
            defer batch.deinit();
            for (0..batch.len()) |index| switch (batch.fact(index)) {
                .auth_url => |fact_value| {
                    saw_url = fact_value.url.len != 0;
                    try std.testing.expect(std.mem.find(u8, fact_value.url, "answer-secret") == null);
                },
                .prompt => {
                    saw_prompt = true;
                    try operation.answer("answer-secret");
                },
                .device_code => return error.UnexpectedDeviceCode,
            };
            if (batch.outcome) |outcome| {
                try std.testing.expect(outcome == .succeeded);
                succeeded = true;
                break;
            }
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(saw_url);
    try std.testing.expect(saw_prompt);
    try std.testing.expect(succeeded);

    const journal_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, ".zi/agent/auth.json" });
    defer std.testing.allocator.free(journal_path);
    const stored = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        journal_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "answer-secret") == null);
}

test "device OAuth cancellation interrupts a blocked poll without prompting" {
    const BlockingDeviceTransport = struct {
        const Self = @This();

        calls: usize = 0,

        pub fn exchange(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            request: ai.transport.Request,
            _: ai.transport.Delivery,
        ) ai.transport.Error!ai.transport.Response {
            self.calls += 1;
            if (self.calls == 1) {
                return .{
                    .status = 200,
                    .body = try allocator.dupe(
                        u8,
                        "{\"device_auth_id\":\"device\",\"user_code\":\"CODE\",\"interval\":5}",
                    ),
                };
            }
            while (request.cancellation) |cancellation| {
                if (cancellation.isCancelled()) return error.Cancelled;
                io.sleep(.fromMilliseconds(1), .awake) catch return error.Cancelled;
            } else return error.InvalidRequest;
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    var transport: BlockingDeviceTransport = .{};
    const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root_buffer[0..root_length],
        .home = root_buffer[0..root_length],
        .provider_id = "openai-codex",
        .method = .device_code,
        .now_ms = 0,
    }, ai.transport.Transport.from(&transport));
    defer operation.deinit();

    var saw_device = false;
    var cancelled = false;
    for (0..5_000) |_| {
        if (operation.hasPending()) {
            var batch = try operation.takeBatch();
            defer batch.deinit();
            for (0..batch.len()) |index| switch (batch.fact(index)) {
                .device_code => {
                    saw_device = true;
                    try std.testing.expect(operation.requestCancel());
                },
                .auth_url, .prompt => return error.UnexpectedInteraction,
            };
            if (batch.outcome) |outcome| {
                try std.testing.expect(outcome == .cancelled);
                cancelled = true;
                break;
            }
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(saw_device);
    try std.testing.expect(cancelled);
}

test "OAuth fact and answer bounds reject data without retaining it" {
    try std.testing.expectError(error.FactTooLarge, admitFactBytes(3, &.{"four"}));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    var fake = ai.transport_testing.FakeTransport.init(&.{});
    const operation = try startWithTransport(std.testing.allocator, std.testing.io, .{
        .startup_cwd = root_buffer[0..root_length],
        .home = root_buffer[0..root_length],
        .provider_id = "missing-provider",
        .method = .browser,
        .now_ms = 0,
        .limits = .{ .max_answer_bytes = 3 },
    }, fake.transport());
    defer operation.deinit();
    try std.testing.expectError(error.AnswerTooLarge, operation.answer("four"));
}
