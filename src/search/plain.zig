const fuzzy = @import("fuzzy.zig");

pub const Match = fuzzy.FuzzyMatch;
pub const FuzzyMatch = fuzzy.FuzzyMatch;
pub const fuzzyMatch = fuzzy.fuzzyMatch;
pub const fuzzyFilter = fuzzy.fuzzyFilter;

pub fn match(query: []const u8, text: []const u8) Match {
    return fuzzy.fuzzyMatch(query, text);
}

pub fn filter(query: []const u8, texts: []const []const u8, out_indices: []usize) usize {
    return fuzzy.fuzzyFilter(query, texts, out_indices);
}
