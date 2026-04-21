# extension system v2 cutover doctrine

## status

accepted for `zi-fex.1`.

this is the root adr for extension-system v2 contract work.

## intent

replace zi's current extension architecture with one truthful v2 system that matches the post-refactor runtime shape.

## why

zi's runtime is explicit about ownership:
- agent thread owns lua, extension registries, session state, and extension execution
- tui owns presentation
- cross-owner work goes through mailboxes
- render-speed reads come from published snapshots

a compatibility-first redesign would preserve the wrong seams: direct tui → lua exceptions, dual registration paths, and internal transport details leaking into the product api. that would keep v1's constraints alive under new names.

## decision

extension system v2 is a **nuclear cutover**.

rules:
- v2 is a replacement architecture, not an evolution layer on top of v1
- after cutover, zi exposes one public extension api
- internal request/mailbox/snapshot transport is host runtime machinery, not extension api
- extension execution stays agent-owned; the tui never calls lua directly
- any built-in extension, host callsite, runtime seam, or tui/agent bridge broken by the redesign moves to v2 instead of getting a bridge back to v1
- the cutover must preserve or expand pi-mono-level extension capability

## forbidden compatibility theater

the following are rejected:
- shipping both v1 and v2 registration or loading surfaces
- adapter layers that accept v1-shaped tools, hooks, events, or ui contracts and translate them into v2 at runtime
- facades that keep old built-ins or host callsites alive unchanged while a hidden shim does the real v2 work
- direct tui → lua hot-path calls, ownership exceptions, or shared-state reach-through added to save a refactor
- exposing internal mailbox payloads, snapshot shapes, or other owner-boundary transport as the public extension contract
- narrowing product capability just to avoid refactoring broken seams

## consumers that move together

the cutover boundary is repo-wide for every consumer that speaks the extension contract:

- built-in extensions and bundled extension-provided behavior
- extension discovery, load, bind, and runtime-root provisioning
- host callsites that invoke extension-visible tools, hooks, commands, ui, providers, or runtime rebinding
- runtime seams and tui/agent bridges for extension-visible status, progress, widgets, and subagent flows
- session/runtime replacement paths such as new-session, resume, fork, and reload
- user and project extensions in the field

there is no promise that a v1 extension continues to run after v2 lands. the promise is that zi has one truthful extension api after the cut.

## runtime anchor

v2 contracts must fit zi's runtime model:

- **agent-owned lua** — lua state, registries, scheduler, and extension execution live on the agent thread
- **host-owned boundaries** — cross-thread mutation and work use mailbox/request-style submission
- **snapshot reads** — the tui renders published semantic state instead of reading agent-owned internals
- **host-owned retained objects** — progress, ui surfaces, subagent state, and similar long-lived objects stay host-owned even when extensions configure or observe them

extension apis should describe product semantics — tools, events, commands, ui capabilities, providers, lifecycle — not leak queue shapes, wake mechanics, or view-local transport blobs.

## consequences

follow-on v2 contract docs should treat this adr as settled ground.

that means:
- contract docs cite this adr instead of reopening compatibility questions
- broken host seams are refactored, not grandfathered
- v1 docs, examples, and runtime paths are disposable once the v2 replacements land
- future extension work is judged against one question: does it fit the agent-owned lua + mailbox/snapshot runtime model without compatibility theater?
