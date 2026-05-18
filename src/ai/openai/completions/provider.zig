const std = @import("std");
const protocol = @import("../../protocol.zig");
const ai_models = @import("../../models.zig");
const ai_provider = @import("../../provider.zig");
const ai_stream = @import("../../stream.zig");
const provider_failure = @import("../../provider_failure.zig");
const request_transform = @import("../../request_transform.zig");
const completions_request = @import("request.zig");
const completions_stream = @import("stream.zig");
const Token = protocol.CancelToken;
const http_cancel = @import("../../../runtime/http_cancel.zig");
const env_api_keys = @import("../../env_api_keys.zig");

pub const OpenAICompletionsProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAICompletionsProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *OpenAICompletionsProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamImplWrapper,
                .stream_simple = streamSimpleImplWrapper,
                .get_name = getNameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn streamImplWrapper(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        const self: *OpenAICompletionsProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options, null, sink);
    }

    fn streamSimpleImplWrapper(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        const self: *OpenAICompletionsProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options.base, ai_models.clampReasoning(options.reasoning, model), sink);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "openai-completions";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn streamImpl(
        self: *OpenAICompletionsProvider,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        reasoning: ?protocol.ThinkingLevel,
        sink: ai_provider.StreamEventSink,
    ) void {
        _ = self;

        var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_buf.deinit(allocator);
        completions_request.buildRequestJson(allocator, &payload_buf, model, context, reasoning) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to build request: {s}", .{@errorName(err)});
            return;
        };
        const transformed_payload = request_transform.transformJsonPayload(allocator, payload_buf.items, .{
            .model = &model,
            .stream_options = options,
        }) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to transform request: {s}", .{@errorName(err)});
            return;
        };
        defer if (transformed_payload) |payload| allocator.free(payload);
        const request_payload = transformed_payload orelse payload_buf.items;

        const api_key = options.api_key orelse {
            completions_stream.emitError(allocator, sink, model, "no API key provided", .{});
            return;
        };

        const uri_str = std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url}) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to build URI: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to parse URI: {s}", .{@errorName(err)});
            return;
        };

        var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
        defer client.deinit();

        var auth_buf: [4096]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch {
            completions_stream.emitError(allocator, sink, model, "API key too long for auth buffer", .{});
            return;
        };

        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;
        extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
        n_extra += 1;

        if (model.headers) |mh| {
            for (mh) |h| {
                if (n_extra >= extra_headers_buf.len) break;
                extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                n_extra += 1;
            }
        }
        if (options.headers) |custom_headers| {
            for (custom_headers) |h| {
                if (n_extra >= extra_headers_buf.len) break;
                extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                n_extra += 1;
            }
        }

        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers_buf[0..n_extra],
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to open connection: {s}", .{@errorName(err)});
            return;
        };
        defer req.deinit();

        var abort_guard = http_cancel.ShutdownOnCancel.start(allocator, options.io, options.signal, http_cancel.requestStream(&req)) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to start interrupt guard: {s}", .{@errorName(err)});
            return;
        };
        defer abort_guard.stop();

        req.sendBodyComplete(request_payload) catch |err| {
            completions_stream.emitError(allocator, sink, model, "failed to send body: {s}", .{@errorName(err)});
            return;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            completions_stream.emitError(allocator, sink, model, "request failed: {s}", .{@errorName(err)});
            return;
        };

        const status = response.head.status;
        var transfer_buf: [16384]u8 = undefined;

        if (status != .ok) {
            var reader = response.reader(&transfer_buf);
            var err_body_buf: [4096]u8 = undefined;
            var n_read: usize = 0;
            while (n_read < err_body_buf.len) {
                var writer: std.Io.Writer = .fixed(err_body_buf[n_read..]);
                const n = reader.stream(&writer, .limited(err_body_buf.len - n_read)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.WriteFailed => unreachable,
                    else => break,
                };
                if (n == 0) break;
                n_read += n;
            }
            const normalized = provider_failure.normalizeHttpFailure(allocator, status, err_body_buf[0..n_read]) catch |err| {
                completions_stream.emitError(allocator, sink, model, "failed to normalize HTTP error: {s}", .{@errorName(err)});
                return;
            };
            completions_stream.emitFailure(sink, model, normalized.failure, normalized.display_message);
            return;
        }

        const reader = response.reader(&transfer_buf);
        completions_stream.processStream(allocator, reader, model, options.signal, sink);
    }
};

const testing = std.testing;

const TestCollector = struct {
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    final_args: std.ArrayListUnmanaged(u8) = .empty,
    final_tool_id: []const u8 = "",
    final_tool_name: []const u8 = "",
    final_error_message: ?[]const u8 = null,
    final_failure_kind: ?protocol.NormalizedFailure.Kind = null,
    final_provider_type: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    alloc_failed: bool = false,

    const EventKind = enum { start, text_start, text_delta, text_end, toolcall_start, toolcall_delta, toolcall_end, done, err, thinking_start, thinking_delta, thinking_end };

    fn deinit(self: *TestCollector) void {
        self.events.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.final_args.deinit(self.allocator);
    }

    fn callback(evt: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        switch (evt) {
            .start => self.events.append(self.allocator, .start) catch {
                self.alloc_failed = true;
            },
            .text_start => self.events.append(self.allocator, .text_start) catch {
                self.alloc_failed = true;
            },
            .text_delta => |d| {
                self.events.append(self.allocator, .text_delta) catch {
                    self.alloc_failed = true;
                };
                self.text.appendSlice(self.allocator, d.delta) catch {
                    self.alloc_failed = true;
                };
            },
            .text_end => self.events.append(self.allocator, .text_end) catch {
                self.alloc_failed = true;
            },
            .toolcall_start => self.events.append(self.allocator, .toolcall_start) catch {
                self.alloc_failed = true;
            },
            .toolcall_delta => |d| {
                self.events.append(self.allocator, .toolcall_delta) catch {
                    self.alloc_failed = true;
                };
                self.final_args.appendSlice(self.allocator, d.delta) catch {
                    self.alloc_failed = true;
                };
            },
            .toolcall_end => |e| {
                self.events.append(self.allocator, .toolcall_end) catch {
                    self.alloc_failed = true;
                };
                self.final_tool_id = e.tool_call.id;
                self.final_tool_name = e.tool_call.name;
            },
            .thinking_start => self.events.append(self.allocator, .thinking_start) catch {
                self.alloc_failed = true;
            },
            .thinking_delta => self.events.append(self.allocator, .thinking_delta) catch {
                self.alloc_failed = true;
            },
            .thinking_end => self.events.append(self.allocator, .thinking_end) catch {
                self.alloc_failed = true;
            },
            .done => self.events.append(self.allocator, .done) catch {
                self.alloc_failed = true;
            },
            .@"error" => |e| {
                self.events.append(self.allocator, .err) catch {
                    self.alloc_failed = true;
                };
                self.final_error_message = e.@"error".error_message;
                self.final_failure_kind = if (e.@"error".failure) |f| f.kind else null;
                self.final_provider_type = if (e.@"error".failure) |f| f.provider_type else null;
            },
        }
    }
};

const test_model: protocol.Model = .{
    .id = "openai/gpt-test",
    .name = "test",
    .api = .openai_completions,
    .provider = .openrouter,
    .base_url = "https://openrouter.ai/api/v1",
    .reasoning = false,
    .input = &.{.text},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 4096,
    .max_tokens = 1024,
};

fn runProcess(arena: std.mem.Allocator, sse_bytes: []const u8, collector: *TestCollector) !void {
    var reader: std.Io.Reader = .fixed(sse_bytes);
    var terminal_tracker: ai_stream.TerminalTracker = .{};
    var tracking_sink: ai_stream.TrackingSink = .{
        .tracker = &terminal_tracker,
        .inner = .{ .func = TestCollector.callback, .ctx = @ptrCast(collector) },
    };
    completions_stream.processStream(arena, &reader, test_model, Token.none, tracking_sink.sink());
    try testing.expect(!collector.alloc_failed);
    _ = try terminal_tracker.finish();
}

fn expectEventAt(col: TestCollector, index: usize, kind: TestCollector.EventKind) !void {
    try testing.expect(index < col.events.items.len);
    try testing.expectEqual(kind, col.events.items[index]);
}

fn expectLastEvent(col: TestCollector, kind: TestCollector.EventKind) !void {
    try testing.expect(col.events.items.len > 0);
    try testing.expectEqual(kind, col.events.items[col.events.items.len - 1]);
}

fn expectContainsEvent(col: TestCollector, kind: TestCollector.EventKind) !void {
    for (col.events.items) |event| {
        if (event == kind) return;
    }
    return error.TestExpectedEqual;
}

test "processStream emits text_delta then done for a simple text response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try expectEventAt(col, 0, .start);
    try expectEventAt(col, 1, .text_start);
    try expectEventAt(col, 2, .text_delta);
    try expectEventAt(col, 3, .text_delta);
    try testing.expectEqual(TestCollector.EventKind.text_end, col.events.items[col.events.items.len - 2]);
    try expectLastEvent(col, .done);
    try testing.expectEqualStrings("Hello world", col.text.items);
}

test "processStream concatenates split tool-call argument chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"t1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"echo hi\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try expectContainsEvent(col, .toolcall_end);
    try testing.expectEqualStrings("t1", col.final_tool_id);
    try testing.expectEqualStrings("bash", col.final_tool_name);
    try testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", col.final_args.items);
}

test "processStream normalizes openrouter error events carried in a 200 stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-err\",\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\",\"metadata\":{\"raw\":\"provider overload\"}}}\n\n" ++
        "data: [DONE]\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try expectLastEvent(col, .err);
    try testing.expectEqual(protocol.NormalizedFailure.Kind.rate_limited, col.final_failure_kind.?);
    try testing.expectEqualStrings("Rate limit exceeded\nprovider overload", col.final_error_message.?);
}

test "processStream maps network_error finish_reason to transient failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"network_error\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try expectLastEvent(col, .err);
    try testing.expectEqual(protocol.NormalizedFailure.Kind.transient, col.final_failure_kind.?);
    try testing.expectEqualStrings("Provider finish_reason: network_error", col.final_error_message.?);
}

test "buildRequestJson emits stream:true and message round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ctx: protocol.Context = .{
        .system_prompt = "be helpful",
        .messages = &.{
            .{ .user = .{ .content = .{ .text = "hi" }, .timestamp = 0 } },
        },
        .tools = null,
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try completions_request.buildRequestJson(alloc, &out, test_model, ctx, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "be helpful") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"openai/gpt-test\"") != null);
}
