const std = @import("std");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../root.zig");
const auth = @import("../auth/root.zig");
const search = @import("../../search/plain.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const plan = @import("plan.zig");

const stdout: std.Io.File = .{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
const Model = ai.protocol.Model;

const ColumnWidths = struct {
    provider: usize = "provider".len,
    model: usize = "model".len,
    context: usize = "context".len,
    max_out: usize = "max-out".len,
    thinking: usize = "thinking".len,
    images: usize = "images".len,
};

pub fn run(
    allocator: std.mem.Allocator,
    runtime: *runtime_mod.Runtime,
    options: plan.ListModelsPlan,
) !result.ExecutionResult {
    var out_buf: [4096]u8 = undefined;
    var out_writer = stdout.writer(std.Options.debug_io, &out_buf);
    try writeListModels(&out_writer.interface, allocator, runtime, options);
    try out_writer.end();
    return .ok;
}

fn writeListModels(
    writer: anytype,
    allocator: std.mem.Allocator,
    runtime: *runtime_mod.Runtime,
    options: plan.ListModelsPlan,
) !void {
    const available = try runtime.model_registry.getAvailable(allocator);
    defer allocator.free(available);

    if (available.len == 0) {
        try writer.writeAll("No models available. Set API keys in environment variables.\n");
        return;
    }

    var to_print = available;
    var owns_to_print = false;
    defer if (owns_to_print) allocator.free(to_print);

    if (options.search) |pattern| {
        to_print = try filterModels(allocator, available, pattern);
        owns_to_print = true;

        if (to_print.len == 0) {
            try writer.print("No models matching \"{s}\"\n", .{pattern});
            return;
        }
    }

    std.mem.sort(Model, to_print, {}, modelLessThan);
    try writeModelTable(writer, to_print);
}

fn filterModels(allocator: std.mem.Allocator, models: []const Model, pattern: []const u8) ![]Model {
    var search_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (search_keys.items) |key| allocator.free(key);
        search_keys.deinit(allocator);
    }

    try search_keys.ensureTotalCapacity(allocator, models.len);
    for (models) |model| {
        const provider = ai.json_util.providerToString(model.provider);
        const key = try std.fmt.allocPrint(allocator, "{s} {s}", .{ provider, model.id });
        search_keys.appendAssumeCapacity(key);
    }

    const matched_indices = try allocator.alloc(usize, models.len);
    defer allocator.free(matched_indices);

    const match_count = search.fuzzyFilter(pattern, search_keys.items, matched_indices);
    const filtered = try allocator.alloc(Model, match_count);
    for (matched_indices[0..match_count], 0..) |model_index, out_index| {
        filtered[out_index] = models[model_index];
    }
    return filtered;
}

fn writeModelTable(writer: anytype, models: []const Model) !void {
    var widths: ColumnWidths = .{};

    for (models) |model| {
        const provider = ai.json_util.providerToString(model.provider);
        widths.provider = @max(widths.provider, provider.len);
        widths.model = @max(widths.model, model.id.len);

        var context_buf: [32]u8 = undefined;
        const context = try formatTokenCount(model.context_window, &context_buf);
        widths.context = @max(widths.context, context.len);

        var max_out_buf: [32]u8 = undefined;
        const max_out = try formatTokenCount(model.max_tokens, &max_out_buf);
        widths.max_out = @max(widths.max_out, max_out.len);
    }

    try writeRow(writer, widths, .{
        .provider = "provider",
        .model = "model",
        .context = "context",
        .max_out = "max-out",
        .thinking = "thinking",
        .images = "images",
    });

    for (models) |model| {
        var context_buf: [32]u8 = undefined;
        var max_out_buf: [32]u8 = undefined;
        try writeRow(writer, widths, .{
            .provider = ai.json_util.providerToString(model.provider),
            .model = model.id,
            .context = try formatTokenCount(model.context_window, &context_buf),
            .max_out = try formatTokenCount(model.max_tokens, &max_out_buf),
            .thinking = if (model.reasoning) "yes" else "no",
            .images = if (hasImageInput(model)) "yes" else "no",
        });
    }
}

const Row = struct {
    provider: []const u8,
    model: []const u8,
    context: []const u8,
    max_out: []const u8,
    thinking: []const u8,
    images: []const u8,
};

fn writeRow(writer: anytype, widths: ColumnWidths, row: Row) !void {
    try writePadded(writer, row.provider, widths.provider);
    try writer.writeAll("  ");
    try writePadded(writer, row.model, widths.model);
    try writer.writeAll("  ");
    try writePadded(writer, row.context, widths.context);
    try writer.writeAll("  ");
    try writePadded(writer, row.max_out, widths.max_out);
    try writer.writeAll("  ");
    try writePadded(writer, row.thinking, widths.thinking);
    try writer.writeAll("  ");
    try writePadded(writer, row.images, widths.images);
    try writer.writeAll("\n");
}

fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    try writeSpaces(writer, width - text.len);
}

fn writeSpaces(writer: anytype, count: usize) !void {
    const spaces = "                                ";
    var remaining = count;
    while (remaining > 0) {
        const to_write = @min(remaining, spaces.len);
        try writer.writeAll(spaces[0..to_write]);
        remaining -= to_write;
    }
}

fn formatTokenCount(count: u64, buf: *[32]u8) ![]const u8 {
    if (count >= 1_000_000) {
        const tenths = @divFloor(count + 50_000, 100_000);
        const whole = tenths / 10;
        const fraction = tenths % 10;
        if (fraction == 0) return std.fmt.bufPrint(buf, "{d}M", .{whole});
        return std.fmt.bufPrint(buf, "{d}.{d}M", .{ whole, fraction });
    }
    if (count >= 1_000) {
        const tenths = @divFloor(count + 50, 100);
        const whole = tenths / 10;
        const fraction = tenths % 10;
        if (fraction == 0) return std.fmt.bufPrint(buf, "{d}K", .{whole});
        return std.fmt.bufPrint(buf, "{d}.{d}K", .{ whole, fraction });
    }
    return std.fmt.bufPrint(buf, "{d}", .{count});
}

fn hasImageInput(model: Model) bool {
    for (model.input) |input| {
        if (input == .image) return true;
    }
    return false;
}

fn modelLessThan(_: void, a: Model, b: Model) bool {
    const provider_a = ai.json_util.providerToString(a.provider);
    const provider_b = ai.json_util.providerToString(b.provider);
    return switch (std.mem.order(u8, provider_a, provider_b)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.id, b.id),
    };
}

const TestRuntime = struct {
    allocator: std.mem.Allocator,
    auth_storage: auth.storage.AuthStorage,
    registry: coding_agent.ModelRegistry,

    fn init(
        allocator: std.mem.Allocator,
        custom_models: []const Model,
        configured_providers: []const []const u8,
    ) !TestRuntime {
        var auth_storage = try auth.storage.AuthStorage.create(allocator, null);
        errdefer auth_storage.deinit();
        for (configured_providers) |provider| {
            auth_storage.setRuntimeApiKey(provider, "test-key");
        }

        var registry = try coding_agent.ModelRegistry.init(allocator, &auth_storage, custom_models);
        errdefer registry.deinit();

        return .{
            .allocator = allocator,
            .auth_storage = auth_storage,
            .registry = registry,
        };
    }

    fn deinit(self: *TestRuntime) void {
        self.registry.deinit();
        self.auth_storage.deinit();
        self.* = undefined;
    }

    fn runtime(self: *TestRuntime) runtime_mod.Runtime {
        return .{
            .allocator = self.allocator,
            .io = std.Options.debug_io,
            .cwd = "/test",
            .auth_storage = &self.auth_storage,
            .settings_manager = undefined,
            .model_registry = &self.registry,
        };
    }
};

fn customModel(
    id: []const u8,
    provider: []const u8,
    reasoning: bool,
    input: []const Model.InputType,
    context_window: u64,
    max_tokens: u64,
) Model {
    return .{
        .id = id,
        .name = id,
        .api = .openai_completions,
        .provider = .{ .custom = provider },
        .base_url = "https://example.com",
        .reasoning = reasoning,
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = context_window,
        .max_tokens = max_tokens,
    };
}

test "list-models renders available model table and applies fuzzy search" {
    const alloc = std.testing.allocator;
    const models = [_]Model{
        customModel("alpha-coder", "alpha", true, &.{ .text, .image }, 200_000, 8_000),
        customModel("beta-chat", "beta", false, &.{.text}, 1_500_000, 32_000),
    };

    var fixture = try TestRuntime.init(alloc, &models, &.{ "alpha", "beta" });
    defer fixture.deinit();
    var runtime = fixture.runtime();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeListModels(&out.writer, alloc, &runtime, .{});
    const rendered = try out.toOwnedSlice();
    defer alloc.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "alpha  alpha-coder") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "beta   beta-chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "200K") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1.5M") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "yes       yes") != null);

    var search_out: std.Io.Writer.Allocating = .init(alloc);
    defer search_out.deinit();

    try writeListModels(&search_out.writer, alloc, &runtime, .{ .search = "alpha" });
    const filtered = try search_out.toOwnedSlice();
    defer alloc.free(filtered);

    try std.testing.expect(std.mem.indexOf(u8, filtered, "alpha-coder") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "beta-chat") == null);
}

test "list-models prints friendly empty states for unavailable and unmatched searches" {
    const alloc = std.testing.allocator;
    const models = [_]Model{customModel("alpha-coder", "alpha", false, &.{.text}, 8_000, 4_000)};

    var no_auth_fixture = try TestRuntime.init(alloc, &models, &.{});
    defer no_auth_fixture.deinit();
    var no_auth_runtime = no_auth_fixture.runtime();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeListModels(&out.writer, alloc, &no_auth_runtime, .{});
    const unavailable = try out.toOwnedSlice();
    defer alloc.free(unavailable);

    try std.testing.expectEqualStrings(
        "No models available. Set API keys in environment variables.\n",
        unavailable,
    );

    var auth_fixture = try TestRuntime.init(alloc, &models, &.{"alpha"});
    defer auth_fixture.deinit();
    var auth_runtime = auth_fixture.runtime();

    var miss_out: std.Io.Writer.Allocating = .init(alloc);
    defer miss_out.deinit();

    try writeListModels(&miss_out.writer, alloc, &auth_runtime, .{ .search = "gamma" });
    const unmatched = try miss_out.toOwnedSlice();
    defer alloc.free(unmatched);

    try std.testing.expectEqualStrings("No models matching \"gamma\"\n", unmatched);
}
