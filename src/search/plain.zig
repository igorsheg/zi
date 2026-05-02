const fuzzy = @import("fuzzy.zig");

pub const Match = fuzzy.FuzzyMatch;
pub const FuzzyMatch = fuzzy.FuzzyMatch;
pub const Field = fuzzy.Field;
pub const Options = fuzzy.Options;
pub const Query = fuzzy.Query;

pub const fuzzyMatch = fuzzy.fuzzyMatch;
pub const fuzzyFilter = fuzzy.fuzzyFilter;
pub const parse = fuzzy.parse;
pub const positions = fuzzy.positions;
pub const matchFields = fuzzy.matchFields;
pub const matchFieldsParsed = fuzzy.matchFieldsParsed;
pub const filterFields = fuzzy.filterFields;

pub fn match(query: []const u8, text: []const u8) Match {
    return fuzzy.match(query, text);
}

pub fn matchWithOptions(query: []const u8, text: []const u8, opts: Options) Match {
    return fuzzy.matchWithOptions(query, text, opts);
}

pub fn filter(query: []const u8, texts: []const []const u8, out_indices: []usize) usize {
    return fuzzy.filter(query, texts, out_indices);
}
