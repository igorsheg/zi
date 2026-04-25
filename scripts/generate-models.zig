const std = @import("std");

const OPENAI_BASE_URL = "https://api.openai.com/v1";
const OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";

const ModelsDevSource = struct {
    key: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
};

const Model = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
    reasoning: bool,
    has_image: bool,
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
    cost_cache_write: f64,
    context_window: u64,
    max_tokens: u64,
};

const ManualModel = struct {
    id: []const u8,
    name: []const u8,
    reasoning: bool,
    has_image: bool,
    ci: f64,
    co: f64,
    cr: f64,
    cw: f64,
    ctx: u64,
    max_tok: u64,
};

const ModelList = struct {
    items: std.ArrayList(Model) = .empty,

    fn append(self: *ModelList, allocator: std.mem.Allocator, model: Model) !void {
        try self.items.append(allocator, model);
    }

    fn appendManual(
        self: *ModelList,
        allocator: std.mem.Allocator,
        manual: ManualModel,
        api: []const u8,
        provider: []const u8,
        base_url: []const u8,
    ) !void {
        try self.append(allocator, .{
            .id = manual.id,
            .name = manual.name,
            .api = api,
            .provider = provider,
            .base_url = base_url,
            .reasoning = manual.reasoning,
            .has_image = manual.has_image,
            .cost_input = manual.ci,
            .cost_output = manual.co,
            .cost_cache_read = manual.cr,
            .cost_cache_write = manual.cw,
            .context_window = manual.ctx,
            .max_tokens = manual.max_tok,
        });
    }

    fn appendManualIfMissing(
        self: *ModelList,
        allocator: std.mem.Allocator,
        provider: []const u8,
        api: []const u8,
        base_url: []const u8,
        manual: ManualModel,
    ) !void {
        if (self.find(provider, manual.id) != null) return;
        try self.appendManual(allocator, manual, api, provider, base_url);
    }

    fn find(self: *ModelList, provider: []const u8, id: []const u8) ?*Model {
        for (self.items.items) |*model| {
            if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, id)) {
                return model;
            }
        }
        return null;
    }

    fn dedupInPlace(self: *ModelList, allocator: std.mem.Allocator) !void {
        var deduped: std.ArrayList(Model) = .empty;
        for (self.items.items) |model| {
            if (findModelSlice(deduped.items, model.provider, model.id) != null) continue;
            try deduped.append(allocator, model);
        }
        self.items = deduped;
    }
};

const MODELS_DEV_SOURCES = [_]ModelsDevSource{
    .{
        .key = "anthropic",
        .api = "anthropic_messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
    },
    .{
        .key = "openai",
        .api = "openai_responses",
        .provider = "openai",
        .base_url = OPENAI_BASE_URL,
    },
};

const CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const CODEX_CTX: u64 = 272_000;
const CODEX_MAX: u64 = 128_000;

const CODEX_MODELS = [_]ManualModel{
    .{ .id = "gpt-5.1", .name = "GPT-5.1", .reasoning = true, .has_image = true, .ci = 1.25, .co = 10, .cr = 0.125, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.1-codex-max", .name = "GPT-5.1 Codex Max", .reasoning = true, .has_image = true, .ci = 1.25, .co = 10, .cr = 0.125, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.1-codex-mini", .name = "GPT-5.1 Codex Mini", .reasoning = true, .has_image = true, .ci = 0.25, .co = 2, .cr = 0.025, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.2", .name = "GPT-5.2", .reasoning = true, .has_image = true, .ci = 1.75, .co = 14, .cr = 0.175, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.2-codex", .name = "GPT-5.2 Codex", .reasoning = true, .has_image = true, .ci = 1.75, .co = 14, .cr = 0.175, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.3-codex", .name = "GPT-5.3 Codex", .reasoning = true, .has_image = true, .ci = 1.75, .co = 14, .cr = 0.175, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.4", .name = "GPT-5.4", .reasoning = true, .has_image = true, .ci = 2.5, .co = 15, .cr = 0.25, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.5", .name = "GPT-5.5", .reasoning = true, .has_image = true, .ci = 5, .co = 30, .cr = 0.5, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.4-mini", .name = "GPT-5.4 Mini", .reasoning = true, .has_image = true, .ci = 0.75, .co = 4.5, .cr = 0.075, .cw = 0, .ctx = CODEX_CTX, .max_tok = CODEX_MAX },
    .{ .id = "gpt-5.3-codex-spark", .name = "GPT-5.3 Codex Spark", .reasoning = true, .has_image = false, .ci = 0, .co = 0, .cr = 0, .cw = 0, .ctx = 128_000, .max_tok = CODEX_MAX },
};

const OPENAI_PATCHES = [_]ManualModel{
    .{ .id = "gpt-5-chat-latest", .name = "GPT-5 Chat Latest", .reasoning = false, .has_image = true, .ci = 1.25, .co = 10, .cr = 0.125, .cw = 0, .ctx = 128_000, .max_tok = 16_384 },
    .{ .id = "gpt-5.1-codex", .name = "GPT-5.1 Codex", .reasoning = true, .has_image = true, .ci = 1.25, .co = 5, .cr = 0.125, .cw = 1.25, .ctx = 400_000, .max_tok = 128_000 },
    .{ .id = "gpt-5.1-codex-max", .name = "GPT-5.1 Codex Max", .reasoning = true, .has_image = true, .ci = 1.25, .co = 10, .cr = 0.125, .cw = 0, .ctx = 400_000, .max_tok = 128_000 },
    .{ .id = "gpt-5.3-codex-spark", .name = "GPT-5.3 Codex Spark", .reasoning = true, .has_image = false, .ci = 0, .co = 0, .cr = 0, .cw = 0, .ctx = 128_000, .max_tok = 16_384 },
    .{ .id = "gpt-5.4", .name = "GPT-5.4", .reasoning = true, .has_image = true, .ci = 2.5, .co = 15, .cr = 0.25, .cw = 0, .ctx = 272_000, .max_tok = 128_000 },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    if (argv.len < 2) {
        std.debug.print("usage: {s} <output-path>\n", .{argv[0]});
        return error.InvalidArguments;
    }
    const output_path = argv[1];

    var all: ModelList = .{};

    std.debug.print("Fetching models.dev/api.json...\n", .{});
    const models_dev_body = try fetch(allocator, "https://models.dev/api.json");
    std.debug.print("  {d} bytes\n", .{models_dev_body.len});
    const models_dev_json = try std.json.parseFromSlice(std.json.Value, allocator, models_dev_body, .{});
    const dev_count_before = all.items.items.len;
    try collectModelsDev(allocator, models_dev_json.value, &all);
    std.debug.print("  {d} tool-capable models from models.dev (anthropic+openai)\n", .{all.items.items.len - dev_count_before});

    std.debug.print("Fetching openrouter.ai/api/v1/models...\n", .{});
    const openrouter_body = try fetch(allocator, "https://openrouter.ai/api/v1/models");
    std.debug.print("  {d} bytes\n", .{openrouter_body.len});
    const openrouter_json = try std.json.parseFromSlice(std.json.Value, allocator, openrouter_body, .{});
    const openrouter_count_before = all.items.items.len;
    try collectOpenRouter(allocator, openrouter_json.value, &all);
    std.debug.print("  {d} tool-capable models from openrouter\n", .{all.items.items.len - openrouter_count_before});

    const codex_count_before = all.items.items.len;
    try collectCodex(allocator, &all);
    std.debug.print("Hand-coded codex block: {d} models\n", .{all.items.items.len - codex_count_before});

    applyPatches(allocator, &all) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    try all.dedupInPlace(allocator);
    std.sort.pdq(Model, all.items.items, {}, lessThanModel);

    std.debug.print("\nFinal per-provider counts:\n", .{});
    try printCounts(allocator, all.items.items);

    try writeOutput(output_path, all.items.items);
    std.debug.print("Wrote {s}\n", .{output_path});
}

fn fetch(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sS", url },
        .max_output_bytes = 32 * 1024 * 1024,
    });

    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0) {
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) std.debug.print("curl failed: {s}\n", .{stderr_trimmed});
        return error.FetchFailed;
    }
    return result.stdout;
}

fn collectModelsDev(allocator: std.mem.Allocator, root: std.json.Value, all: *ModelList) !void {
    for (MODELS_DEV_SOURCES) |src| {
        const section = getField(root, src.key) orelse continue;
        const models = getField(section, "models") orelse continue;
        if (models != .object) continue;

        var it = models.object.iterator();
        while (it.next()) |entry| {
            const model_id = entry.key_ptr.*;
            const model = entry.value_ptr.*;
            if (!boolField(model, "tool_call")) continue;

            try all.append(allocator, .{
                .id = model_id,
                .name = stringField(model, "name") orelse model_id,
                .api = src.api,
                .provider = src.provider,
                .base_url = src.base_url,
                .reasoning = boolField(model, "reasoning"),
                .has_image = hasImage(model),
                .cost_input = numberPath(model, &.{ "cost", "input" }) orelse 0,
                .cost_output = numberPath(model, &.{ "cost", "output" }) orelse 0,
                .cost_cache_read = numberPath(model, &.{ "cost", "cache_read" }) orelse 0,
                .cost_cache_write = numberPath(model, &.{ "cost", "cache_write" }) orelse 0,
                .context_window = u64Path(model, &.{ "limit", "context" }) orelse 4096,
                .max_tokens = u64Path(model, &.{ "limit", "output" }) orelse 4096,
            });
        }
    }
}

fn collectOpenRouter(allocator: std.mem.Allocator, root: std.json.Value, all: *ModelList) !void {
    const data = getField(root, "data") orelse return;
    if (data != .array) return;

    for (data.array.items) |model| {
        if (!containsStringArray(getField(model, "supported_parameters"), "tools")) continue;

        const architecture = getField(model, "architecture");
        const input_has_image = blk: {
            if (containsStringArray(valueField(architecture, "input_modalities"), "image")) break :blk true;
            if (stringFieldOpt(valueField(architecture, "modality"))) |modality| {
                if (std.mem.indexOf(u8, modality, "image") != null) break :blk true;
            }
            break :blk false;
        };

        var context_window = u64Field(model, "context_length") orelse 4096;
        if (context_window == 0) context_window = 4096;

        var max_tokens: u64 = 4096;
        if (valueField(getField(model, "top_provider"), "max_completion_tokens")) |value| {
            if (toU64(value)) |n| {
                if (n > 0) max_tokens = n;
            }
        }

        try all.append(allocator, .{
            .id = stringField(model, "id") orelse continue,
            .name = stringField(model, "name") orelse stringField(model, "id") orelse continue,
            .api = "openai_completions",
            .provider = "openrouter",
            .base_url = OPENROUTER_BASE_URL,
            .reasoning = containsStringArray(getField(model, "supported_parameters"), "reasoning"),
            .has_image = input_has_image,
            .cost_input = (numberPath(model, &.{ "pricing", "prompt" }) orelse 0) * 1_000_000,
            .cost_output = (numberPath(model, &.{ "pricing", "completion" }) orelse 0) * 1_000_000,
            .cost_cache_read = (numberPath(model, &.{ "pricing", "input_cache_read" }) orelse 0) * 1_000_000,
            .cost_cache_write = (numberPath(model, &.{ "pricing", "input_cache_write" }) orelse 0) * 1_000_000,
            .context_window = context_window,
            .max_tokens = max_tokens,
        });
    }
}

fn collectCodex(allocator: std.mem.Allocator, all: *ModelList) !void {
    for (CODEX_MODELS) |model| {
        try all.appendManual(allocator, model, "openai_codex_responses", "openai_codex", CODEX_BASE_URL);
    }
}

fn applyPatches(allocator: std.mem.Allocator, all: *ModelList) !void {
    if (all.find("anthropic", "claude-opus-4-5")) |model| {
        model.cost_cache_read = 0.5;
        model.cost_cache_write = 6.25;
    }

    for (all.items.items) |*model| {
        if (std.mem.eql(u8, model.provider, "anthropic") and
            (std.mem.eql(u8, model.id, "claude-opus-4-6") or std.mem.eql(u8, model.id, "claude-sonnet-4-6")))
        {
            model.context_window = 1_000_000;
        }
        if (std.mem.eql(u8, model.provider, "openai") and std.mem.eql(u8, model.id, "gpt-5.4")) {
            model.context_window = 272_000;
            model.max_tokens = 128_000;
        }
        if (std.mem.eql(u8, model.provider, "openrouter") and std.mem.eql(u8, model.id, "moonshotai/kimi-k2.5")) {
            model.cost_input = 0.41;
            model.cost_output = 2.06;
            model.cost_cache_read = 0.07;
            model.max_tokens = 4096;
        }
    }

    try all.appendManualIfMissing(allocator, "anthropic", "anthropic_messages", "https://api.anthropic.com", .{
        .id = "claude-opus-4-6",
        .name = "Claude Opus 4.6",
        .reasoning = true,
        .has_image = true,
        .ci = 5,
        .co = 25,
        .cr = 0.5,
        .cw = 6.25,
        .ctx = 1_000_000,
        .max_tok = 128_000,
    });

    try all.appendManualIfMissing(allocator, "anthropic", "anthropic_messages", "https://api.anthropic.com", .{
        .id = "claude-sonnet-4-6",
        .name = "Claude Sonnet 4.6",
        .reasoning = true,
        .has_image = true,
        .ci = 3,
        .co = 15,
        .cr = 0.3,
        .cw = 3.75,
        .ctx = 1_000_000,
        .max_tok = 64_000,
    });

    for (OPENAI_PATCHES) |patch| {
        try all.appendManualIfMissing(allocator, "openai", "openai_responses", OPENAI_BASE_URL, patch);
    }

    if (all.find("openrouter", "auto") == null) {
        try all.append(allocator, .{
            .id = "auto",
            .name = "Auto",
            .api = "openai_completions",
            .provider = "openrouter",
            .base_url = OPENROUTER_BASE_URL,
            .reasoning = true,
            .has_image = true,
            .cost_input = 0,
            .cost_output = 0,
            .cost_cache_read = 0,
            .cost_cache_write = 0,
            .context_window = 2_000_000,
            .max_tokens = 30_000,
        });
    }
}

fn printCounts(allocator: std.mem.Allocator, models: []const Model) !void {
    var providers: std.ArrayList([]const u8) = .empty;
    defer providers.deinit(allocator);

    for (models) |model| {
        if (!containsStringSlice(providers.items, model.provider)) {
            try providers.append(allocator, model.provider);
        }
    }
    std.sort.pdq([]const u8, providers.items, {}, lessThanString);

    for (providers.items) |provider| {
        std.debug.print("  {s:<20} {d}\n", .{ provider, countForProvider(models, provider) });
    }
    std.debug.print("  {s:<20} {d}\n", .{ "TOTAL", models.len });
}

fn writeOutput(output_path: []const u8, models: []const Model) !void {
    const file = try std.fs.createFileAbsolute(output_path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);
    const w = &file_writer.interface;

    try w.writeAll("// Auto-generated by scripts/generate-models.zig\n");
    try w.writeAll("// Do not edit manually — generated by `zig build generate-models`.\n");
    try w.print("// Models: {d}\n\n", .{models.len});
    try w.writeAll("const protocol = @import(\"protocol.zig\");\n\n");
    try w.writeAll("pub const models = [_]protocol.Model{\n");

    for (models) |model| {
        try w.writeAll("    .{\n");
        try w.print("        .id = \"{f}\",\n", .{std.zig.fmtString(model.id)});
        try w.print("        .name = \"{f}\",\n", .{std.zig.fmtString(model.name)});
        try w.print("        .api = .{s},\n", .{model.api});
        try w.print("        .provider = .{s},\n", .{model.provider});
        try w.print("        .base_url = \"{s}\",\n", .{model.base_url});
        try w.print("        .reasoning = {},\n", .{model.reasoning});
        if (model.has_image) {
            try w.writeAll("        .input = &.{ .text, .image },\n");
        } else {
            try w.writeAll("        .input = &.{ .text },\n");
        }
        try w.writeAll("        .cost = .{ .input = ");
        try writeNumber(w, model.cost_input);
        try w.writeAll(", .output = ");
        try writeNumber(w, model.cost_output);
        try w.writeAll(", .cache_read = ");
        try writeNumber(w, model.cost_cache_read);
        try w.writeAll(", .cache_write = ");
        try writeNumber(w, model.cost_cache_write);
        try w.writeAll(" },\n");
        try w.print("        .context_window = {d},\n", .{model.context_window});
        try w.print("        .max_tokens = {d},\n", .{model.max_tokens});
        try w.writeAll("    },\n");
    }

    try w.writeAll("};\n");
    try w.flush();
}

fn writeNumber(w: *std.Io.Writer, value: f64) !void {
    if (!std.math.isFinite(value) or value == 0) {
        try w.writeAll("0");
        return;
    }

    const rounded = @round(value);
    if (rounded == value and @abs(value) < 1e15) {
        try w.print("{d:.0}", .{value});
        return;
    }

    var buf: [64]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "{d:.10}", .{value});
    const trimmed = trimTrailingZeros(full);
    try w.writeAll(trimmed);
}

fn trimTrailingZeros(full: []const u8) []const u8 {
    var end = full.len;
    while (end > 0 and full[end - 1] == '0') : (end -= 1) {}
    if (end > 0 and full[end - 1] == '.') end -= 1;
    return full[0..end];
}

fn findModelSlice(models: []const Model, provider: []const u8, id: []const u8) ?usize {
    for (models, 0..) |model, i| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, id)) {
            return i;
        }
    }
    return null;
}

fn countForProvider(models: []const Model, provider: []const u8) usize {
    var count: usize = 0;
    for (models) |model| {
        if (std.mem.eql(u8, model.provider, provider)) count += 1;
    }
    return count;
}

fn lessThanModel(_: void, a: Model, b: Model) bool {
    return switch (std.mem.order(u8, a.provider, b.provider)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.id, b.id),
    };
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn valueField(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const v = value orelse return null;
    return getField(v, key);
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return stringFieldOpt(getField(value, key));
}

fn stringFieldOpt(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) bool {
    const v = getField(value, key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn u64Field(value: std.json.Value, key: []const u8) ?u64 {
    return toU64(getField(value, key) orelse return null);
}

fn numberPath(value: std.json.Value, path: []const []const u8) ?f64 {
    var current = value;
    for (path) |segment| {
        current = getField(current, segment) orelse return null;
    }
    return toNumber(current);
}

fn u64Path(value: std.json.Value, path: []const []const u8) ?u64 {
    var current = value;
    for (path) |segment| {
        current = getField(current, segment) orelse return null;
    }
    return toU64(current);
}

fn toNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| if (std.math.isFinite(n)) n else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn toU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (std.math.isFinite(n) and n >= 0) @intFromFloat(n) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn hasImage(model: std.json.Value) bool {
    return containsStringArray(valueField(getField(model, "modalities"), "input"), "image");
}

fn containsStringArray(value: ?std.json.Value, needle: []const u8) bool {
    const v = value orelse return false;
    if (v != .array) return false;
    for (v.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

fn containsStringSlice(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
