//! Versioned semantic tool-result detail families.
//!
//! The public tool result envelope stays open (`details: json.Value`) so
//! extensions can return arbitrary payloads. This module defines the small set
//! of host-recognized, opt-in detail families that builtin and extension tools
//! may use for richer host-owned presentation.

const std = @import("std");
const diff = @import("../../diff/document.zig");
const diff_json = @import("../../diff/json.zig");
const json_util = @import("../../ai/json_util.zig");

pub const DIFF_KIND = "diff";
pub const DIFF_VERSION: i64 = 2;

pub const DiffDetails = struct {
    owned: diff.OwnedDocument,

    pub fn document(self: *const DiffDetails) diff.DiffDocument {
        return self.owned.document;
    }

    pub fn deinit(self: *DiffDetails) void {
        self.owned.deinit();
    }
};

/// Serialize a diff document into the open `AgentToolResult.details` envelope.
/// Shape:
/// `{ kind = "diff", version = 2, diff = <diff_json document> }`.
pub fn diffToJsonValue(allocator: std.mem.Allocator, document: diff.DiffDocument) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    errdefer json_util.freeJsonValue(allocator, .{ .object = obj });

    try obj.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, DIFF_KIND) });
    try obj.put(allocator, try allocator.dupe(u8, "version"), .{ .integer = DIFF_VERSION });
    try obj.put(allocator, try allocator.dupe(u8, "diff"), try diff_json.toJsonValue(allocator, document));

    return .{ .object = obj };
}

/// Parse a recognized diff details envelope. Unknown kind/version/shape is an
/// error so callers can fail open to generic text rendering.
pub fn diffFromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !DiffDetails {
    if (value != .object) return error.InvalidToolResultDetails;
    const obj = value.object;

    const kind_val = obj.get("kind") orelse return error.InvalidToolResultDetails;
    if (kind_val != .string or !std.mem.eql(u8, kind_val.string, DIFF_KIND)) {
        return error.UnsupportedToolResultDetails;
    }

    const version_val = obj.get("version") orelse return error.InvalidToolResultDetails;
    const version = switch (version_val) {
        .integer => |n| n,
        else => return error.InvalidToolResultDetails,
    };
    if (version != DIFF_VERSION) return error.UnsupportedToolResultDetails;

    const diff_val = obj.get("diff") orelse return error.InvalidToolResultDetails;
    return .{ .owned = try diff_json.fromJsonValue(allocator, diff_val) };
}

const testing = std.testing;

test "diff details preserve open envelope with recognized kind and version" {
    const inputs = [_]diff.Input{.{
        .old_path = "a.txt",
        .new_path = "a.txt",
        .old_text = "one\ntwo\n",
        .new_text = "one\nTWO\n",
    }};
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const details = try diffToJsonValue(testing.allocator, doc.document);
    defer json_util.freeJsonValue(testing.allocator, details);

    try testing.expect(details == .object);
    try testing.expectEqualStrings(DIFF_KIND, details.object.get("kind").?.string);
    try testing.expectEqual(@as(i64, DIFF_VERSION), details.object.get("version").?.integer);

    var parsed = try diffFromJsonValue(testing.allocator, details);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.document().changes.len);
    try testing.expectEqual(@as(u32, 1), parsed.document().stats.added);
    try testing.expectEqual(@as(u32, 1), parsed.document().stats.removed);
}
