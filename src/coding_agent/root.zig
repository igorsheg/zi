pub const paths = @import("paths.zig");
pub const session_manager = @import("session_manager.zig");
pub const session_store = @import("session_store.zig");

pub const PersistencePaths = paths.PersistencePaths;
pub const SessionManager = session_manager.SessionManager;
pub const SessionHeader = session_manager.SessionHeader;
pub const SessionEntry = session_manager.SessionEntry;
pub const SessionContext = session_manager.SessionContext;
pub const SessionStore = session_store.SessionStore;

pub const current_session_version = session_manager.current_session_version;

pub fn testsReachable() void {
    _ = paths;
    _ = session_manager;
    _ = session_store;
}

test {
    _ = paths;
    _ = session_manager;
    _ = session_store;
}
