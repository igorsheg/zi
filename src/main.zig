const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

        const context = agent.protocol.AgentContext{
            .system_prompt = "You are a helpful assistant. Be concise.",
            .messages = &.{user_msg},
        };

        const options = ai.protocol.StreamOptions{
            .api_key = key,
            .max_tokens = 4096,
        };

        agent.loop.runSingleTurn(
            allocator,
            &registry,
            model,
            context,
            options,
            &printHandler,
            null,
        );

        try stdout.writeAll("\n");
    } else {
        try stderr.writeAll("error: interactive mode not yet implemented. use -p flag.\n");
        std.process.exit(1);
    }
}

fn printHandler(event: agent.protocol.AgentEvent, _: ?*anyopaque) void {
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
        else => {},
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
