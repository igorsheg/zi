const std = @import("std");

pub const Item = @import("Item.zig");
pub const StreamEvent = @import("StreamEvent.zig");
pub const Provider = @import("Provider.zig");
pub const Usage = @import("Usage.zig");
pub const UsagePricing = @import("UsagePricing.zig");
pub const Transport = @import("Transport.zig");
pub const JsonTransport = @import("JsonTransport.zig");
pub const LocalDiscovery = @import("LocalDiscovery.zig");
pub const HttpTransport = @import("HttpTransport.zig");
pub const OpenAiResponses = @import("OpenAiResponses.zig").OpenAiResponses;
pub const OpenAiChat = @import("OpenAiChat.zig").OpenAiChat;
pub const AnthropicMessages = @import("AnthropicMessages.zig").AnthropicMessages;
pub const Wire = @import("Wire.zig").Wire;
pub const Effort = @import("Effort.zig");
pub const ModelMeta = @import("ModelMeta.zig");
pub const ModelCatalog = @import("ModelCatalog.zig");
pub const ProviderRegistry = @import("ProviderRegistry.zig");
pub const ProviderFactory = @import("ProviderFactory.zig");
pub const Codex = @import("Codex.zig").Codex;
pub const CodexConfig = @import("Codex.zig").Config;
pub const CodexCredential = @import("Codex.zig").Credential;
pub const CodexOwnedCredential = @import("Codex.zig").OwnedCredential;
pub const CodexCredentialSource = @import("Codex.zig").CredentialSource;
pub const CodexAcquirePurpose = @import("Codex.zig").AcquirePurpose;
pub const CodexAcquireDecision = @import("Codex.zig").AcquireDecision;
pub const CodexUnauthorizedDecision = @import("Codex.zig").UnauthorizedDecision;
pub const CodexCredentials = @import("CodexCredentials.zig");
pub const CodexSettings = @import("CodexSettings.zig");
pub const CodexRefresh = @import("CodexRefresh.zig");
pub const CodexModels = @import("CodexModels.zig");
pub const CodexOperations = @import("CodexOperations.zig");
pub const CodexUsage = @import("CodexUsage.zig");
pub const Mock = @import("Mock.zig");
const Sse = @import("Sse.zig");
const Retry = @import("Retry.zig");
const ApiError = @import("ApiError.zig");
const StreamRetry = @import("StreamRetry.zig");
const SecureAllocator = @import("SecureAllocator.zig");
const OpenAiResponsesBody = @import("OpenAiResponsesBody.zig");
const OpenAiResponsesEvents = @import("OpenAiResponsesEvents.zig");
const OpenAiChatBody = @import("OpenAiChatBody.zig");
const OpenAiChatEvents = @import("OpenAiChatEvents.zig");
const AnthropicMessagesBody = @import("AnthropicMessagesBody.zig");
const AnthropicMessagesEvents = @import("AnthropicMessagesEvents.zig");

test {
    _ = Item;
    _ = StreamEvent;
    _ = Provider;
    _ = Usage;
    _ = UsagePricing;
    _ = Transport;
    _ = Sse;
    _ = Retry;
    _ = ApiError;
    _ = StreamRetry;
    _ = SecureAllocator;
    _ = OpenAiResponses;
    _ = OpenAiResponsesBody;
    _ = OpenAiResponsesEvents;
    _ = OpenAiChat;
    _ = OpenAiChatBody;
    _ = OpenAiChatEvents;
    _ = AnthropicMessages;
    _ = AnthropicMessagesBody;
    _ = AnthropicMessagesEvents;
    _ = Wire;
    _ = Effort;
    _ = JsonTransport;
    _ = LocalDiscovery;
    _ = HttpTransport;
    _ = ModelMeta;
    _ = ModelCatalog;
    _ = ProviderRegistry;
    _ = ProviderFactory;
    _ = Codex;
    _ = CodexConfig;
    _ = CodexCredential;
    _ = CodexCredentialSource;
    _ = CodexAcquirePurpose;
    _ = CodexAcquireDecision;
    _ = CodexUnauthorizedDecision;
    _ = CodexCredentials;
    _ = CodexSettings;
    _ = CodexRefresh;
    _ = CodexModels;
    _ = CodexOperations;
    _ = CodexUsage;
}

test "Codex credential source is implementable through the public seam" {
    const Source = struct {
        const Self = @This();

        pub fn acquire(
            _: *Self,
            allocator: std.mem.Allocator,
            _: std.Io,
            _: ?Provider.Tick,
            purpose: CodexAcquirePurpose,
        ) CodexCredentialSource.CallbackError!CodexAcquireDecision {
            std.debug.assert(purpose == .request);
            return .{ .ready = try CodexOwnedCredential.init(allocator, .{
                .access_token = "token",
                .account_id = "account",
            }) };
        }

        pub fn recoverUnauthorized(
            _: *Self,
            _: std.mem.Allocator,
            _: std.Io,
            _: ?Provider.Tick,
            _: CodexCredential,
        ) CodexCredentialSource.CallbackError!CodexUnauthorizedDecision {
            return .use_response;
        }

        pub fn noteUnauthorized(_: *Self, _: CodexCredential) void {}
    };
    var source: Source = .{};
    _ = CodexCredentialSource.from(&source);
}
