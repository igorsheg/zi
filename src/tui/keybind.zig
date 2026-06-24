//! Bounded key binding registry for frontend-defined shortcuts.
//!
//! The TUI owns focus and input mode decisions, but not the meaning of a
//! frontend shortcut. A match produces an opaque id; the frontend maps that id
//! to product behavior.
const std = @import("std");
const input = @import("input.zig");

pub const Id = u16;
pub const binding_count_max: usize = 64;

pub const Binding = struct {
    /// Zero is reserved as "no binding" so accidental default values never
    /// trigger frontend behavior.
    id: Id,
    chord: input.Chord,
};

const Entry = Binding;

pub const Store = struct {
    len: u8 = 0,
    entries: [binding_count_max]Entry = undefined,

    pub fn clear(self: *Store) void {
        self.len = 0;
    }

    /// Replace the whole resolved keymap. Only the bounded prefix is inspected;
    /// invalid bindings, duplicate ids, and duplicate chords are dropped.
    /// Callers that accept operational extension input should validate and
    /// report diagnostics before installing.
    pub fn set(self: *Store, bindings: []const Binding) void {
        self.clear();
        const bounded = bindings[0..@min(bindings.len, binding_count_max)];
        for (bounded) |binding| {
            if (self.len == self.entries.len) return;
            if (binding.id == 0) continue;
            if (self.containsId(binding.id)) continue;
            if (self.match(binding.chord) != null) continue;
            self.entries[self.len] = binding;
            self.len += 1;
        }
    }

    pub fn match(self: *const Store, chord: input.Chord) ?Id {
        for (self.entries[0..self.len]) |entry| {
            if (entry.chord.eql(chord)) return entry.id;
        }
        return null;
    }

    fn containsId(self: *const Store, id: Id) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.id == id) return true;
        }
        return false;
    }
};

test "store matches installed bindings" {
    var store: Store = .{};
    store.set(&.{.{ .id = 7, .chord = input.Chord.ctrl('l') }});

    try std.testing.expectEqual(@as(?Id, 7), store.match(input.Chord.ctrl('l')));
    try std.testing.expectEqual(@as(?Id, null), store.match(input.Chord.ctrl('x')));
}

test "store drops invalid and ambiguous bindings" {
    var store: Store = .{};
    store.set(&.{
        .{ .id = 0, .chord = input.Chord.ctrl('a') },
        .{ .id = 1, .chord = input.Chord.ctrl('b') },
        .{ .id = 2, .chord = input.Chord.ctrl('b') },
        .{ .id = 1, .chord = input.Chord.ctrl('c') },
    });

    try std.testing.expectEqual(@as(u8, 1), store.len);
    try std.testing.expectEqual(@as(?Id, 1), store.match(input.Chord.ctrl('b')));
    try std.testing.expectEqual(@as(?Id, null), store.match(input.Chord.ctrl('a')));
    try std.testing.expectEqual(@as(?Id, null), store.match(input.Chord.ctrl('c')));
}
