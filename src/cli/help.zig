pub fn writeGeneralHelp(writer: anytype) !void {
    try writer.writeAll(
        \\zi — AI coding agent
        \\
        \\Usage: zi [options] [message]
        \\
        \\Options:
        \\  -p, --print           Non-interactive mode
        \\  --model <id>          Model ID or pattern (default: from settings or claude-sonnet-4)
        \\  --api-key <key>       API key override (also reads ~/.zi/agent/auth.json)
        \\  --continue <path>     Continue from a session file
        \\  --mode <text|json>    Output mode (default: text)
        \\  --no-session          Disable session persistence
        \\  --tools <filter>      Comma-separated list of allowed tools
        \\  --append-system-prompt <text|path>  Append to system prompt (literal text or file path)
        \\  --list-models         List available models
        \\  -h, --help            Show help
        \\  -v, --version         Show version
        \\
    );
}
