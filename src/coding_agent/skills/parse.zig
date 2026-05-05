const std = @import("std");
const types = @import("types.zig");
const resource_types = @import("../resources/types.zig");

pub const ParsedSkillDocument = struct {
    frontmatter: types.SkillFrontmatter,
    body: []const u8,
};

pub fn parseFrontmatter(allocator: std.mem.Allocator, raw: []const u8) !ParsedSkillDocument {
    if (!std.mem.startsWith(u8, raw, "---\n") and !std.mem.startsWith(u8, raw, "---\r\n")) {
        return .{ .frontmatter = .{}, .body = raw };
    }

    const header_start = findLineEnd(raw, 0) orelse return .{ .frontmatter = .{}, .body = raw };
    const rest = raw[header_start..];
    const marker_index = std.mem.indexOf(u8, rest, "\n---\n") orelse std.mem.indexOf(u8, rest, "\n---\r\n") orelse return .{ .frontmatter = .{}, .body = raw };
    const header = rest[0..marker_index];
    const marker_len: usize = if (std.mem.startsWith(u8, rest[marker_index..], "\n---\r\n")) 6 else 5;
    const body_start = header_start + marker_index + marker_len;

    var frontmatter = types.SkillFrontmatter{};
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\"");

        if (std.mem.eql(u8, key, "name")) {
            frontmatter.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "description")) {
            frontmatter.description = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            frontmatter.disable_model_invocation = parseBool(value);
        }
    }

    return .{
        .frontmatter = frontmatter,
        .body = raw[body_start..],
    };
}

pub fn deinitParsedSkillDocument(allocator: std.mem.Allocator, doc: ParsedSkillDocument) void {
    if (doc.frontmatter.name) |name| allocator.free(name);
    if (doc.frontmatter.description) |description| allocator.free(description);
}

pub fn validateSkillFrontmatter(
    allocator: std.mem.Allocator,
    frontmatter: types.SkillFrontmatter,
    parent_dir_name: []const u8,
    file_path: []const u8,
) ![]const resource_types.ResourceDiagnostic {
    var diagnostics: std.ArrayListUnmanaged(resource_types.ResourceDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| {
            allocator.free(diagnostic.message);
            if (diagnostic.path) |path| allocator.free(path);
        }
        diagnostics.deinit(allocator);
    }

    const name = frontmatter.name orelse parent_dir_name;
    if (!std.mem.eql(u8, name, parent_dir_name)) {
        try appendWarning(allocator, &diagnostics, file_path, "name does not match parent directory");
    }
    if (name.len > types.MAX_NAME_LENGTH) {
        try appendWarning(allocator, &diagnostics, file_path, "name exceeds 64 characters");
    }
    if (!isValidSkillName(name)) {
        try appendWarning(allocator, &diagnostics, file_path, "name contains invalid characters");
    }
    if (frontmatter.description == null or std.mem.trim(u8, frontmatter.description.?, " \t\r\n").len == 0) {
        try appendWarning(allocator, &diagnostics, file_path, "description is required");
    } else if (frontmatter.description.?.len > types.MAX_DESCRIPTION_LENGTH) {
        try appendWarning(allocator, &diagnostics, file_path, "description exceeds 1024 characters");
    }

    return try diagnostics.toOwnedSlice(allocator);
}

fn appendWarning(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(resource_types.ResourceDiagnostic),
    file_path: []const u8,
    message: []const u8,
) !void {
    try diagnostics.append(allocator, .{
        .kind = .warning,
        .message = try allocator.dupe(u8, message),
        .path = try allocator.dupe(u8, file_path),
    });
}

fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;

    var prev_dash = false;
    for (name) |c| {
        const is_valid = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!is_valid) return false;
        if (c == '-') {
            if (prev_dash) return false;
            prev_dash = true;
        } else {
            prev_dash = false;
        }
    }
    return true;
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

fn findLineEnd(buf: []const u8, start: usize) ?usize {
    const nl = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse return null;
    return nl + 1;
}

test "parse frontmatter extracts fields" {
    const allocator = std.testing.allocator;
    const doc = try parseFrontmatter(
        allocator,
        "---\nname: test-skill\ndescription: sample\ndisable-model-invocation: true\n---\nbody\n",
    );
    defer deinitParsedSkillDocument(allocator, doc);

    try std.testing.expectEqualStrings("test-skill", doc.frontmatter.name.?);
    try std.testing.expectEqualStrings("sample", doc.frontmatter.description.?);
    try std.testing.expect(doc.frontmatter.disable_model_invocation);
    try std.testing.expectEqualStrings("body\n", doc.body);
}
