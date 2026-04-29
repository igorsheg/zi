const std = @import("std");
const ai = @import("../../ai/root.zig");
const protocol = @import("../../agent3/types.zig");
const ai_completion = @import("../ai_completion.zig");
const ai_complete_worker_mod = @import("../extensions/ai_complete_worker.zig");
const extension_runner_mod = @import("../extensions/runner.zig");

pub fn buildWorkerRequest(
    self: anytype,
    allocator: std.mem.Allocator,
    id: extension_runner_mod.AsyncOpId,
    request: extension_runner_mod.AiCompleteRequest,
) !ai_complete_worker_mod.Request {
    const current_model = resolveExtensionAiModel(self, request.model) orelse return error.ModelUnavailable;
    const provider = self._stream_closure.registry.getForModel(
        ai.provider.apiToString(current_model.api),
        ai.json_util.providerToString(current_model.provider),
    ) orelse return error.ProviderUnavailable;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const api_key = self._stream_closure.resolveApiKey(arena.allocator(), current_model);
    var built = ai_complete_worker_mod.Request{
        .id = id,
        .provider = provider,
        .model = current_model,
        .prompt = try allocator.dupe(u8, request.prompt),
        .system_prompt = null,
        .api_key = null,
        .headers = null,
        .max_tokens = request.max_tokens,
        .reasoning = resolveReasoning(current_model, request.reasoning),
    };
    errdefer built.deinit(allocator);
    if (request.system_prompt) |value| built.system_prompt = try allocator.dupe(u8, value);
    if (api_key.len > 0) built.api_key = try allocator.dupe(u8, api_key);
    built.headers = try self._stream_closure.mergeClaimHeaders(current_model, allocator, null);
    return built;
}

fn resolveReasoning(model: ai.protocol.Model, override: ?protocol.ThinkingLevel) ?ai.protocol.ThinkingLevel {
    if (!model.reasoning) return null;
    const level = override orelse return .high;
    return switch (level) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn resolveExtensionAiModel(self: anytype, model_ref: ?[]const u8) ?ai.protocol.Model {
    const value = model_ref orelse return self.agent.modelValue();
    return self.resolveModelRef(value);
}

pub fn completeUserText(
    self: anytype,
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    prompt_text: []const u8,
    max_tokens: u64,
) ![]u8 {
    const current_model = self.agent.modelValue();
    const provider = self._stream_closure.registry.getForModel(
        ai.provider.apiToString(current_model.api),
        ai.json_util.providerToString(current_model.provider),
    ) orelse return error.ProviderUnavailable;

    const api_key = self._stream_closure.resolveApiKey(allocator, current_model);
    const result = ai_completion.runPreparedTextCompletion(allocator, .{
        .provider = provider,
        .model = current_model,
        .prompt = prompt_text,
        .system_prompt = system_prompt,
        .api_key = if (api_key.len > 0) api_key else null,
        .max_tokens = max_tokens,
        .reasoning = if (current_model.reasoning) .high else null,
    });
    return switch (result) {
        .completed => |completed| completed.text,
        .err => |msg| {
            defer allocator.free(msg);
            std.log.scoped(.coding_agent).warn("completion failed: {s}", .{msg});
            return error.ProviderCompletionFailed;
        },
        .cancelled => error.MissingCompletionText,
    };
}
