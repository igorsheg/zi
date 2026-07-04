const std = @import("std");

const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const client_protocol = coding_agent.client_protocol;
const Engine = coding_agent.Engine;
const vm = coding_agent.view_model;

pub const OutputMode = enum { text, json };

pub const Options = struct {
    prompt: []const u8,
    output: OutputMode = .text,
};

pub fn run(
    engine: *Engine,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
        engine.allocator,
        1,
        options.prompt,
        .auto,
    );
    errdefer envelope.deinit(engine.allocator);
    try engine.submit(envelope);

    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.heap.page_allocator);
    var wrote_text = false;
    var saw_terminal = false;
    while (!saw_terminal) {
        var sample = try engine.viewModel().sample(
            std.heap.page_allocator,
            &cursor,
            vm.sample_bytes_per_frame_max,
        );
        defer sample.deinit(std.heap.page_allocator);
        for (sample.notices.items) |notice| {
            if (notice.severity == .err) try printAssistantError(stderr, notice.text.slice());
        }
        for (sample.items.items) |item| {
            if (item.kind == .assistant and item.text_suffix.len > 0) {
                switch (options.output) {
                    .text => try stdout.writeAll(item.text_suffix),
                    .json => try writeJsonDelta(stdout, item.text_suffix),
                }
                wrote_text = true;
            }
            if ((item.kind == .assistant or item.kind == .system_notice) and item.state == .final) saw_terminal = true;
        }
        if (sample.op.phase == .idle and wrote_text) saw_terminal = true;
        if (!saw_terminal) std.Thread.yield() catch {};
    }
    if (options.output == .text and wrote_text) try stdout.writeByte('\n');
}

fn writeJsonDelta(stdout: *std.Io.Writer, text: []const u8) !void {
    try stdout.writeAll("{\"type\":\"assistant_delta\",\"text\":");
    try std.json.Stringify.value(text, .{}, stdout);
    try stdout.writeAll("}\n");
    try stdout.flush();
}

fn printAssistantError(stderr: *std.Io.Writer, message: []const u8) !void {
    try stderr.writeAll(message);
    try stderr.writeByte('\n');
}

test "print mode emits assistant text from injected stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var provider = try ai.FauxProvider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    const content = [_]ai.AssistantContent{ai.faux.text("hi")};
    const message = ai.faux.assistantMessage(&content, .{});
    try provider.setResponses(&.{message});

    const engine = try Engine.start(std.testing.allocator, null, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-05-27T00:00:00Z" } },
        .dir = tmp.dir,
        .stream = provider.apiProvider().stream,
    });
    defer {
        engine.requestShutdown();
        engine.join();
    }

    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);

    try run(engine, &stdout, &stderr, .{ .prompt = "hello" });
    try std.testing.expectEqualStrings("hi\n", stdout.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}
