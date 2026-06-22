//! Symbol map for Zig source files using the toolchain's own `std.zig.Ast`.
//! Zero external dependencies: lists functions, tests, and top-level/nested
//! const/var declarations with 1-based line numbers so the agent can navigate
//! a large file without re-reading it whole.

const std = @import("std");
const agent = @import("../../agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const path_utils = @import("path_utils.zig");
const paths_mod = @import("../paths.zig");
const tool_output_policy = @import("../tool_output_policy.zig");
const test_support = @import("test_support.zig");

pub const max_read_bytes = 1024 * 1024;
pub const max_output_bytes = tool_output_policy.default_max_bytes;
pub const max_output_lines = tool_output_policy.default_max_lines;

const parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Path to a Zig source file (relative or absolute)" }
    \\  },
    \\  "required": ["path"]
    \\}
;

pub const SymbolsTool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    parsed_parameters: runtime.JsonOwned(std.json.Value),

    pub const Config = struct {
        cwd: []const u8,
        home_dir: ?[]const u8 = null,
        allow_paths_outside_cwd: bool = false,
        max_read_bytes: usize = max_read_bytes,
        max_output_bytes: usize = max_output_bytes,
        max_output_lines: usize = max_output_lines,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !SymbolsTool {
        const cwd = try allocator.dupe(u8, config.cwd);
        errdefer allocator.free(cwd);
        const home_dir = if (config.home_dir) |path| try allocator.dupe(u8, path) else null;
        errdefer if (home_dir) |path| allocator.free(path);
        const parsed_parameters = try runtime.JsonOwned(std.json.Value).parseJson(allocator, parameters_schema, .{});
        var owned_config = config;
        owned_config.cwd = cwd;
        owned_config.home_dir = home_dir;
        return .{
            .allocator = allocator,
            .config = owned_config,
            .parsed_parameters = parsed_parameters,
        };
    }

    pub fn deinit(self: *SymbolsTool) void {
        self.allocator.free(self.config.cwd);
        if (self.config.home_dir) |path| self.allocator.free(path);
        self.parsed_parameters.deinit();
        self.* = undefined;
    }

    pub fn tool(self: *SymbolsTool) agent.AgentTool {
        return .{
            .name = "symbols",
            .description = "List declarations in a Zig source file with line numbers: " ++
                "functions, tests, and const/var bindings. Uses the Zig parser, so the " ++
                "file must be syntactically valid Zig. Use this to navigate large files " ++
                "before reading a specific region with offset/limit.",
            .parameters = self.parsed_parameters.value,
            .label = "symbols",
            .execute = .{ .context = self, .call_fn = execute },
        };
    }
};

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *agent.ToolRuntime,
    context: ?*anyopaque,
    token: runtime.CancelToken,
    _: []const u8,
    params: std.json.Value,
    _: ?agent.AgentToolUpdateCallback,
) anyerror!agent.ToolExecutionResult {
    try token.throwIfRequested();
    const self: *SymbolsTool = @ptrCast(@alignCast(context orelse return error.MissingToolContext));
    const path = parsePath(params) catch return path_utils.errorResult(
        allocator,
        "invalid_arguments",
        "Invalid symbols arguments: provide a path string.",
    );
    const resolved_path = paths_mod.ToolPaths.resolveExisting(allocator, io, .{
        .cwd = self.config.cwd,
        .allow_paths_outside_cwd = self.config.allow_paths_outside_cwd,
        .home_dir = self.config.home_dir,
    }, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidToolArguments, error.PathOutsideCwd => return path_utils.errorResultWithPathFmt(
            allocator,
            "Invalid symbols path {s}: {s}",
            "invalid_path",
            path,
            err,
            .{ path, @errorName(err) },
        ),
        else => return path_utils.errorResultWithPathFmt(
            allocator,
            "Symbols path resolution failed for {s}: {s}",
            "path_error",
            path,
            err,
            .{ path, @errorName(err) },
        ),
    };
    defer allocator.free(resolved_path);

    if (!std.mem.endsWith(u8, resolved_path, ".zig")) {
        return path_utils.errorResultFmt(
            allocator,
            "Symbols tool only supports .zig files: {s}",
            "unsupported_extension",
            .{path},
        );
    }

    const content = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        resolved_path,
        allocator,
        .limited(self.config.max_read_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileTooBig, error.StreamTooLong => return readTooLargeResult(allocator, self.config.max_read_bytes),
        else => return path_utils.errorResultWithPathFmt(
            allocator,
            "Symbols failed to read {s}: {s}",
            "read_failed",
            path,
            err,
            .{ path, @errorName(err) },
        ),
    };
    defer allocator.free(content);
    try token.throwIfRequested();
    if (!std.unicode.utf8ValidateSlice(content)) {
        return path_utils.errorResultFmt(
            allocator,
            "Symbols failed: {s} is not valid UTF-8 text.",
            "non_utf8_file",
            .{path},
        );
    }

    // std.zig.Ast.parse requires a sentinel-terminated source.
    const sentinel_source = try allocator.allocSentinel(u8, content.len, 0);
    defer allocator.free(sentinel_source);
    @memcpy(sentinel_source[0..content.len], content);

    var tree = std.zig.Ast.parse(allocator, sentinel_source, .zig) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        var msg_writer: std.Io.Writer.Allocating = .init(allocator);
        defer msg_writer.deinit();
        tree.renderError(tree.errors[0], &msg_writer.writer) catch return error.OutOfMemory;
        const msg = try allocator.dupe(u8, msg_writer.written());
        defer allocator.free(msg);
        return path_utils.errorResultFmt(
            allocator,
            "Symbols failed: {s} has a parse error: {s}",
            "parse_error",
            .{ path, msg },
        );
    }

    return renderSymbols(allocator, self.config, path, &tree);
}

fn parsePath(params: std.json.Value) ![]const u8 {
    if (params != .object) return error.InvalidToolArguments;
    const path_value = params.object.get("path") orelse params.object.get("file_path") orelse
        return error.InvalidToolArguments;
    if (path_value != .string or path_value.string.len == 0) return error.InvalidToolArguments;
    return path_value.string;
}

fn readTooLargeResult(allocator: std.mem.Allocator, max_bytes: usize) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "Symbols failed: file exceeds the {d} byte read limit.",
        .{max_bytes},
    );
    errdefer allocator.free(message);
    const details = try path_utils.jsonDetails(allocator, .{
        .isError = true,
        .reason = @as([]const u8, "file_too_large"),
        .maxBytes = max_bytes,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, message, details);
}

const Symbol = struct {
    kind: []const u8, // "fn" | "test" | "const" | "var"
    name: []const u8, // borrowed from tree.tokenSlice; lifetime == tree
    line: usize, // 1-based
};

fn collectSymbols(allocator: std.mem.Allocator, tree: *const std.zig.Ast) ![]Symbol {
    var list: std.ArrayList(Symbol) = .empty;
    errdefer list.deinit(allocator);

    const tags = tree.nodes.items(.tag);
    // Node 0 is root; iterate every node so nested decls are included.
    for (tags, 0..) |tag, raw| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw);
        switch (tag) {
            .fn_decl => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buf, node) orelse continue;
                const name_tok = proto.name_token orelse continue;
                try list.append(allocator, .{
                    .kind = "fn",
                    .name = tree.tokenSlice(name_tok),
                    .line = lineOf(tree, name_tok),
                });
            },
            .test_decl => {
                const opt_tok = tree.nodeData(node).opt_token_and_node[0];
                if (opt_tok.unwrap()) |name_tok| {
                    try list.append(allocator, .{
                        .kind = "test",
                        .name = stripStringQuotes(tree.tokenSlice(name_tok)),
                        .line = lineOf(tree, name_tok),
                    });
                } else {
                    // Unnamed `test {}`: anchor on the `test` keyword token.
                    const kw_tok = tree.nodeMainToken(node);
                    try list.append(allocator, .{
                        .kind = "test",
                        .name = "",
                        .line = lineOf(tree, kw_tok),
                    });
                }
            },
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => {
                const decl = tree.fullVarDecl(node) orelse continue;
                // mut_token is the `const`/`var` keyword; the name identifier follows it.
                const name_tok = decl.ast.mut_token + 1;
                const kind: []const u8 = blk: {
                    const mut_slice = tree.tokenSlice(decl.ast.mut_token);
                    break :blk if (std.mem.eql(u8, mut_slice, "var")) "var" else "const";
                };
                try list.append(allocator, .{
                    .kind = kind,
                    .name = tree.tokenSlice(name_tok),
                    .line = lineOf(tree, name_tok),
                });
            },
            else => {},
        }
    }
    return list.toOwnedSlice(allocator);
}

// ponytail: O(symbols * file) per call via tokenLocation scanning from offset 0.
// Fine for a navigation tool (sub-ms on a 3k-line file); upgrade to an
// incremental newline index if a profile shows it on a hot path.
fn lineOf(tree: *const std.zig.Ast, tok: std.zig.Ast.TokenIndex) usize {
    return tree.tokenLocation(0, tok).line + 1;
}

/// Strips one leading and trailing `"` from a string-literal token slice.
/// Zig string literals have no embedded unescaped quotes, so this is exact.
fn stripStringQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn renderSymbols(
    allocator: std.mem.Allocator,
    config: SymbolsTool.Config,
    path: []const u8,
    tree: *const std.zig.Ast,
) !agent.ToolExecutionResult {
    const symbols = try collectSymbols(allocator, tree);
    defer allocator.free(symbols);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    var emitted: usize = 0;
    var truncated_lines = false;
    for (symbols) |sym| {
        if (emitted == config.max_output_lines) {
            truncated_lines = true;
            break;
        }
        try writer.writer.print("{d}\t{s}\t{s}\n", .{ sym.line, sym.kind, sym.name });
        emitted += 1;
    }

    var text = try writer.toOwnedSlice();
    var truncated_bytes = false;
    if (text.len > config.max_output_bytes) {
        text = text[0..config.max_output_bytes];
        truncated_bytes = true;
    }

    const details = try path_utils.jsonDetails(allocator, .{
        .path = path,
        .symbolCount = symbols.len,
        .outputSymbols = emitted,
        .truncated = truncated_lines or truncated_bytes,
        .totalSymbols = symbols.len,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return path_utils.ownedTextResult(allocator, text, details);
}

test "symbols tool lists functions tests and consts with line numbers" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.zig",
        \\const std = @import("std");
        \\
        \\const count: u32 = 3;
        \\
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\
        \\test "add works" {
        \\    try std.testing.expectEqual(@as(u32, 5), add(2, 3));
        \\}
        \\
        \\var total: u32 = 0;
    );

    var symbols_tool = try SymbolsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer symbols_tool.deinit();

    var result = try test_support.execute(symbols_tool.tool(), "{\"path\":\"file.zig\"}");
    defer result.deinit();

    const text = result.result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "1\tconst\tstd") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3\tconst\tcount") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5\tfn\tadd") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "9\ttest\tadd works") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "13\tvar\ttotal") != null);
    const details = result.result.details.?.object;
    try std.testing.expectEqual(@as(i64, 5), details.get("symbolCount").?.integer);
    try std.testing.expect(!details.get("truncated").?.bool);
}

test "symbols tool rejects non-zig files operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.txt", "not zig");

    var symbols_tool = try SymbolsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer symbols_tool.deinit();

    var result = try test_support.execute(symbols_tool.tool(), "{\"path\":\"file.txt\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("unsupported_extension", result.result.details.?.object.get("reason").?.string);
}

test "symbols tool reports parse errors without crashing" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/bad.zig", "pub fn add( a: u32) u32 {\n  return a\n}\n"); // missing comma/semi

    var symbols_tool = try SymbolsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer symbols_tool.deinit();

    var result = try test_support.execute(symbols_tool.tool(), "{\"path\":\"bad.zig\"}");
    defer result.deinit();

    try std.testing.expectEqualStrings("parse_error", result.result.details.?.object.get("reason").?.string);
}

test "symbols tool reports missing file operationally" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();

    var symbols_tool = try SymbolsTool.init(std.testing.allocator, .{
        .cwd = fixture.cwd(),
        .allow_paths_outside_cwd = true,
    });
    defer symbols_tool.deinit();

    var result = try test_support.execute(symbols_tool.tool(), "{\"path\":\"missing.zig\"}");
    defer result.deinit();

    const details = result.result.details.?.object;
    try std.testing.expect(details.get("isError").?.bool);
    try std.testing.expectEqualStrings("read_failed", details.get("reason").?.string);
}

test "symbols tool lists unnamed tests" {
    var fixture = try test_support.Fixture.init("repo");
    defer fixture.deinit();
    try fixture.write("repo/file.zig",
        \\test {}
        \\test "named" {}
    );

    var symbols_tool = try SymbolsTool.init(std.testing.allocator, .{ .cwd = fixture.cwd() });
    defer symbols_tool.deinit();

    var result = try test_support.execute(symbols_tool.tool(), "{\"path\":\"file.zig\"}");
    defer result.deinit();

    const text = result.result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "1\ttest\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2\ttest\tnamed") != null);
}
