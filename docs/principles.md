# Principles

zi is pi-mono reimplemented in zig.

That sentence carries most of the doctrine.

## 1. Parity first

pi-mono is the product spec.

When behavior, data shapes, or product seams drift, the default move is to close the drift. Simplification is only valid if capability and extensibility stay at pi-mono level.

## 2. Zig is an implementation advantage

Zig should improve:
- ownership clarity
- startup and memory behavior
- hot-path performance
- deployability

It should not be used as an excuse to collapse layers, remove seams, or narrow the product.

## 3. Preserve the stack

zi is not one program. It is a stack:
- shared data formats
- provider substrate
- terminal UI
- stateful agent
- product composition root

A layer should own one kind of problem and stay reusable by the layer above it.

## 4. Do not collapse boundaries

If a concern belongs to a higher layer, do not push it downward just because the code is nearby.

Examples:
- persistence and compaction are not agent-loop concerns
- UI rendering is not provider logic
- provider quirks are not TUI concerns

## 5. Ownership is architecture

Every long-lived resource needs one obvious owner.

Across threads, ownership is explicit.
Across flows, transient data has one lifetime owner.
If ownership is ambiguous, the design is ambiguous.

## 6. Wire formats are contracts

Session files, events, message shapes, and extension-visible payloads are product contracts, not local implementation details.

Use the same observable behavior as pi-mono. Do not invent near-miss alternatives.

## 7. Build with a consumer

A layer is only real when something above it uses it.

Vertical slices beat isolated subsystems because drift becomes visible early.

## 8. Docs should describe invariants

Good docs explain:
- why a boundary exists
- what must stay true
- what belongs where

Bad docs try to freeze transient implementation details.
