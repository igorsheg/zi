const std = @import("std");
const ai = @import("ai");
const auth = @import("auth");
const agent = @import("agent");
const session = @import("session");
const bash_tool = @import("tools/bash.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // Arena allocator for the entire run. No explicit frees needed in print mode.
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var print_mode = false;
    var show_help = false;
    var show_version = false;
    var api_key_arg: ?[]const u8 = null;
    var model_id: ?[]const u8 = null;
    var list_models = false;
    var prompt_text: ?[]const u8 = null;

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (eql(arg, "-p") or eql(arg, "--print")) {
            print_mode = true;
        } else if (eql(arg, "-h") or eql(arg, "--help")) {
            show_help = true;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            show_version = true;
        } else if (eql(arg, "--api-key")) {
            api_key_arg = args.next();
        } else if (eql(arg, "--model")) {
            if (args.next()) |m| model_id = m;
        } else if (eql(arg, "--list-models")) {
            list_models = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            prompt_text = arg;
        }
    }

    if (show_version) {
        try stdout.writeAll("zi v0.0.1\n");
        return;
    }
    if (show_help) {
        try stdout.writeAll(
            \\zi — AI coding agent
            \\
            \\Usage: zi [options] [message]
            \\
            \\Options:
            \\  -p, --print           Non-interactive mode
            \\  --model <id>          Model ID or pattern (default: claude-sonnet-4-20250514)
            \\  --api-key <key>       API key (or set ANTHROPIC_API_KEY)
            \\  --list-models         List available models
            \\  -h, --help            Show help
            \\  -v, --version         Show version
            \\
        );
        return;
    }

    if (list_models) {
        const all = ai.models.getAllModels();
        for (all) |m| {
            stdout.writeAll(ai.provider.apiToString(m.api)) catch {};
            stdout.writeAll("\t") catch {};
            stdout.writeAll(m.id) catch {};
            stdout.writeAll("\t") catch {};
            stdout.writeAll(m.name) catch {};
            stdout.writeAll("\n") catch {};
        }
        return;
    }

    if (print_mode or prompt_text != null) {
        const prompt = prompt_text orelse {
            try stderr.writeAll("error: no prompt provided\n");
            std.process.exit(1);
        };

        // Resolve model from catalog
        const resolved_id = model_id orelse "claude-sonnet-4-20250514";
        const model = ai.models.getModelById(resolved_id) orelse
            ai.models.findModel(resolved_id) orelse {
            try stderr.writeAll("error: model not found: ");
            try stderr.writeAll(resolved_id);
            try stderr.writeAll("\nuse --list-models to see available models\n");
            std.process.exit(1);
        };

        // Only anthropic provider implemented for now
        if (!std.meta.eql(model.api, .anthropic_messages)) {
            try stderr.writeAll("error: only anthropic models supported currently. model '");
            try stderr.writeAll(model.id);
            try stderr.writeAll("' uses api '");
            try stderr.writeAll(ai.provider.apiToString(model.api));
            try stderr.writeAll("'\n");
            std.process.exit(1);
        }

        const key = api_key_arg orelse std.posix.getenv("ANTHROPIC_API_KEY") orelse {
            try stderr.writeAll("error: no API key. set ANTHROPIC_API_KEY or use --api-key\n");
            std.process.exit(1);
        };

        var anthropic_prov = ai.anthropic.AnthropicProvider.init(allocator);
        const prov = anthropic_prov.provider();

        var registry = ai.provider.Registry.init(allocator);
        defer registry.deinit();
        try registry.register("anthropic-messages", prov, null);

        const user_msg = agent.protocol.AgentMessage{
            .user = .{
                .content = .{ .text = prompt },
                .timestamp = std.time.milliTimestamp(),
            },
        };

        // Build tools
        const tools = [_]agent.protocol.AgentTool{
            bash_tool.makeTool(),
        };

        const options = ai.protocol.StreamOptions{
            .api_key = key,
            .max_tokens = 4096,
        };

        // Session writer — persists messages incrementally on message_end,
        // gated on first assistant message (matches pi-mono behavior).
        const cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch "/unknown";
        var sw = session.writer.SessionWriter.init(allocator, cwd_buf);

        var handler = PrintSessionHandler{ .session_writer = &sw };

        agent.loop.runAgentLoop(
            allocator,
            &registry,
            model,
            "You are a helpful assistant. Be concise. You have access to a bash tool to execute commands.",
            &.{user_msg},
            &tools,
            options,
            &PrintSessionHandler.callback,
            @ptrCast(&handler),
        );

        try stdout.writeAll("\n");

        if (sw.flushed) {
            stderr.writeAll("session: ") catch {};
            stderr.writeAll(sw.session_file) catch {};
            stderr.writeAll("\n") catch {};
        }
    } else {
        try stderr.writeAll("error: interactive mode not yet implemented. use -p flag.\n");
        std.process.exit(1);
    }
}

/// Event handler: prints to stdout/stderr AND persists messages on message_end.
const PrintSessionHandler = struct {
    session_writer: *session.writer.SessionWriter,

    fn callback(event: agent.protocol.AgentEvent, ctx: ?*anyopaque) void {
        const self: *PrintSessionHandler = @ptrCast(@alignCast(ctx));
        switch (event) {
            .message_update => |mu| {
                switch (mu.assistant_message_event) {
                    .text_delta => |d| stdout.writeAll(d.delta) catch {},
                    .@"error" => |e| {
                        if (e.@"error".error_message) |msg| {
                            stderr.writeAll("\nerror: ") catch {};
                            stderr.writeAll(msg) catch {};
                            stderr.writeAll("\n") catch {};
                        }
                    },
                    else => {},
                }
            },
            .tool_execution_start => |te| {
                stderr.writeAll("⚡ ") catch {};
                stderr.writeAll(te.tool_name) catch {};
                stderr.writeAll("\n") catch {};
            },
            .message_end => |me| {
                self.session_writer.appendMessage(me.message);
            },
            else => {},
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
