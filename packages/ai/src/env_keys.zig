const std = @import("std");
const types = @import("types.zig");

/// Sentinel value returned when authentication is detected via
/// credentials files or IAM roles rather than explicit API keys.
const authenticated_sentinel = "<authenticated>";

/// Get API key for provider from known environment variables.
/// Returns null if no key is found.
pub fn getEnvApiKey(provider: types.Provider) ?[]const u8 {
    return switch (provider) {
        .github_copilot => std.posix.getenv("COPILOT_GITHUB_TOKEN") orelse std.posix.getenv("GH_TOKEN") orelse std.posix.getenv("GITHUB_TOKEN"),
        .anthropic => std.posix.getenv("ANTHROPIC_OAUTH_TOKEN") orelse std.posix.getenv("ANTHROPIC_API_KEY"),
        .google_vertex => getVertexKey(),
        .amazon_bedrock => getBedrockKey(),
        .openai => std.posix.getenv("OPENAI_API_KEY"),
        .azure_openai_responses => std.posix.getenv("AZURE_OPENAI_API_KEY"),
        .google, .google_antigravity => std.posix.getenv("GEMINI_API_KEY"),
        .groq => std.posix.getenv("GROQ_API_KEY"),
        .cerebras => std.posix.getenv("CEREBRAS_API_KEY"),
        .xai => std.posix.getenv("XAI_API_KEY"),
        .openrouter => std.posix.getenv("OPENROUTER_API_KEY"),
        .vercel_ai_gateway => std.posix.getenv("AI_GATEWAY_API_KEY"),
        .zai => std.posix.getenv("ZAI_API_KEY"),
        .mistral => std.posix.getenv("MISTRAL_API_KEY"),
        .minimax => std.posix.getenv("MINIMAX_API_KEY"),
        .minimax_cn => std.posix.getenv("MINIMAX_CN_API_KEY"),
        .huggingface => std.posix.getenv("HF_TOKEN"),
        .opencode, .opencode_go => std.posix.getenv("OPENCODE_API_KEY"),
        .kimi_coding => std.posix.getenv("KIMI_API_KEY"),
        .google_gemini_cli => null, // OAuth only
        .openai_codex => null, // OAuth only
    };
}

/// Check for Vertex AI credentials.
/// Returns GOOGLE_CLOUD_API_KEY if set, or "<authenticated>" if ADC credentials
/// exist and GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION are set.
fn getVertexKey() ?[]const u8 {
    // Check for explicit API key first
    if (std.posix.getenv("GOOGLE_CLOUD_API_KEY")) |key| {
        return key;
    }

    // Check for Application Default Credentials
    const has_credentials = hasVertexAdcCredentials();
    const has_project = std.posix.getenv("GOOGLE_CLOUD_PROJECT") != null or std.posix.getenv("GCLOUD_PROJECT") != null;
    const has_location = std.posix.getenv("GOOGLE_CLOUD_LOCATION") != null;

    if (has_credentials and has_project and has_location) {
        return authenticated_sentinel;
    }

    return null;
}

/// Check if Vertex ADC credentials exist.
/// Checks GOOGLE_APPLICATION_CREDENTIALS env var first, then the default
/// path at ~/.config/gcloud/application_default_credentials.json.
fn hasVertexAdcCredentials() bool {
    // Check GOOGLE_APPLICATION_CREDENTIALS env var first (standard way)
    if (std.posix.getenv("GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    // Fall back to default ADC path
    const home = std.posix.getenv("HOME") orelse return false;
    const adc_path = std.fs.path.join(std.heap.page_allocator, &[_][]const u8{
        home, ".config", "gcloud", "application_default_credentials.json",
    }) catch return false;
    defer std.heap.page_allocator.free(adc_path);

    std.fs.accessAbsolute(adc_path, .{}) catch return false;
    return true;
}

/// Check for Amazon Bedrock credentials.
/// Returns "<authenticated>" if any AWS credential source is detected:
/// - AWS_PROFILE (named profile)
/// - AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (IAM keys)
/// - AWS_BEARER_TOKEN_BEDROCK (bearer token)
/// - AWS_CONTAINER_CREDENTIALS_RELATIVE_URI (ECS task roles)
/// - AWS_CONTAINER_CREDENTIALS_FULL_URI (ECS task roles)
/// - AWS_WEB_IDENTITY_TOKEN_FILE (IRSA)
fn getBedrockKey() ?[]const u8 {
    if (std.posix.getenv("AWS_PROFILE") != null) {
        return authenticated_sentinel;
    }

    if (std.posix.getenv("AWS_ACCESS_KEY_ID") != null and std.posix.getenv("AWS_SECRET_ACCESS_KEY") != null) {
        return authenticated_sentinel;
    }

    if (std.posix.getenv("AWS_BEARER_TOKEN_BEDROCK") != null) {
        return authenticated_sentinel;
    }

    if (std.posix.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != null) {
        return authenticated_sentinel;
    }

    if (std.posix.getenv("AWS_CONTAINER_CREDENTIALS_FULL_URI") != null) {
        return authenticated_sentinel;
    }

    if (std.posix.getenv("AWS_WEB_IDENTITY_TOKEN_FILE") != null) {
        return authenticated_sentinel;
    }

    return null;
}
