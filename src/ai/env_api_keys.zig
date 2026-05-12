const std = @import("std");

pub fn getEnvApiKey(provider: []const u8) ?[]const u8 {
    const eql = std.mem.eql;

    if (eql(u8, provider, "github-copilot")) {
        return @import("env").get("COPILOT_GITHUB_TOKEN") orelse
            @import("env").get("GH_TOKEN") orelse
            @import("env").get("GITHUB_TOKEN");
    }

    if (eql(u8, provider, "anthropic")) {
        return @import("env").get("ANTHROPIC_OAUTH_TOKEN") orelse
            @import("env").get("ANTHROPIC_API_KEY");
    }

    if (eql(u8, provider, "google-vertex")) {
        if (@import("env").get("GOOGLE_CLOUD_API_KEY")) |key| return key;

        const has_project = @import("env").get("GOOGLE_CLOUD_PROJECT") != null or
            @import("env").get("GCLOUD_PROJECT") != null;
        const has_location = @import("env").get("GOOGLE_CLOUD_LOCATION") != null;
        const has_creds = @import("env").get("GOOGLE_APPLICATION_CREDENTIALS") != null;

        if (has_creds and has_project and has_location) return "<authenticated>";
        return null;
    }

    if (eql(u8, provider, "amazon-bedrock")) {
        if (@import("env").get("AWS_PROFILE") != null) return "<authenticated>";
        if (@import("env").get("AWS_ACCESS_KEY_ID") != null and
            @import("env").get("AWS_SECRET_ACCESS_KEY") != null) return "<authenticated>";
        if (@import("env").get("AWS_BEARER_TOKEN_BEDROCK") != null) return "<authenticated>";
        if (@import("env").get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != null) return "<authenticated>";
        if (@import("env").get("AWS_CONTAINER_CREDENTIALS_FULL_URI") != null) return "<authenticated>";
        if (@import("env").get("AWS_WEB_IDENTITY_TOKEN_FILE") != null) return "<authenticated>";
        return null;
    }

    const env_var = envVarForProvider(provider) orelse return null;
    return @import("env").get(env_var);
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
