const std = @import("std");
const types = @import("types.zig");

pub fn formatSkillsForPrompt(allocator: std.mem.Allocator, skills: []const types.Skill) ![]const u8 {
    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try w.writeAll("Use the read tool to load a skill's file when the task matches its description.\n");
    try w.writeAll("When a skill file references a relative path, resolve it against the skill directory and use that absolute path in tool commands.\n\n");
    try w.writeAll("<available_skills>\n");
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try w.writeAll("  <skill>\n");
        const escaped_name = try escapeXml(allocator, skill.name);
        defer allocator.free(escaped_name);
        const escaped_description = try escapeXml(allocator, skill.description);
        defer allocator.free(escaped_description);
        const escaped_location = try escapeXml(allocator, skill.file_path);
        defer allocator.free(escaped_location);
        try w.print("    <name>{s}</name>\n", .{escaped_name});
        try w.print("    <description>{s}</description>\n", .{escaped_description});
        try w.print("    <location>{s}</location>\n", .{escaped_location});
        try w.writeAll("  </skill>\n");
    }
    try w.writeAll("</available_skills>");

    return try aw.toOwnedSlice();
}

fn escapeXml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "format skills excludes explicit-only skills" {
    const allocator = std.testing.allocator;
    const source_info = @import("../resources/types.zig").SourceInfo{ .path = "p", .source = "local" };
    const skills = [_]types.Skill{
        .{ .name = "one", .description = "desc", .file_path = "/tmp/SKILL.md", .base_dir = "/tmp", .source_info = source_info },
        .{ .name = "two", .description = "desc", .file_path = "/tmp/two.md", .base_dir = "/tmp", .source_info = source_info, .disable_model_invocation = true },
    };
    const out = try formatSkillsForPrompt(allocator, &skills);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<name>one</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<name>two</name>") == null);
}
