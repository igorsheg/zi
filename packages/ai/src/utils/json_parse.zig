const std = @import("std");

/// Attempts to parse potentially incomplete JSON during streaming.
/// Always returns a valid Value, even if the JSON is incomplete.
///
/// This is a best-effort parser for streaming JSON responses.
/// - First tries standard parsing
/// - If that fails, attempts to close unclosed brackets/braces for partial JSON
/// - Returns empty object {} if all parsing fails
pub fn parseStreamingJson(allocator: std.mem.Allocator, partial_json: ?[]const u8) !std.json.Value {
    // Handle null or empty input
    const json_str = partial_json orelse "";
    if (json_str.len == 0 or isOnlyWhitespace(json_str)) {
        return std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    }
    
    // Try standard parsing first (fastest for complete JSON)
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        // If standard parsing fails, try to fix incomplete JSON
        _ = err;
        return try parsePartialJson(allocator, json_str);
    };
    
    return parsed.value;
}

/// Check if a string contains only whitespace.
fn isOnlyWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

/// Attempt to parse incomplete/partial JSON by closing unclosed structures.
/// This is a best-effort approach for streaming responses.
fn parsePartialJson(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    // Count unclosed brackets and braces
    var brace_depth: i32 = 0;    // {}
    var bracket_depth: i32 = 0;  // []
    var in_string = false;
    var escape_next = false;
    
    for (json_str) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }
        
        if (c == '\\' and in_string) {
            escape_next = true;
            continue;
        }
        
        if (c == '"' and !escape_next) {
            in_string = !in_string;
            continue;
        }
        
        if (!in_string) {
            switch (c) {
                '{' => brace_depth += 1,
                '}' => brace_depth -= 1,
                '[' => bracket_depth += 1,
                ']' => bracket_depth -= 1,
                else => {},
            }
        }
    }
    
    // Close any unclosed strings
    var fixed = std.ArrayList(u8).init(allocator);
    defer fixed.deinit();
    
    try fixed.appendSlice(json_str);
    
    if (in_string) {
        try fixed.append('"');
    }
    
    // Close unclosed brackets and braces (in reverse order of opening)
    // First close any unclosed arrays
    while (bracket_depth > 0) : (bracket_depth -= 1) {
        // Remove trailing comma if present before closing
        if (fixed.items.len > 0 and fixed.items[fixed.items.len - 1] == ',') {
            _ = fixed.pop();
        }
        try fixed.append(']');
    }
    
    // Then close any unclosed objects
    while (brace_depth > 0) : (brace_depth -= 1) {
        // Remove trailing comma if present before closing
        if (fixed.items.len > 0 and fixed.items[fixed.items.len - 1] == ',') {
            _ = fixed.pop();
        }
        try fixed.append('}');
    }
    
    // Try parsing the fixed JSON
    const fixed_slice = try fixed.toOwnedSlice();
    defer allocator.free(fixed_slice);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, fixed_slice, .{
        .ignore_unknown_fields = true,
    }) catch {
        // If fixing didn't help, return empty object
        return std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    };
    
    // We need to return the value but the parsed struct owns it
    // Clone it so we can free the parsed struct
    const value_copy = try cloneJsonValue(allocator, parsed.value);
    parsed.deinit();
    return value_copy;
}

/// Clone a JSON value to a new allocation.
fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return std.json.Value{ .bool = b },
        .integer => |i| return std.json.Value{ .integer = i },
        .float => |f| return std.json.Value{ .float = f },
        .string => |s| return std.json.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return std.json.Value{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try new_obj.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return std.json.Value{ .object = new_obj };
        },
        .number_string => |s| return std.json.Value{ .number_string = try allocator.dupe(u8, s) },
    }
}
