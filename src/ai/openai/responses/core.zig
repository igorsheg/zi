const std = @import("std");
const protocol = @import("../../protocol.zig");
const ai_provider = @import("../../provider.zig");
const provider_failure = @import("../../provider_failure.zig");
const request_transform = @import("../../request_transform.zig");
const responses_request = @import("request.zig");
const responses_stream = @import("stream.zig");
const Token = protocol.CancelToken;
const http_cancel = @import("../../../runtime/http_cancel.zig");

pub const AuthFactory = struct {
    ctx: ?*anyopaque = null,
    build: *const fn (
        ctx: ?*anyopaque,
        buf: []u8,
        api_key: ?[]const u8,
    ) error{ NoApiKey, BufferTooSmall }![]u8,
};

pub const EventMapOutcome = responses_stream.EventMapOutcome;
pub const EventMapper = responses_stream.EventMapper;
pub const identityEventMapper = responses_stream.identityEventMapper;
pub const codexEventMapper = responses_stream.codexEventMapper;

pub const CoreOptions = struct {
    base_url: ?[]const u8 = null,
    path: []const u8,
    auth: AuthFactory,
    extra_headers: []const protocol.Header = &.{},
    provider_label: []const u8 = "openai-responses",
    event_mapper: EventMapper = .{ .map = identityEventMapper },
    reasoning_effort: ?[]const u8 = null,
    reasoning_summary: ?[]const u8 = null,
    build_request: ?*const fn (
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        reasoning_effort: ?[]const u8,
        reasoning_summary: ?[]const u8,
    ) anyerror!void = null,
};

pub fn streamCore(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    core: CoreOptions,
    sink: ai_provider.StreamEventSink,
) void {
    var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_buf.deinit(allocator);
    const build_fn = core.build_request orelse &responses_request.buildRequestJson;
    build_fn(allocator, &payload_buf, model, context, options, core.reasoning_effort, core.reasoning_summary) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to build request: {s}", .{@errorName(err)});
        return;
    };
    const transformed_payload = request_transform.transformJsonPayload(allocator, payload_buf.items, .{
        .model = &model,
        .stream_options = options,
    }) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to transform request: {s}", .{@errorName(err)});
        return;
    };
    defer if (transformed_payload) |payload| allocator.free(payload);
    const request_payload = transformed_payload orelse payload_buf.items;

    var auth_buf: [4096]u8 = undefined;
    const auth_value = core.auth.build(core.auth.ctx, &auth_buf, options.api_key) catch |err| {
        const msg = switch (err) {
            error.NoApiKey => "no API key provided",
            error.BufferTooSmall => "API key too long for auth buffer",
        };
        responses_stream.emitError(allocator, sink, model, core.provider_label, "{s}", .{msg});
        return;
    };

    const base = core.base_url orelse model.base_url;
    const uri_str = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, core.path }) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to build URI: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(uri_str);

    const uri = std.Uri.parse(uri_str) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to parse URI: {s}", .{@errorName(err)});
        return;
    };

    var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
    defer client.deinit();

    var extra_headers_buf: [16]std.http.Header = undefined;
    var n_extra: usize = 0;
    extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
    n_extra += 1;

    if (model.headers) |mh| for (mh) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    };
    for (core.extra_headers) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    }
    if (options.headers) |custom| for (custom) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = extra_headers_buf[0..n_extra],
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to open connection: {s}", .{@errorName(err)});
        return;
    };
    defer req.deinit();

    var abort_guard = http_cancel.ShutdownOnCancel.start(allocator, options.io, options.signal, http_cancel.requestStream(&req)) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to start interrupt guard: {s}", .{@errorName(err)});
        return;
    };
    defer abort_guard.stop();

    req.sendBodyComplete(request_payload) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to send body: {s}", .{@errorName(err)});
        return;
    };

    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        responses_stream.emitError(allocator, sink, model, core.provider_label, "request failed: {s}", .{@errorName(err)});
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
            responses_stream.emitError(allocator, sink, model, core.provider_label, "failed to normalize HTTP error: {s}", .{@errorName(err)});
            return;
        };
        responses_stream.emitFailure(allocator, sink, model, core.provider_label, normalized.failure, normalized.display_message);
        return;
    }

    var reader = response.reader(&transfer_buf);
    responses_stream.processStreamMapped(allocator, &reader, model, options.signal, core.provider_label, core.event_mapper, sink);
}

fn formatHttpErrorDetail(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) ![]const u8 {
    const status_code = @intFromEnum(status);
    const reason = status.phrase() orelse "";
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s} (empty body)", .{ status_code, reason });
        return std.fmt.allocPrint(allocator, "HTTP {d} (empty body)", .{status_code});
    }

    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        if (extractJsonErrorMessage(parsed.value)) |message| {
            if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s}: {s}", .{ status_code, reason, message });
            return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status_code, message });
        }
    } else |_| {}

    if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s}: {s}", .{ status_code, reason, trimmed });
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status_code, trimmed });
}

fn extractJsonErrorMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("error")) |err| {
        switch (err) {
            .string => |s| return s,
            .object => {
                if (err.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) return msg.string;
                if (err.object.get("code")) |code| if (code == .string and code.string.len > 0) return code.string;
            },
            else => {},
        }
    }
    if (value.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) return msg.string;
    return null;
}

const testing = std.testing;

const TestCollector = struct {
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    thinking: std.ArrayListUnmanaged(u8) = .empty,
    tool_args: std.ArrayListUnmanaged(u8) = .empty,
    final_tool_id: []const u8 = "",
    final_tool_name: []const u8 = "",
    final_response_id: ?[]const u8 = null,
    done_reason: ?protocol.AssistantMessageEvent.DoneReason = null,
    allocator: std.mem.Allocator,
    alloc_failed: bool = false,

    const EventKind = enum {
        start,
        text_start,
        text_delta,
        text_end,
        thinking_start,
        thinking_delta,
        thinking_end,
        toolcall_start,
        toolcall_delta,
        toolcall_end,
        done,
        err,
    };

    fn deinit(self: *TestCollector) void {
        self.events.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
        self.tool_args.deinit(self.allocator);
    }

    fn cb(evt: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
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
            .text_end => |end| {
                self.events.append(self.allocator, .text_end) catch {
                    self.alloc_failed = true;
                };
                if (end.content.len > 0) {
                    self.text.clearRetainingCapacity();
                    self.text.appendSlice(self.allocator, end.content) catch {
                        self.alloc_failed = true;
                    };
                }
            },
            .thinking_start => self.events.append(self.allocator, .thinking_start) catch {
                self.alloc_failed = true;
            },
            .thinking_delta => |d| {
                self.events.append(self.allocator, .thinking_delta) catch {
                    self.alloc_failed = true;
                };
                self.thinking.appendSlice(self.allocator, d.delta) catch {
                    self.alloc_failed = true;
                };
            },
            .thinking_end => self.events.append(self.allocator, .thinking_end) catch {
                self.alloc_failed = true;
            },
            .toolcall_start => self.events.append(self.allocator, .toolcall_start) catch {
                self.alloc_failed = true;
            },
            .toolcall_delta => |d| {
                self.events.append(self.allocator, .toolcall_delta) catch {
                    self.alloc_failed = true;
                };
                self.tool_args.appendSlice(self.allocator, d.delta) catch {
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
            .done => |d| {
                self.events.append(self.allocator, .done) catch {
                    self.alloc_failed = true;
                };
                self.done_reason = d.reason;
                if (d.message.response_id) |rid| self.final_response_id = rid;
            },
            .@"error" => self.events.append(self.allocator, .err) catch {
                self.alloc_failed = true;
            },
        }
    }
};

const test_model: protocol.Model = .{
    .id = "openai/gpt-test",
    .name = "test",
    .api = .openai_responses,
    .provider = .openai,
    .base_url = "https://api.openai.com",
    .reasoning = true,
    .input = &.{.text},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 4096,
    .max_tokens = 1024,
};

fn runProcessWithMapper(
    arena: std.mem.Allocator,
    sse_bytes: []const u8,
    event_mapper: EventMapper,
    collector: *TestCollector,
) !void {
    var reader: std.Io.Reader = .fixed(sse_bytes);
    responses_stream.processStreamMapped(arena, &reader, test_model, Token.none, "openai-responses", event_mapper, .{ .func = TestCollector.cb, .ctx = @ptrCast(collector) });
    try testing.expect(!collector.alloc_failed);
}

fn runProcess(arena: std.mem.Allocator, sse_bytes: []const u8, collector: *TestCollector) !void {
    try runProcessWithMapper(arena, sse_bytes, .{ .map = identityEventMapper }, collector);
}

fn expectCollectorSaw(col: TestCollector, kind: TestCollector.EventKind) !void {
    for (col.events.items) |event| {
        if (event == kind) return;
    }
    return error.TestExpectedEqual;
}

fn writeInputToJson(allocator: std.mem.Allocator, model: protocol.Model, ctx: protocol.Context) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };
    try jw.beginArray();
    try responses_request.writeInputOpts(allocator, &jw, model, ctx, false);
    try jw.endArray();
    return allocating.toOwnedSlice();
}

test "processStream maps reasoning summary deltas to a thinking block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_abc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_part.added\",\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Let me think\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\" carefully.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque-blob\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_abc\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"total_tokens\":30}}}\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("Let me think carefully.", col.thinking.items);
    try testing.expectEqualStrings("resp_abc", col.final_response_id.?);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
    try expectCollectorSaw(col, .thinking_start);
    try expectCollectorSaw(col, .thinking_end);
}

test "processStream maps output_text deltas to a text block with response_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_xyz\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_xyz\",\"status\":\"completed\"}}\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("Hello world", col.text.items);
    try testing.expectEqualStrings("resp_xyz", col.final_response_id.?);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
}

test "processStream concatenates function_call argument chunks and overrides stop to toolUse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"cmd\\\":\\\"\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"echo hi\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tc\",\"status\":\"completed\"}}\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("call_abc|fc_1", col.final_tool_id);
    try testing.expectEqualStrings("bash", col.final_tool_name);
    try testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", col.tool_args.items);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.toolUse, col.done_reason.?);
}

test "processStreamMapped codex mapper stops after terminal response.completed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8}}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" ignored\"}\n\n";

    try runProcessWithMapper(alloc, sse_bytes, .{ .map = codexEventMapper }, &col);

    try testing.expectEqualStrings("Hello", col.text.items);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
}

test "processStream uses final output_item payload for message phase and tool ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_added\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"draft\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_final\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"final text\"}]}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_added\",\"call_id\":\"call_added\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"draft\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"cmd\\\":\\\"draft\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_final\",\"call_id\":\"call_final\",\"name\":\"bash_final\",\"arguments\":\"{\\\"cmd\\\":\\\"final\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("final text", col.text.items);
    try testing.expectEqualStrings("call_final|fc_final", col.final_tool_id);
    try testing.expectEqualStrings("bash_final", col.final_tool_name);
}

test "buildRequestJson emits store:false, input[], and reasoning:none for reasoning model" {
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
    try responses_request.buildRequestJson(alloc, &out, test_model, ctx, .{}, null, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"store\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"developer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"input_text\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"none\"") != null);
}

test "buildRequestJson includes prompt cache, max_output_tokens, and temperature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ctx: protocol.Context = .{
        .messages = &.{
            .{ .user = .{ .content = .{ .text = "hi" }, .timestamp = 0 } },
        },
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try responses_request.buildRequestJson(alloc, &out, test_model, ctx, .{
        .session_id = "session-123",
        .cache_retention = .long,
        .max_tokens = 321,
        .temperature = 0.5,
    }, null, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_key\":\"session-123\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_retention\":\"24h\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"max_output_tokens\":321") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"temperature\":0.5") != null);
}

test "writeInputOpts remaps foreign tool result ids to the replayed function call id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var foreign_args = std.json.Value{ .object = .{} };
    defer foreign_args.object.deinit(alloc);

    const assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call:bad|item bad!!!",
            .name = "bash",
            .arguments = foreign_args,
        } }},
        .api = .openai_completions,
        .provider = .openrouter,
        .model = "openai/gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tool_result: protocol.ToolResultMessage = .{
        .tool_call_id = "call:bad|item bad!!!",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "ok" } }},
        .details = null,
        .is_error = false,
        .timestamp = 0,
    };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = assistant }, .{ .tool_result = tool_result } } };

    const written = try writeInputToJson(alloc, test_model, ctx);
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"call_id\":\"call_bad\"") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "\"call_id\":\"call_bad\""));
}

test "writeInputOpts inserts synthetic tool result and skips errored assistants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var synthetic_args = std.json.Value{ .object = .{} };
    defer synthetic_args.object.deinit(alloc);

    const tool_calling_assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call_1|fc_1",
            .name = "bash",
            .arguments = synthetic_args,
        } }},
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .model = "gpt-5.4",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const errored_assistant = protocol.AssistantMessage{
        .content = &.{.{ .text = .{ .text = "should not replay" } }},
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .model = "gpt-5.4",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .@"error",
        .timestamp = 0,
    };
    const user = protocol.UserMessage{ .content = .{ .text = "next" }, .timestamp = 0 };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = tool_calling_assistant }, .{ .assistant = errored_assistant }, .{ .user = user } } };

    const written = try writeInputToJson(alloc, .{
        .id = "gpt-5.4",
        .name = "codex",
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 4096,
        .max_tokens = 1024,
    }, ctx);
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "No result provided") != null);
    try testing.expect(std.mem.indexOf(u8, written, "should not replay") == null);
}

test "writeInputOpts serializes invalid tool-result utf-8 as output text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var foreign_args = std.json.Value{ .object = .{} };
    defer foreign_args.object.deinit(alloc);

    const assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call:bad|item bad!!!",
            .name = "bash",
            .arguments = foreign_args,
        } }},
        .api = .openai_completions,
        .provider = .openrouter,
        .model = "openai/gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tool_result: protocol.ToolResultMessage = .{
        .tool_call_id = "call:bad|item bad!!!",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "bad\xaa\xfftail" } }},
        .details = null,
        .is_error = false,
        .timestamp = 0,
    };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = assistant }, .{ .tool_result = tool_result } } };

    const written = try writeInputToJson(alloc, test_model, ctx);
    defer alloc.free(written);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, written, .{});
    defer parsed.deinit();

    var found = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function_call_output")) continue;
        const output = item.object.get("output") orelse continue;
        try testing.expect(output == .string);
        try testing.expect(std.mem.indexOf(u8, output.string, "tail") != null);
        found = true;
        break;
    }
    try testing.expect(found);
}

test "processStream infers toolUse at EOF when tool calls are present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}}\n\n";

    try runProcess(alloc, sse_bytes, &col);

    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.toolUse, col.done_reason.?);
}
