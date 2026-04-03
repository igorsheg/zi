const std = @import("std");

/// Get API key for a provider from known environment variables.
/// Port of pi-mono's getEnvApiKey (packages/ai/src/env-api-keys.ts:63-133).
///
/// Returns the env var value if set, null otherwise.
/// Special cases:
///   - "anthropic": checks ANTHROPIC_OAUTH_TOKEN first, then ANTHROPIC_API_KEY
///   - "github-copilot": checks COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN
///   - "amazon-bedrock": checks AWS_PROFILE, AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY,
///     AWS_BEARER_TOKEN_BEDROCK, container/web-identity credential sources
///   - "google-vertex": checks GOOGLE_CLOUD_API_KEY, then ADC credentials
///     (skipping ADC file check for now — just check env vars)
pub fn getEnvApiKey(provider: []const u8) ?[]const u8 {
    const eql = std.mem.eql;

    // github-copilot: multiple token sources
    if (eql(u8, provider, "github-copilot")) {
        return std.posix.getenv("COPILOT_GITHUB_TOKEN") orelse
            std.posix.getenv("GH_TOKEN") orelse
            std.posix.getenv("GITHUB_TOKEN");
    }

    // anthropic: oauth token takes precedence over api key
    if (eql(u8, provider, "anthropic")) {
        return std.posix.getenv("ANTHROPIC_OAUTH_TOKEN") orelse
            std.posix.getenv("ANTHROPIC_API_KEY");
    }

    // google-vertex: explicit API key, or ADC env-var-based check
    if (eql(u8, provider, "google-vertex")) {
        if (std.posix.getenv("GOOGLE_CLOUD_API_KEY")) |key| return key;

        const has_project = std.posix.getenv("GOOGLE_CLOUD_PROJECT") != null or
            std.posix.getenv("GCLOUD_PROJECT") != null;
        const has_location = std.posix.getenv("GOOGLE_CLOUD_LOCATION") != null;
        // NOTE: skipping ADC file check (would need fs access). only env-var sources.
        const has_creds = std.posix.getenv("GOOGLE_APPLICATION_CREDENTIALS") != null;

        if (has_creds and has_project and has_location) return "<authenticated>";
        return null;
    }

    // amazon-bedrock: multiple credential sources
    if (eql(u8, provider, "amazon-bedrock")) {
        if (std.posix.getenv("AWS_PROFILE") != null) return "<authenticated>";
        if (std.posix.getenv("AWS_ACCESS_KEY_ID") != null and
            std.posix.getenv("AWS_SECRET_ACCESS_KEY") != null) return "<authenticated>";
        if (std.posix.getenv("AWS_BEARER_TOKEN_BEDROCK") != null) return "<authenticated>";
        if (std.posix.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != null) return "<authenticated>";
        if (std.posix.getenv("AWS_CONTAINER_CREDENTIALS_FULL_URI") != null) return "<authenticated>";
        if (std.posix.getenv("AWS_WEB_IDENTITY_TOKEN_FILE") != null) return "<authenticated>";
        return null;
    }

    // Standard provider → env var map
    const env_var = envVarForProvider(provider) orelse return null;
    return std.posix.getenv(env_var);
}

fn envVarForProvider(provider: []const u8) ?[:0]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, provider, "openai")) return "OPENAI_API_KEY";
    if (eql(u8, provider, "azure-openai-responses")) return "AZURE_OPENAI_API_KEY";
    if (eql(u8, provider, "google")) return "GEMINI_API_KEY";
    if (eql(u8, provider, "groq")) return "GROQ_API_KEY";
    if (eql(u8, provider, "cerebras")) return "CEREBRAS_API_KEY";
    if (eql(u8, provider, "xai")) return "XAI_API_KEY";
    if (eql(u8, provider, "openrouter")) return "OPENROUTER_API_KEY";
    if (eql(u8, provider, "vercel-ai-gateway")) return "AI_GATEWAY_API_KEY";
    if (eql(u8, provider, "zai")) return "ZAI_API_KEY";
    if (eql(u8, provider, "mistral")) return "MISTRAL_API_KEY";
    if (eql(u8, provider, "minimax")) return "MINIMAX_API_KEY";
    if (eql(u8, provider, "minimax-cn")) return "MINIMAX_CN_API_KEY";
    if (eql(u8, provider, "huggingface")) return "HF_TOKEN";
    if (eql(u8, provider, "opencode")) return "OPENCODE_API_KEY";
    if (eql(u8, provider, "opencode-go")) return "OPENCODE_API_KEY";
    if (eql(u8, provider, "kimi-coding")) return "KIMI_API_KEY";
    return null;
}

