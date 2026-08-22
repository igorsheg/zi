const store = @import("Store.zig");

pub const Store = store.Store;
pub const Entry = store.Entry;
pub const Kind = store.Kind;
pub const default_max_store_bytes = store.default_max_store_bytes;

test {
    _ = store;
}
