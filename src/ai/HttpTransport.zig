const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});
const JsonTransport = @import("JsonTransport.zig");
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const Sse = @import("Sse.zig");
const Transport = @import("Transport.zig");

pub const RuntimeError = error{
    OutOfMemory,
    CurlGlobalInitFailed,
    UnsupportedRuntime,
};

pub const CaSource = enum {
    environment,
    native,
    libcurl_default,
    probed,
    unavailable,
};

pub const CaStatus = struct {
    origin: CaSource,
    proxy: CaSource,
};

/// Safe for user-facing diagnostics. It contains no URL, header, proxy, or path.
pub fn caFailureHint(err: Transport.StreamError) ?[]const u8 {
    if (err != error.TlsVerificationFailed) return null;
    return "TLS certificate verification failed; configure CURL_CA_BUNDLE, " ++
        "SSL_CERT_FILE, or the system CA store";
}

var curl_global_mutex: std.atomic.Mutex = .unlocked;
var curl_global_references: usize = 0;

fn lockCurlGlobal() void {
    while (!curl_global_mutex.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
}

fn acquireCurlGlobal() error{CurlGlobalInitFailed}!void {
    lockCurlGlobal();
    defer curl_global_mutex.unlock();
    if (curl_global_references == 0 and c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) {
        return error.CurlGlobalInitFailed;
    }
    curl_global_references += 1;
}

fn releaseCurlGlobal() void {
    lockCurlGlobal();
    defer curl_global_mutex.unlock();
    std.debug.assert(curl_global_references > 0);
    curl_global_references -= 1;
    if (curl_global_references == 0) c.curl_global_cleanup();
}

fn validateRuntimeFeatures(features: c_int) error{UnsupportedRuntime}!void {
    if (comptime !@hasDecl(c, "CURL_VERSION_THREADSAFE")) return error.UnsupportedRuntime;
    const required = c.CURL_VERSION_ASYNCHDNS | c.CURL_VERSION_THREADSAFE;
    if ((features & required) != required) return error.UnsupportedRuntime;
}

fn curlGlobalReferenceCount() usize {
    lockCurlGlobal();
    defer curl_global_mutex.unlock();
    return curl_global_references;
}

/// Heap-stable, explicit owner of libcurl process state. The caller must ensure
/// all transports and worker threads using it are finished before `deinit`. Each
/// owner holds one process-global libcurl reference until then.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    active_mutex: std.Io.Mutex = .init,
    active_multi: std.ArrayList(*c.CURLM) = .empty,
    origin_ca_source: CaSource = .unavailable,
    proxy_ca_source: CaSource = .unavailable,
    ca_info: ?[:0]u8 = null,
    ca_path: ?[:0]u8 = null,
    proxy_ca_info: ?[:0]u8 = null,
    proxy_ca_path: ?[:0]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: std.process.Environ,
    ) RuntimeError!*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        try acquireCurlGlobal();
        errdefer releaseCurlGlobal();
        const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.UnsupportedRuntime;
        try validateRuntimeFeatures(info.*.features);
        self.* = .{ .allocator = allocator, .io = io };
        errdefer self.freeCa();
        try self.resolveCa(io, environment, info);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;
        defer allocator.destroy(self);
        std.debug.assert(self.active_multi.items.len == 0);
        self.active_multi.deinit(allocator);
        self.freeCa();
        releaseCurlGlobal();
        self.* = undefined;
    }

    pub fn transport(self: *Runtime) HttpTransport {
        return .{ .runtime = self };
    }

    pub fn caStatus(self: *const Runtime) CaStatus {
        return .{ .origin = self.origin_ca_source, .proxy = self.proxy_ca_source };
    }

    /// Wakes every active multi poll. A cancelling thread should set its
    /// cancellation state first, then call this method so the next tick sees it.
    pub fn wakeup(self: *Runtime) error{ OutOfMemory, ConnectionFailed }!void {
        self.active_mutex.lockUncancelable(self.io);
        defer self.active_mutex.unlock(self.io);
        for (self.active_multi.items) |multi| {
            const code = c.curl_multi_wakeup(multi);
            if (code != c.CURLM_OK) return mapMultiError(code);
        }
    }

    fn register(self: *Runtime, multi: *c.CURLM) error{OutOfMemory}!void {
        self.active_mutex.lockUncancelable(self.io);
        defer self.active_mutex.unlock(self.io);
        try self.active_multi.append(self.allocator, multi);
    }

    fn unregister(self: *Runtime, multi: *c.CURLM) void {
        self.active_mutex.lockUncancelable(self.io);
        defer self.active_mutex.unlock(self.io);
        for (self.active_multi.items, 0..) |active, index| {
            if (active == multi) {
                _ = self.active_multi.swapRemove(index);
                return;
            }
        }
        unreachable;
    }

    fn freeCa(self: *Runtime) void {
        if (self.ca_info) |value| self.allocator.free(value);
        if (self.ca_path) |value| self.allocator.free(value);
        if (self.proxy_ca_info) |value| self.allocator.free(value);
        if (self.proxy_ca_path) |value| self.allocator.free(value);
        self.ca_info = null;
        self.ca_path = null;
        self.proxy_ca_info = null;
        self.proxy_ca_path = null;
    }

    fn copyProbedProxy(self: *Runtime) error{OutOfMemory}!void {
        if (self.ca_info) |value| self.proxy_ca_info = try self.allocator.dupeZ(u8, value);
        if (self.ca_path) |value| self.proxy_ca_path = try self.allocator.dupeZ(u8, value);
        self.proxy_ca_source = .probed;
    }

    fn resolveCa(
        self: *Runtime,
        io: std.Io,
        environment: std.process.Environ,
        info: *c.curl_version_info_data,
    ) error{OutOfMemory}!void {
        const bundle = nonEmptyEnv(environment, "CURL_CA_BUNDLE");
        const file = nonEmptyEnv(environment, "SSL_CERT_FILE");
        const directory = nonEmptyEnv(environment, "SSL_CERT_DIR");
        const overridden = bundle != null or file != null or directory != null;
        const backend = activeTlsBackend(info);
        const curl_has_defaults = curlDefaultsUsable(io, info, backend);

        if (bundle) |value| {
            self.ca_info = try self.allocator.dupeZ(u8, value);
            self.origin_ca_source = .environment;
        } else if (file != null or directory != null) {
            if (file) |value| self.ca_info = try self.allocator.dupeZ(u8, value);
            if (directory) |value| self.ca_path = try self.allocator.dupeZ(u8, value);
            self.origin_ca_source = .environment;
        } else if (backend == .native) {
            self.origin_ca_source = .native;
        } else if (curl_has_defaults) {
            self.origin_ca_source = .libcurl_default;
        } else {
            self.ca_info = try probeBundle(self.allocator, io);
            self.ca_path = try probeDirectory(self.allocator, io, backend);
            self.origin_ca_source = if (self.ca_info != null or self.ca_path != null)
                .probed
            else
                .unavailable;
        }

        // Origin environment overrides must not replace HTTPS proxy trust.
        if (!overridden) {
            self.proxy_ca_source = self.origin_ca_source;
            if (self.origin_ca_source == .probed) try self.copyProbedProxy();
        } else if (backend == .native) {
            self.proxy_ca_source = .native;
        } else if (curl_has_defaults) {
            self.proxy_ca_source = .libcurl_default;
        } else {
            self.proxy_ca_info = try probeBundle(self.allocator, io);
            self.proxy_ca_path = try probeDirectory(self.allocator, io, backend);
            self.proxy_ca_source = if (self.proxy_ca_info != null or self.proxy_ca_path != null)
                .probed
            else
                .unavailable;
        }
    }
};

pub const HttpTransport = struct {
    runtime: *Runtime,

    pub fn streaming(self: *HttpTransport) Transport.Transport {
        return Transport.Transport.from(self);
    }

    pub fn json(self: *HttpTransport) JsonTransport.Transport {
        return JsonTransport.Transport.from(self);
    }

    pub fn ssePost(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *HttpTransport,
        stream_request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        var adapter: SseAdapter = .{ .sink = sink };
        var parser = Sse.Parser.init(allocator, .{
            .max_line_bytes = stream_request.limits.header_buffer_bytes,
            .max_event_bytes = stream_request.limits.max_sse_event_bytes,
            .max_data_bytes = stream_request.limits.max_sse_event_bytes,
        }, Sse.EventSink.from(&adapter));
        defer parser.deinit();

        var state: TransferState = .{
            .allocator = allocator,
            .io = io,
            .tick = stream_request.tick,
            .mode = .sse,
            .max_body_bytes = @min(stream_request.limits.max_error_body_bytes, 4_096),
            .max_header_bytes = stream_request.limits.max_header_bytes,
            .idle_timeout_ms = stream_request.limits.idle_timeout_ms,
            .total_timeout_ms = 0,
            .parser = &parser,
        };
        defer state.body.deinit(allocator);
        try perform(
            self.runtime,
            &state,
            stream_request.url,
            stream_request.headers,
            .post,
            stream_request.json_body,
            stream_request.limits.connect_timeout_ms,
            stream_request.limits.header_buffer_bytes,
        );
        try state.finishCallbacks();
        if (state.status >= 200 and state.status < 300) {
            parser.finalize() catch |err| return mapParserError(err);
            try state.poll();
            return .{ .status = state.status, .outcome = .completed };
        }
        if (state.body.items.len == 0) {
            const no_body = "(no response body)";
            try state.body.appendSlice(allocator, no_body[0..@min(no_body.len, state.max_body_bytes)]);
        }
        return .{
            .status = state.status,
            .retry_after_ms = state.retryAfterMs(),
            .outcome = .failed,
            .error_body = try state.takeBody(),
        };
    }

    pub fn request(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *HttpTransport,
        request_value: JsonTransport.Request,
    ) JsonTransport.Error!JsonTransport.Response {
        var state: TransferState = .{
            .allocator = allocator,
            .io = io,
            .tick = request_value.tick,
            .mode = .json,
            .max_body_bytes = request_value.limits.max_response_body_bytes,
            .max_header_bytes = request_value.limits.max_header_bytes,
            .idle_timeout_ms = request_value.limits.idle_timeout_ms,
            .total_timeout_ms = request_value.limits.total_timeout_ms,
        };
        defer state.body.deinit(allocator);
        try perform(
            self.runtime,
            &state,
            request_value.url,
            request_value.headers,
            request_value.method,
            request_value.json_body,
            request_value.limits.connect_timeout_ms,
            request_value.limits.header_buffer_bytes,
        );
        try state.finishCallbacks();
        return .{
            .status = state.status,
            .body = try state.takeBody(),
            .retry_after_ms = state.retryAfterMs(),
        };
    }
};

const Mode = enum { sse, json };
const Failure = enum { none, cancelled, out_of_memory, invalid_response, idle_timed_out };

const TransferState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tick: ?Provider.Tick,
    mode: Mode,
    max_body_bytes: usize,
    max_header_bytes: usize,
    idle_timeout_ms: u64,
    total_timeout_ms: u64,
    parser: ?*Sse.Parser = null,
    body: std.ArrayList(u8) = .empty,
    header_bytes: usize = 0,
    status: u16 = 0,
    failure: Failure = .none,
    start_ns: i96 = 0,
    last_progress_ns: i96 = 0,
    retry_after: [Retry.retry_after_max_bytes]u8 = undefined,
    retry_after_len: usize = 0,
    content_type: [128]u8 = undefined,
    content_type_len: usize = 0,

    fn poll(self: *TransferState) error{Cancelled}!void {
        if (self.tick) |tick| try tick.poll();
    }

    fn markProgress(self: *TransferState) void {
        self.last_progress_ns = nowNs(self.io);
    }

    fn checkTimeout(self: *TransferState) ?Transport.StreamError {
        const now = nowNs(self.io);
        if (self.total_timeout_ms != 0 and elapsedMs(self.start_ns, now) >= self.total_timeout_ms) {
            return error.IdleTimedOut;
        }
        if (self.idle_timeout_ms != 0 and elapsedMs(self.last_progress_ns, now) >= self.idle_timeout_ms) {
            return error.IdleTimedOut;
        }
        return null;
    }

    fn callbackCheck(self: *TransferState) bool {
        if (self.failure != .none) return false;
        self.poll() catch {
            self.failure = .cancelled;
            return false;
        };
        if (self.checkTimeout()) |_| {
            self.failure = .idle_timed_out;
            return false;
        }
        return true;
    }

    fn finishCallbacks(self: *TransferState) Transport.StreamError!void {
        try self.poll();
        return switch (self.failure) {
            .none => {},
            .cancelled => error.Cancelled,
            .out_of_memory => error.OutOfMemory,
            .invalid_response => error.InvalidResponse,
            .idle_timed_out => error.IdleTimedOut,
        };
    }

    fn isEventStream(self: *const TransferState) bool {
        const value = std.mem.trim(u8, self.content_type[0..self.content_type_len], " \t\r\n");
        const separator = std.mem.findScalar(u8, value, ';') orelse value.len;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..separator], " \t"), "text/event-stream");
    }

    fn retryAfterMs(self: *const TransferState) ?u64 {
        if (self.retry_after_len == 0) return null;
        const real_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        const seconds: i64 = @intCast(@divFloor(real_ns, std.time.ns_per_s));
        return Retry.parseRetryAfter(self.retry_after[0..self.retry_after_len], seconds);
    }

    fn takeBody(self: *TransferState) error{OutOfMemory}![]u8 {
        const result = try self.body.toOwnedSlice(self.allocator);
        return result;
    }
};

const SseAdapter = struct {
    sink: Transport.EventSink,

    pub fn emit(self: *SseAdapter, event_name: []const u8, data: []const u8) error{Cancelled}!void {
        try self.sink.emit(.{ .event_name = if (event_name.len == 0) null else event_name, .data = data });
    }
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsedMs(start: i96, finish: i96) u64 {
    if (finish <= start) return 0;
    const elapsed_ns = std.math.sub(i96, finish, start) catch std.math.maxInt(i96);
    const value = @divFloor(elapsed_ns, std.time.ns_per_ms);
    return @intCast(@min(value, std.math.maxInt(u64)));
}

fn writeCallback(data: ?*anyopaque, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const state: *TransferState = @ptrCast(@alignCast(userdata orelse return 0));
    if (!state.callbackCheck()) return 0;
    const length = std.math.mul(usize, size, count) catch {
        state.failure = .invalid_response;
        return 0;
    };
    const bytes: [*]const u8 = @ptrCast(data orelse return 0);
    const chunk = bytes[0..length];
    state.markProgress();

    if (state.mode == .sse and state.status >= 200 and state.status < 300) {
        state.parser.?.feed(chunk) catch |err| {
            state.failure = switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.Cancelled => .cancelled,
                error.LineTooLong, error.EventTooLong, error.DataTooLong => .invalid_response,
            };
            return 0;
        };
    } else {
        const available = state.max_body_bytes -| state.body.items.len;
        if (chunk.len > available and state.mode == .json) {
            state.failure = .invalid_response;
            return 0;
        }
        state.body.appendSlice(state.allocator, chunk[0..@min(chunk.len, available)]) catch {
            state.failure = .out_of_memory;
            return 0;
        };
    }
    if (!state.callbackCheck()) return 0;
    return length;
}

fn headerCallback(data: ?*anyopaque, size: usize, count: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const state: *TransferState = @ptrCast(@alignCast(userdata orelse return 0));
    if (!state.callbackCheck()) return 0;
    const length = std.math.mul(usize, size, count) catch {
        state.failure = .invalid_response;
        return 0;
    };
    if (length > state.max_header_bytes -| state.header_bytes) {
        state.failure = .invalid_response;
        return 0;
    }
    const bytes: [*]const u8 = @ptrCast(data orelse return 0);
    const line = bytes[0..length];
    state.header_bytes += length;
    state.markProgress();
    parseHeader(state, line);
    if (!state.callbackCheck()) return 0;
    return length;
}

fn parseHeader(state: *TransferState, raw_line: []const u8) void {
    const line = std.mem.trim(u8, raw_line, "\r\n");
    if (std.mem.startsWith(u8, line, "HTTP/")) {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        _ = parts.next();
        const status_bytes = parts.next() orelse {
            state.failure = .invalid_response;
            return;
        };
        const parsed = std.fmt.parseInt(u16, status_bytes, 10) catch {
            state.failure = .invalid_response;
            return;
        };
        if (parsed < 100 or parsed > 599) {
            state.failure = .invalid_response;
        } else {
            state.status = parsed;
            state.retry_after_len = 0;
            state.content_type_len = 0;
        }
        return;
    }
    const colon = std.mem.findScalar(u8, line, ':') orelse return;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
        if (value.len <= state.retry_after.len) {
            @memcpy(state.retry_after[0..value.len], value);
            state.retry_after_len = value.len;
        }
    } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        if (value.len <= state.content_type.len) {
            @memcpy(state.content_type[0..value.len], value);
            state.content_type_len = value.len;
        }
    }
}

fn perform(
    runtime: *Runtime,
    state: *TransferState,
    url: []const u8,
    headers: []const Transport.Header,
    method: anytype,
    body: ?[]const u8,
    connect_timeout_ms: u64,
    buffer_bytes: usize,
) Transport.StreamError!void {
    try state.poll();
    if (url.len > JsonTransport.maximum_url_bytes) return error.InvalidRequest;
    state.start_ns = nowNs(state.io);
    state.last_progress_ns = state.start_ns;

    const easy = c.curl_easy_init() orelse return error.OutOfMemory;
    defer c.curl_easy_cleanup(easy);
    const multi = c.curl_multi_init() orelse return error.OutOfMemory;
    defer _ = c.curl_multi_cleanup(multi);
    runtime.register(multi) catch return error.OutOfMemory;
    defer runtime.unregister(multi);

    const url_z = state.allocator.dupeZ(u8, url) catch return error.OutOfMemory;
    defer {
        @memset(url_z, 0);
        state.allocator.free(url_z);
    }
    var header_list: ?*c.struct_curl_slist = null;
    defer wipeAndFreeHeaders(header_list);
    for (headers) |header| {
        const line = std.fmt.allocPrintSentinel(state.allocator, "{s}: {s}", .{ header.name, header.value }, 0) catch
            return error.OutOfMemory;
        defer {
            @memset(line, 0);
            state.allocator.free(line);
        }
        const appended = c.curl_slist_append(header_list, line.ptr) orelse return error.OutOfMemory;
        header_list = appended;
    }

    try setopt(easy, c.CURLOPT_URL, url_z.ptr);
    try setopt(easy, c.CURLOPT_HTTPHEADER, header_list);
    try setopt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
    try setopt(easy, c.CURLOPT_WRITEDATA, state);
    try setopt(easy, c.CURLOPT_HEADERFUNCTION, headerCallback);
    try setopt(easy, c.CURLOPT_HEADERDATA, state);
    try setopt(easy, c.CURLOPT_PRIVATE, state);
    try setopt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    if (state.mode == .sse) try setopt(easy, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
    try setopt(easy, c.CURLOPT_USERAGENT, "zi/0.1.0-dev");
    try setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    try setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    if (runtime.ca_info) |value| try setopt(easy, c.CURLOPT_CAINFO, value.ptr);
    if (runtime.ca_path) |value| try setoptCaPath(easy, c.CURLOPT_CAPATH, value.ptr);
    if (runtime.proxy_ca_info) |value| try setopt(easy, c.CURLOPT_PROXY_CAINFO, value.ptr);
    if (runtime.proxy_ca_path) |value| try setoptCaPath(easy, c.CURLOPT_PROXY_CAPATH, value.ptr);
    try setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, toLong(connect_timeout_ms));
    if (comptime @hasDecl(c, "CURLOPT_PROTOCOLS_STR")) {
        try setopt(easy, c.CURLOPT_PROTOCOLS_STR, "http,https");
        try setopt(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    } else {
        const protocols: c_long = c.CURLPROTO_HTTP | c.CURLPROTO_HTTPS;
        try setopt(easy, c.CURLOPT_PROTOCOLS, protocols);
        try setopt(easy, c.CURLOPT_REDIR_PROTOCOLS, protocols);
    }
    try setopt(easy, c.CURLOPT_BUFFERSIZE, toLong(@min(buffer_bytes, @as(usize, 512 * 1024))));

    const is_post = switch (@TypeOf(method)) {
        JsonTransport.Method => method == .post,
        else => true,
    };
    if (is_post) {
        try setopt(easy, c.CURLOPT_POST, @as(c_long, 1));
    } else {
        try setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
    }
    if (body) |payload| {
        try setopt(easy, c.CURLOPT_POSTFIELDS, payload.ptr);
        try setopt(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(payload.len)));
        if (!is_post) try setopt(easy, c.CURLOPT_CUSTOMREQUEST, "GET");
    }
    if (state.total_timeout_ms != 0) {
        try setopt(easy, c.CURLOPT_TIMEOUT_MS, toLong(state.total_timeout_ms));
    }

    const add_code = c.curl_multi_add_handle(multi, easy);
    if (add_code != c.CURLM_OK) return mapMultiError(add_code);
    defer _ = c.curl_multi_remove_handle(multi, easy);

    var running: c_int = 0;
    const initial_perform_code = c.curl_multi_perform(multi, &running);
    if (initial_perform_code != c.CURLM_OK) {
        try state.finishCallbacks();
        return mapMultiError(initial_perform_code);
    }
    while (running != 0) {
        try state.poll();
        if (state.checkTimeout()) |err| return err;
        var descriptors: c_int = 0;
        const wait_ms = pollWaitMs(state);
        const poll_code = c.curl_multi_poll(multi, null, 0, wait_ms, &descriptors);
        if (poll_code != c.CURLM_OK) return mapMultiError(poll_code);
        try state.poll();
        if (state.checkTimeout()) |err| return err;
        const perform_code = c.curl_multi_perform(multi, &running);
        if (perform_code != c.CURLM_OK) {
            try state.finishCallbacks();
            return mapMultiError(perform_code);
        }
        try state.finishCallbacks();
    }

    var messages: c_int = 0;
    var saw_done = false;
    while (c.curl_multi_info_read(multi, &messages)) |message| {
        if (message.*.msg != c.CURLMSG_DONE) continue;
        saw_done = true;
        try state.finishCallbacks();
        const result = message.*.data.result;
        if (result == c.CURLE_OPERATION_TIMEDOUT) {
            if (state.checkTimeout()) |err| return err;
            return error.ConnectTimedOut;
        }
        if (result != c.CURLE_OK) return mapCurlError(result);
    }
    if (!saw_done) return error.ConnectionFailed;
    var response_code: c_long = 0;
    const info_code = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &response_code);
    if (info_code != c.CURLE_OK) return mapCurlError(info_code);
    if (response_code < 100 or response_code > 599) return error.InvalidResponse;
    state.status = @intCast(response_code);
    try state.poll();
}

fn pollWaitMs(state: *const TransferState) c_int {
    var wait_ms: u64 = 100;
    const now = nowNs(state.io);
    if (state.idle_timeout_ms != 0) {
        const elapsed = elapsedMs(state.last_progress_ns, now);
        wait_ms = @min(wait_ms, state.idle_timeout_ms -| elapsed);
    }
    if (state.total_timeout_ms != 0) {
        const elapsed = elapsedMs(state.start_ns, now);
        wait_ms = @min(wait_ms, state.total_timeout_ms -| elapsed);
    }
    return @intCast(wait_ms);
}

fn setopt(easy: *c.CURL, option: c.CURLoption, value: anytype) Transport.StreamError!void {
    const code = c.curl_easy_setopt(easy, option, value);
    if (code == c.CURLE_OUT_OF_MEMORY) return error.OutOfMemory;
    if (code != c.CURLE_OK) return error.InvalidRequest;
}

fn setoptCaPath(easy: *c.CURL, option: c.CURLoption, value: [*:0]const u8) Transport.StreamError!void {
    const code = c.curl_easy_setopt(easy, option, value);
    if (code == c.CURLE_OK or ignorableCaPathError(code)) return;
    return mapCurlError(code);
}

fn ignorableCaPathError(code: c.CURLcode) bool {
    return code == c.CURLE_NOT_BUILT_IN or code == c.CURLE_UNKNOWN_OPTION;
}

fn toLong(value: anytype) c_long {
    const wide: u128 = @intCast(value);
    return @intCast(@min(wide, @as(u128, std.math.maxInt(c_long))));
}

fn wipeAndFreeHeaders(list: ?*c.struct_curl_slist) void {
    var node = list;
    while (node) |current| : (node = current.*.next) {
        if (current.*.data) |data| {
            const bytes = std.mem.span(data);
            @memset(bytes, 0);
        }
    }
    c.curl_slist_free_all(list);
}

fn mapParserError(err: Sse.ParseError) Transport.StreamError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.LineTooLong, error.EventTooLong, error.DataTooLong => error.InvalidResponse,
    };
}

fn mapMultiError(code: c.CURLMcode) Transport.StreamError {
    return if (code == c.CURLM_OUT_OF_MEMORY) error.OutOfMemory else error.ConnectionFailed;
}

fn mapCurlError(code: c.CURLcode) Transport.StreamError {
    return switch (code) {
        c.CURLE_OPERATION_TIMEDOUT => error.ConnectTimedOut,
        c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLE_PEER_FAILED_VERIFICATION,
        c.CURLE_SSL_CACERT_BADFILE,
        c.CURLE_SSL_ISSUER_ERROR,
        => error.TlsVerificationFailed,
        c.CURLE_URL_MALFORMAT, c.CURLE_UNSUPPORTED_PROTOCOL => error.InvalidRequest,
        c.CURLE_GOT_NOTHING, c.CURLE_WEIRD_SERVER_REPLY, c.CURLE_BAD_CONTENT_ENCODING => error.InvalidResponse,
        else => error.ConnectionFailed,
    };
}

fn nonEmptyEnv(environment: std.process.Environ, name: []const u8) ?[:0]const u8 {
    const value = environment.getPosix(name) orelse return null;
    return if (value.len == 0) null else value;
}

const TlsBackend = enum {
    native,
    openssl,
    directory_any,
    unsupported,
};

fn activeTlsBackend(info: *const c.curl_version_info_data) TlsBackend {
    if (hasNativeFeature(info)) return .native;
    const pointer = info.*.ssl_version orelse return .unsupported;
    return classifyTlsBackend(std.mem.span(pointer));
}

fn hasNativeFeature(info: *const c.curl_version_info_data) bool {
    if (comptime !@hasField(c.curl_version_info_data, "feature_names")) return false;
    if (comptime !@hasDecl(c, "CURLVERSION_ELEVENTH")) return false;
    if (info.*.age < c.CURLVERSION_ELEVENTH) return false;
    const names = info.*.feature_names orelse return false;
    var index: usize = 0;
    while (names[index]) |name| : (index += 1) {
        const value = std.mem.span(name);
        if (std.ascii.eqlIgnoreCase(value, "AppleSecTrust") or
            std.ascii.eqlIgnoreCase(value, "NativeCA")) return true;
    }
    return false;
}

fn classifyTlsBackend(value: []const u8) TlsBackend {
    inline for (.{ "SecureTransport", "Schannel", "AppleSecTrust", "NativeCA" }) |marker| {
        if (activeMarker(value, marker)) return .native;
    }
    inline for (.{ "OpenSSL", "LibreSSL", "BoringSSL", "quictls", "AWS-LC" }) |marker| {
        if (activeMarker(value, marker)) return .openssl;
    }
    inline for (.{ "GnuTLS", "mbedTLS", "wolfSSL" }) |marker| {
        if (activeMarker(value, marker)) return .directory_any;
    }
    return .unsupported;
}

/// MultiSSL lists inactive backends in parentheses. Only an occurrence at
/// parenthesis depth zero describes the active backend.
fn activeMarker(value: []const u8, marker: []const u8) bool {
    if (marker.len == 0 or value.len < marker.len) return false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] == '(') {
            depth += 1;
            continue;
        }
        if (value[index] == ')') {
            depth -|= 1;
            continue;
        }
        if (depth == 0 and index + marker.len <= value.len and
            std.ascii.eqlIgnoreCase(value[index .. index + marker.len], marker))
        {
            return true;
        }
    }
    return false;
}

fn compiledCaInfo(info: *const c.curl_version_info_data) ?[*:0]const u8 {
    if (comptime !@hasField(c.curl_version_info_data, "cainfo") or
        !@hasDecl(c, "CURLVERSION_SEVENTH")) return null;
    if (info.*.age < c.CURLVERSION_SEVENTH) return null;
    return info.*.cainfo;
}

fn compiledCaPath(info: *const c.curl_version_info_data) ?[*:0]const u8 {
    if (comptime !@hasField(c.curl_version_info_data, "capath") or
        !@hasDecl(c, "CURLVERSION_SEVENTH")) return null;
    if (info.*.age < c.CURLVERSION_SEVENTH) return null;
    return info.*.capath;
}

fn curlDefaultsUsable(
    io: std.Io,
    info: *const c.curl_version_info_data,
    backend: TlsBackend,
) bool {
    if (compiledCaInfo(info)) |pointer| {
        var file = std.Io.Dir.openFile(.cwd(), io, std.mem.span(pointer), .{}) catch null;
        if (file) |*value| {
            defer value.close(io);
            const stat = value.stat(io) catch null;
            if (stat != null and stat.?.kind == .file) return true;
        }
    }
    if (compiledCaPath(info)) |pointer| {
        if (directoryContainsCa(io, std.mem.span(pointer), backend)) return true;
    }
    return false;
}

fn probeBundle(allocator: std.mem.Allocator, io: std.Io) error{OutOfMemory}!?[:0]u8 {
    const paths = [_][]const u8{
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        "/usr/local/share/certs/ca-root-nss.crt",
        "/etc/ssl/cert.pem",
    };
    for (paths) |path| {
        std.Io.Dir.access(.cwd(), io, path, .{}) catch continue;
        const result = try allocator.dupeZ(u8, path);
        return result;
    }
    return null;
}

fn probeDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: TlsBackend,
) error{OutOfMemory}!?[:0]u8 {
    if (backend != .openssl and backend != .directory_any) return null;
    const paths = [_][]const u8{ "/etc/ssl/certs", "/etc/pki/tls/certs" };
    for (paths) |path| {
        if (!directoryContainsCa(io, path, backend)) continue;
        const result = try allocator.dupeZ(u8, path);
        return result;
    }
    return null;
}

fn directoryContainsCa(io: std.Io, path: []const u8, backend: TlsBackend) bool {
    var directory = std.Io.Dir.openDir(.cwd(), io, path, .{ .iterate = true }) catch return false;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch return false) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (backend) {
            .openssl => if (isOpenSslCaEntry(entry.name)) return true,
            .directory_any => return true,
            .native, .unsupported => return false,
        }
    }
    return false;
}

fn isOpenSslCaEntry(name: []const u8) bool {
    if (name.len != 10 or name[8] != '.' or name[9] != '0') return false;
    for (name[0..8]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "duration conversions saturate across native integer domains" {
    const long_max: u64 = @intCast(std.math.maxInt(c_long));
    try std.testing.expectEqual(std.math.maxInt(c_long), toLong(long_max));
    try std.testing.expectEqual(std.math.maxInt(c_long), toLong(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 0), elapsedMs(1, 0));
    try std.testing.expectEqual(std.math.maxInt(u64), elapsedMs(std.math.minInt(i96), std.math.maxInt(i96)));
}

test "process curl coordinator reference-counts multiple Runtime owners" {
    const baseline = curlGlobalReferenceCount();
    const first = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    try std.testing.expectEqual(baseline + 1, curlGlobalReferenceCount());
    const second = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    try std.testing.expectEqual(baseline + 2, curlGlobalReferenceCount());
    first.deinit();
    try std.testing.expectEqual(baseline + 1, curlGlobalReferenceCount());
    second.deinit();
    try std.testing.expectEqual(baseline, curlGlobalReferenceCount());
}

test "process curl coordinator permits concurrent owners" {
    const Worker = struct {
        fn run(ready: *std.atomic.Value(usize)) void {
            acquireCurlGlobal() catch unreachable;
            _ = ready.fetchAdd(1, .seq_cst);
            while (ready.load(.seq_cst) != 2) std.Thread.yield() catch std.atomic.spinLoopHint();
            releaseCurlGlobal();
        }
    };
    const baseline = curlGlobalReferenceCount();
    var ready: std.atomic.Value(usize) = .init(0);
    const first = try std.Thread.spawn(.{}, Worker.run, .{&ready});
    const second = try std.Thread.spawn(.{}, Worker.run, .{&ready});
    first.join();
    second.join();
    try std.testing.expectEqual(baseline, curlGlobalReferenceCount());
}

test "failed runtime feature validation rolls back a global reference" {
    const baseline = curlGlobalReferenceCount();
    try acquireCurlGlobal();
    validateRuntimeFeatures(0) catch |err| {
        releaseCurlGlobal();
        try std.testing.expectEqual(error.UnsupportedRuntime, err);
        try std.testing.expectEqual(baseline, curlGlobalReferenceCount());
        return;
    };
    return error.TestUnexpectedResult;
}

test "curl and multi out-of-memory codes retain OutOfMemory" {
    try std.testing.expectEqual(error.OutOfMemory, mapCurlError(c.CURLE_OUT_OF_MEMORY));
    try std.testing.expectEqual(error.OutOfMemory, mapMultiError(c.CURLM_OUT_OF_MEMORY));
    try std.testing.expectEqual(error.ConnectionFailed, mapMultiError(c.CURLM_INTERNAL_ERROR));
}

test "compiled CA fields are ignored before seventh version-info age" {
    if (comptime @hasField(c.curl_version_info_data, "cainfo") and
        @hasField(c.curl_version_info_data, "capath") and
        @hasDecl(c, "CURLVERSION_SEVENTH"))
    {
        var info: c.curl_version_info_data = std.mem.zeroes(c.curl_version_info_data);
        const ca_info: [:0]const u8 = "/compiled-ca.pem";
        const ca_path: [:0]const u8 = "/compiled-ca-dir";
        info.cainfo = ca_info.ptr;
        info.capath = ca_path.ptr;
        info.age = c.CURLVERSION_SIXTH;
        try std.testing.expect(compiledCaInfo(&info) == null);
        try std.testing.expect(compiledCaPath(&info) == null);
        info.age = c.CURLVERSION_SEVENTH;
        try std.testing.expectEqualStrings(ca_info, std.mem.span(compiledCaInfo(&info).?));
        try std.testing.expectEqualStrings(ca_path, std.mem.span(compiledCaPath(&info).?));
    }
}

test "missing compiled CA defaults are rejected and backend directory rules apply" {
    var info: c.curl_version_info_data = std.mem.zeroes(c.curl_version_info_data);
    info.age = c.CURLVERSION_SEVENTH;
    const missing: [:0]const u8 = "/tmp/zi-ca-definitely-missing";
    info.cainfo = missing.ptr;
    try std.testing.expect(!curlDefaultsUsable(std.testing.io, &info, .openssl));

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/zi-ca-{x}", .{@intFromPtr(&info)});
    try std.Io.Dir.createDir(.cwd(), std.testing.io, path, .default_dir);
    defer std.Io.Dir.deleteTree(.cwd(), std.testing.io, path) catch unreachable;
    var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, path, .{});
    defer directory.close(std.testing.io);
    const file = try directory.createFile(std.testing.io, "not-hashed.pem", .{});
    file.close(std.testing.io);
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    info.cainfo = null;
    info.capath = path_z.ptr;
    try std.testing.expect(!curlDefaultsUsable(std.testing.io, &info, .openssl));
    try std.testing.expect(curlDefaultsUsable(std.testing.io, &info, .directory_any));
}

test "probed origin CA is copied independently to proxy CA" {
    var runtime: Runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer runtime.freeCa();
    runtime.origin_ca_source = .probed;
    runtime.ca_info = try std.testing.allocator.dupeZ(u8, "/bundle");
    runtime.ca_path = try std.testing.allocator.dupeZ(u8, "/directory");
    try runtime.copyProbedProxy();
    try std.testing.expectEqual(CaSource.probed, runtime.proxy_ca_source);
    try std.testing.expectEqualStrings(runtime.ca_info.?, runtime.proxy_ca_info.?);
    try std.testing.expectEqualStrings(runtime.ca_path.?, runtime.proxy_ca_path.?);
    try std.testing.expect(runtime.ca_info.?.ptr != runtime.proxy_ca_info.?.ptr);
}

test "native feature names are ignored for pre-eleventh version-info age" {
    if (comptime @hasField(c.curl_version_info_data, "feature_names") and
        @hasDecl(c, "CURLVERSION_ELEVENTH"))
    {
        var info: c.curl_version_info_data = std.mem.zeroes(c.curl_version_info_data);
        const native: [:0]const u8 = "NativeCA";
        const names = [_:null]?[*:0]const u8{native.ptr};
        info.feature_names = @ptrCast(&names);
        info.age = c.CURLVERSION_TENTH;
        try std.testing.expect(!hasNativeFeature(&info));
        info.age = c.CURLVERSION_ELEVENTH;
        try std.testing.expect(hasNativeFeature(&info));
    }
}

test "unsupported CAPATH setopt errors are ignorable but OOM is not" {
    try std.testing.expect(ignorableCaPathError(c.CURLE_NOT_BUILT_IN));
    try std.testing.expect(ignorableCaPathError(c.CURLE_UNKNOWN_OPTION));
    try std.testing.expect(!ignorableCaPathError(c.CURLE_OUT_OF_MEMORY));
    try std.testing.expect(!ignorableCaPathError(c.CURLE_BAD_FUNCTION_ARGUMENT));
}

test "TLS backend detection ignores parenthesized inactive MultiSSL backends" {
    try std.testing.expectEqual(TlsBackend.native, classifyTlsBackend("Schannel (OpenSSL/3.0)"));
    try std.testing.expectEqual(TlsBackend.openssl, classifyTlsBackend("(Schannel) OpenSSL/3.0"));
    try std.testing.expectEqual(TlsBackend.directory_any, classifyTlsBackend("GnuTLS/3.8 (wolfSSL)"));
    try std.testing.expectEqual(TlsBackend.unsupported, classifyTlsBackend("rustls/0.23 (Schannel)"));
    try std.testing.expectEqual(TlsBackend.native, classifyTlsBackend("AppleSecTrust"));
}

test "OpenSSL CA directory entry requires eight hex digits and dot zero" {
    try std.testing.expect(isOpenSslCaEntry("0123abcd.0"));
    try std.testing.expect(isOpenSslCaEntry("ABCDEF09.0"));
    try std.testing.expect(!isOpenSslCaEntry("0123abcd.1"));
    try std.testing.expect(!isOpenSslCaEntry("0123abcg.0"));
    try std.testing.expect(!isOpenSslCaEntry(".hidden"));
}

test "CA failure hint is typed and secret free" {
    const hint = caFailureHint(error.TlsVerificationFailed).?;
    try std.testing.expect(std.mem.indexOf(u8, hint, "CURL_CA_BUNDLE") != null);
    try std.testing.expect(caFailureHint(error.ConnectionFailed) == null);
}

test "CA environment precedence accepts paths without probing" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CURL_CA_BUNDLE", "/does/not/need/to/exist.pem");
    try map.put("SSL_CERT_FILE", "/ignored.pem");
    try map.put("SSL_CERT_DIR", "/ignored-dir");
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environment: std.process.Environ = .{ .block = block };
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, environment);
    defer runtime.deinit();
    try std.testing.expectEqual(CaSource.environment, runtime.caStatus().origin);
    try std.testing.expect(runtime.caStatus().proxy != .environment);
    try std.testing.expectEqualStrings("/does/not/need/to/exist.pem", runtime.ca_info.?);
    try std.testing.expect(runtime.ca_path == null);
}

test "SSL certificate file and directory combine when bundle is absent" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("SSL_CERT_FILE", "/unprobed-file.pem");
    try map.put("SSL_CERT_DIR", "/unprobed-directory");
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environment: std.process.Environ = .{ .block = block };
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, environment);
    defer runtime.deinit();
    try std.testing.expectEqualStrings("/unprobed-file.pem", runtime.ca_info.?);
    try std.testing.expectEqualStrings("/unprobed-directory", runtime.ca_path.?);
}

test "runtime requires asynchronous DNS and owns curl global lifecycle" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    runtime.deinit();
}

const IntegrationServer = struct {
    server: *std.Io.net.Server,

    fn serve(self: IntegrationServer) void {
        var stream = self.server.accept(std.testing.io) catch unreachable;
        defer stream.close(std.testing.io);
        var buffer: [256]u8 = undefined;
        var writer = stream.writer(std.testing.io, &buffer);
        writer.interface.writeAll(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Length: 13\r\n" ++
                "Connection: close\r\n\r\n" ++
                "data: hel",
        ) catch unreachable;
        writer.interface.flush() catch unreachable;
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch unreachable;
        writer.interface.writeAll("lo\n\n") catch unreachable;
        writer.interface.flush() catch unreachable;
    }
};

test "loopback SSE response accepts arbitrary chunks without a content type requirement" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const server_runner: IntegrationServer = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, IntegrationServer.serve, .{server_runner});
    defer thread.join();

    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/stream", .{
        server.socket.address.getPort(),
    });
    const Collector = struct {
        const Self = @This();

        data: [16]u8 = undefined,
        length: usize = 0,

        pub fn emit(self: *Self, event: Transport.SseEvent) Transport.DeliveryError!void {
            @memcpy(self.data[0..event.data.len], event.data);
            self.length = event.data.len;
        }
    };
    var collector: Collector = .{};
    var result = try concrete.streaming().ssePost(std.testing.allocator, std.testing.io, .{
        .url = url,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .json_body = "{}",
        .limits = .{
            .max_request_body_bytes = 16,
            .max_header_bytes = 1024,
            .max_sse_event_bytes = 64,
            .max_error_body_bytes = 64,
            .header_buffer_bytes = 128,
            .connect_timeout_ms = 1_000,
            .idle_timeout_ms = 1_000,
        },
    }, Transport.EventSink.from(&collector));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Transport.Outcome.completed, result.outcome);
    try std.testing.expectEqualStrings("hello", collector.data[0..collector.length]);
}

const StaticServer = struct {
    server: *std.Io.net.Server,
    first: []const u8,
    second: []const u8 = "",
    delay_ms: i64 = 0,

    fn serve(self: StaticServer) void {
        var stream = self.server.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(std.testing.io, &buffer);
        writer.interface.writeAll(self.first) catch return;
        writer.interface.flush() catch return;
        if (self.delay_ms != 0) {
            std.testing.io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch return;
        }
        writer.interface.writeAll(self.second) catch return;
        writer.interface.flush() catch return;
    }
};

fn loopbackUrl(buffer: []u8, server: *const std.Io.net.Server) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/test?exact=yes", .{
        server.socket.address.getPort(),
    });
}

test "loopback non-success SSE drains a bounded prefix and parses Retry-After" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const runner: StaticServer = .{
        .server = &server,
        .first = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 2\r\n" ++
            "Content-Length: 10\r\nConnection: close\r\n\r\n0123456789",
    };
    const thread = try std.Thread.spawn(.{}, StaticServer.serve, .{runner});
    defer thread.join();
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try loopbackUrl(&url_buffer, &server);
    const Ignore = struct {
        const Self = @This();

        pub fn emit(_: *Self, _: Transport.SseEvent) Transport.DeliveryError!void {}
    };
    var ignore: Ignore = .{};
    var result = try concrete.streaming().ssePost(std.testing.allocator, std.testing.io, .{
        .url = url,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .json_body = "{}",
        .limits = .{
            .max_request_body_bytes = 16,
            .max_header_bytes = 1024,
            .max_sse_event_bytes = 64,
            .max_error_body_bytes = 4,
            .header_buffer_bytes = 128,
            .connect_timeout_ms = 1_000,
            .idle_timeout_ms = 1_000,
        },
    }, Transport.EventSink.from(&ignore));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Transport.Outcome.failed, result.outcome);
    try std.testing.expectEqual(@as(u16, 429), result.status);
    try std.testing.expectEqual(@as(?u64, 2_000), result.retry_after_ms);
    try std.testing.expectEqualStrings("0123", result.error_body.?);
}

test "loopback JSON enforces response cap" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const runner: StaticServer = .{
        .server = &server,
        .first = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n0123456789",
    };
    const thread = try std.Thread.spawn(.{}, StaticServer.serve, .{runner});
    defer thread.join();
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try loopbackUrl(&url_buffer, &server);
    try std.testing.expectError(error.InvalidResponse, concrete.json().request(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .get,
            .url = url,
            .headers = &.{},
            .limits = .{
                .max_response_body_bytes = 4,
                .connect_timeout_ms = 1_000,
                .idle_timeout_ms = 1_000,
                .total_timeout_ms = 2_000,
            },
        },
    ));
}

test "loopback header stall observes exact idle timeout" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const runner: StaticServer = .{
        .server = &server,
        .first = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n",
        .second = "Connection: close\r\n\r\n{}",
        .delay_ms = 80,
    };
    const thread = try std.Thread.spawn(.{}, StaticServer.serve, .{runner});
    defer thread.join();
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try loopbackUrl(&url_buffer, &server);
    try std.testing.expectError(error.IdleTimedOut, concrete.json().request(
        std.testing.allocator,
        std.testing.io,
        .{
            .method = .get,
            .url = url,
            .headers = &.{},
            .limits = .{
                .connect_timeout_ms = 1_000,
                .idle_timeout_ms = 20,
                .total_timeout_ms = 2_000,
            },
        },
    ));
}

test "loopback sink cancellation wins over curl callback failure" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const runner: StaticServer = .{
        .server = &server,
        .first = "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\ndata: stop\n\n",
    };
    const thread = try std.Thread.spawn(.{}, StaticServer.serve, .{runner});
    defer thread.join();
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try loopbackUrl(&url_buffer, &server);
    const CancelSink = struct {
        const Self = @This();

        pub fn emit(_: *Self, _: Transport.SseEvent) Transport.DeliveryError!void {
            return error.Cancelled;
        }
    };
    var cancel_sink: CancelSink = .{};
    try std.testing.expectError(error.Cancelled, concrete.streaming().ssePost(
        std.testing.allocator,
        std.testing.io,
        .{
            .url = url,
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .json_body = "{}",
            .limits = .{
                .max_request_body_bytes = 16,
                .max_header_bytes = 1024,
                .max_sse_event_bytes = 64,
                .max_error_body_bytes = 64,
                .header_buffer_bytes = 128,
                .connect_timeout_ms = 1_000,
                .idle_timeout_ms = 1_000,
            },
        },
        Transport.EventSink.from(&cancel_sink),
    ));
}

test "pre-dispatch cancellation retains no privileged header or active curl handle" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    const CancelTick = struct {
        const Self = @This();

        pub fn poll(_: *Self) Provider.DeliveryError!void {
            return error.Cancelled;
        }
    };
    const Ignore = struct {
        const Self = @This();

        pub fn emit(_: *Self, _: Transport.SseEvent) Transport.DeliveryError!void {}
    };
    var tick: CancelTick = .{};
    var ignore: Ignore = .{};
    try std.testing.expectError(error.Cancelled, concrete.streaming().ssePost(
        std.testing.allocator,
        std.testing.io,
        .{
            .url = "https://example.test/never-dispatched",
            .headers = &.{.{ .name = "Authorization", .value = "Bearer top-secret" }},
            .json_body = "{}",
            .tick = Provider.Tick.from(&tick),
            .limits = .{
                .max_request_body_bytes = 16,
                .max_header_bytes = 1024,
                .max_sse_event_bytes = 64,
                .max_error_body_bytes = 64,
                .header_buffer_bytes = 128,
                .connect_timeout_ms = 1_000,
                .idle_timeout_ms = 1_000,
            },
        },
        Transport.EventSink.from(&ignore),
    ));
    try std.testing.expectEqual(@as(usize, 0), runtime.active_multi.items.len);
    try std.testing.expect(std.mem.indexOf(u8, @errorName(error.Cancelled), "top-secret") == null);
}

test "loopback non-success SSE supplies bounded no-response-body literal" {
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const runner: StaticServer = .{
        .server = &server,
        .first = "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, StaticServer.serve, .{runner});
    defer thread.join();
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer runtime.deinit();
    var concrete = runtime.transport();
    var url_buffer: [128]u8 = undefined;
    const url = try loopbackUrl(&url_buffer, &server);
    const Ignore = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: Transport.SseEvent) Transport.DeliveryError!void {}
    };
    var ignore: Ignore = .{};
    var result = try concrete.streaming().ssePost(std.testing.allocator, std.testing.io, .{
        .url = url,
        .headers = &.{},
        .json_body = "{}",
        .limits = .{
            .max_request_body_bytes = 16,
            .max_header_bytes = 1024,
            .max_sse_event_bytes = 64,
            .max_error_body_bytes = 8,
            .header_buffer_bytes = 128,
            .connect_timeout_ms = 1_000,
            .idle_timeout_ms = 1_000,
        },
    }, Transport.EventSink.from(&ignore));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("(no resp", result.error_body.?);
}
