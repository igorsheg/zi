# flow-owned transient data

## doctrine

transient heap data belongs to the flow that defines its lifetime. components borrow it. thread boundaries deep-copy it. only stable catalogs may be borrowed long-term.

## ownership by lifetime

| lifetime | owner |
| --- | --- |
| process / session | domain or session owner |
| one TUI flow / overlay | flow owner |
| one component interaction | component |
| cross-thread hop | message payload via `msg_allocator` |
| static immutable catalog | producer |

if the lifetime boundary is unclear, the owner is unclear too.

## rules

### components borrow, flows own

`ListPicker` owns only interaction state:
- query buffer
- selected index
- filtered scratch

heap-backed rows, labels, descriptions, previews, and search strings belong to the flow that opened the picker.

### thread boundaries are hard boundaries

anything crossing TUI ↔ agent must be:
- deep-copied
- allocated from `msg_allocator`
- freed by the receiver side

no borrowed slice survives a queue hop.

### stable catalogs may be borrowed

safe long-lived borrows require all three:
- immutable producer
- stable lifetime
- documented contract

examples in zi:
- model catalog for session lifetime
- oauth providers table
- static literals

if UI derives new strings from stable data, those derived strings are flow-owned.

### no provenance heuristics

ban shapes like:
- `free if ptr != other_ptr`
- `sometimes borrowed, sometimes owned`
- `free on cancel but not on select`
- `return ArrayList.items and free by len later`
- `return a shortened slice and free it as if it were the original allocation`

if teardown depends on guessing provenance, the design is lying.

## reference shape

```text
                  tui thread only

  domain api / stable catalog
             |
             v
       flow owner
       - owns fetched rows
       - owns derived ui rows
       - owns derived search text
       - owns overlay handle
             |
             v
        ListPicker
        - borrows rows/search text
        - owns query + filtered scratch
             |
             v
   deep-copy minimal selected payload
        into msg_allocator
             |
             v
        request / event queue
```

## picker audit

### bucket a — stable borrowed data only

leave these simple:
- settings picker
- thinking picker
- login provider picker

### bucket b — heap-backed transient flow

these need explicit flow owners:
- resume picker
- model picker
- future searchable dynamic pickers

## current application

`src/tui/interactive.zig` now treats `/resume` and `/model` as flow-owned overlays:
- opening a picker creates a dedicated flow
- `ListPicker` borrows from the flow
- `ListPicker` selection callbacks now carry `Selection { item, source_index }` so flows can resolve the owning row without string matching
- cancel, select, and interactive deinit all converge on one teardown path
- cross-thread payloads still clone exactly once into `msg_allocator`
