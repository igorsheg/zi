pub const max_credentials = 32;
pub const max_secret_bytes = 64 * 1024;

pub const Credential = union(enum) {
    api_key: ApiKey,
    oauth: OAuth,

    pub const ApiKey = struct {
        key: []const u8,
    };

    pub const OAuth = struct {
        access: []const u8,
        refresh: []const u8,
        expires_at_ms: u64,
        account_id: ?[]const u8 = null,
    };
};

pub const Entry = struct {
    provider_id: []const u8,
    credential: Credential,
};
