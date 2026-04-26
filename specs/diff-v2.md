# diff v2

## status

Implemented for zi's built-in edit result family and TUI rendering path.

## purpose

Diff v2 is the semantic diff format used by zi for:

- edit-tool structured `details`
- unified diff text generation
- TUI pretty diff rendering
- extension-compatible builtin-family renderer inheritance

The design goal is one canonical semantic model. Renderers and serializers derive from it; they do not rediscover relationships from flattened text.

## non-goals

Diff v2 is not a full git replacement. It does not currently define:

- rename/copy detection
- binary patch encoding
- word/inline diff runs
- alternate algorithms as public API
- whitespace-ignore modes
- moved-code coloring

Those can be added later without changing the core ownership boundary.

## result envelope

Tool results keep zi's open public envelope:

```zig
AgentToolResult{
    content: []ContentBlock,
    details: std.json.Value,
    is_error: bool,
}
```

Diff is an optional recognized semantic family in `details`:

```json
{
  "kind": "diff",
  "version": 2,
  "diff": { ... DiffDocument ... }
}
```

Rules:

- `details` remains open JSON; extensions may return arbitrary shapes.
- Unknown `kind`, unsupported `version`, or malformed diff payloads must fail open to generic text rendering.
- `content` should remain useful fallback text. The built-in edit tool returns unified diff text in `content`.

## ownership

The plain document is a borrowed semantic view:

```zig
DiffDocument{
    changes: []const FileChange,
    stats: Stats,
}
```

Owned documents use one arena:

```zig
OwnedDocument{
    document: DiffDocument,
    arena: std.heap.ArenaAllocator,
}
```

All nested document slices owned by `OwnedDocument` live in that arena and are freed together. The plain document carries no allocator and no ownership flags.

## semantic model

A file change contains hunks. A hunk contains first-class blocks.

```zig
FileChange{
    old_path: []const u8,
    new_path: []const u8,
    hunks: []const Hunk,
    stats: Stats,
}

Hunk{
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    blocks: []const HunkBlock,
}
```

`HunkBlock` is the core of v2:

```zig
HunkBlock = union(enum) {
    context: ContextBlock,
    delete: DeleteBlock,
    insert: InsertBlock,
    replace: ReplaceBlock,
}
```

Blocks:

```zig
ContextBlock{
    old_start: u32,
    new_start: u32,
    lines: []const Line,
}

DeleteBlock{
    old_start: u32,
    lines: []const Line,
}

InsertBlock{
    new_start: u32,
    lines: []const Line,
}

ReplaceBlock{
    old_start: u32,
    new_start: u32,
    old_lines: []const Line,
    new_lines: []const Line,
}

Line{
    text: []const u8,
}
```

Line text currently excludes the line separator. Newline-at-EOF metadata is intentionally deferred; the model has room to add line metadata later.

## why blocks, not flat lines

Diff v1 represented replace as delete lines plus insert lines with an optional pairing id. That was a side channel.

Diff v2 makes replacement first-class:

```text
replace {
  old_lines = [...]
  new_lines = [...]
}
```

Benefits:

- illegal states are reduced
- TUI renderers do not infer replacement pairs
- inline/word diff has a natural home later
- JSON is clearer for extensions
- unified diff remains a projection, not the model

## internal algorithm shape

The core algorithm pipeline is:

```text
old/new line slices
  -> Myers raw ops
  -> range opcodes
  -> replacement compaction
  -> grouped hunks with context
  -> arena-owned DiffDocument blocks
```

Internal opcodes use full old/new ranges:

```zig
Opcode = union(enum) {
    equal:   { old: Range, new: Range },
    delete:  { old: Range, new_at: u32 },
    insert:  { old_at: u32, new: Range },
    replace: { old: Range, new: Range },
}
```

Delete followed by insert at the same cursor is compacted into replace. Public hunks are then built from opcodes.

## hunk grouping

Grouping follows the familiar `difflib`/`similar` shape:

- keep up to `context` equal lines before a change
- keep up to `context` equal lines after a change
- merge nearby changes separated by `<= 2 * context` equal lines
- split hunks across larger equal ranges

## JSON shape

A diff details payload stores block hunks:

```json
{
  "kind": "diff",
  "version": 2,
  "diff": {
    "changes": [
      {
        "oldPath": "src/a.zig",
        "newPath": "src/a.zig",
        "stats": { "added": 1, "removed": 1 },
        "hunks": [
          {
            "oldStart": 10,
            "oldCount": 3,
            "newStart": 10,
            "newCount": 3,
            "blocks": [
              {
                "op": "context",
                "oldStart": 10,
                "newStart": 10,
                "lines": ["before"]
              },
              {
                "op": "replace",
                "oldStart": 11,
                "newStart": 11,
                "oldLines": ["old text"],
                "newLines": ["new text"]
              }
            ]
          }
        ]
      }
    ],
    "stats": { "added": 1, "removed": 1 }
  }
}
```

## projections

### unified diff

Unified text is derived from blocks:

- `context` -> ` ` lines
- `delete` -> `-` lines
- `insert` -> `+` lines
- `replace` -> old lines as `-`, then new lines as `+`

### TUI

The TUI consumes the structured details on result change:

```text
details JSON
  -> OwnedDocument
  -> diff_view rows / retained surface
  -> paint cached rows
```

The paint path must not parse JSON, run diff algorithms, or allocate semantic diff structures.

### extensions

Extensions can opt into the native diff renderer by returning the same `kind/version` details family. They do not need to be built-in tools.

## future extensions

Good next additions:

- `Line.has_newline` or equivalent EOF newline metadata
- inline word/char runs inside `ReplaceBlock`
- complexity guardrails and fallback behavior
- optional algorithm selection or histogram/patience backend

These should extend the block model rather than flatten replacements back into line side channels.
