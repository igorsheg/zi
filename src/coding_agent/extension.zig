pub const Host = union(enum) {
    disabled,

    pub fn disabledHost() Host {
        return .disabled;
    }
};
