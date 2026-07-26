# Building-block strategy

- Status: active
- Adopted: 2026-07-26

## Product direction

Zi is a dependable, inspectable coding-agent substrate with an opinionated reference terminal client. It should be useful as installed, but its larger leverage comes from software built with, around, and on top of it.

Zi therefore optimizes for being configured, extended, driven as a process, embedded through deliberate public contracts, and forked. Mainline remains small and purposeful: it proves the substrate, establishes excellent defaults, and absorbs ecosystem behavior only after that behavior has demonstrated broad value.

## Goals

1. **Teach one habit at a time.** A user should be able to add behavior without understanding Zi's internal object graph.
2. **Use the least powerful sufficient mechanism.** Prompt rules precede skills, skills precede executable extensions, and extensions precede forks.
3. **Make external contracts dependable.** Every supported building block has explicit lifecycle, cancellation, bounds, versioning, diagnostics, examples, and release-shaped acceptance.
4. **Keep the mainline application stable.** Niche behavior belongs outside mainline unless repeated use proves it should become common policy.
5. **Let downstream work perform R&D.** Working extensions, clients, wrappers, and forks are stronger product evidence than speculative feature requests.
6. **Keep quality asymmetric.** Downstream artifacts may be narrow or disposable; Zi's ownership, trust, fault isolation, durability, and shutdown guarantees may not be.

## Customization ladder

Use the first level that can express the behavior:

1. `AGENTS.md` and system-prompt policy;
2. skills and prompt templates;
3. settings, CLI composition, text mode, and JSON mode;
4. trusted extensions for executable behavior;
5. RPC for external applications and language-neutral process composition;
6. a curated coding-agent SDK after real external consumers establish its contract;
7. a separate client or fork for substantially different product behavior.

Repository package boundaries are not automatically public compatibility boundaries. In particular, the current broad `@with-zi/coding-agent` exports remain private until concrete external consumers justify a smaller supported interface.

## Feature routing

| Requested behavior                              | Default home                                 |
| ----------------------------------------------- | -------------------------------------------- |
| Universal coding-agent invariant or policy      | `AgentSession` or another coding-agent owner |
| Repository knowledge or repeatable instructions | prompt rule, skill, or prompt template       |
| Specialized executable behavior                 | extension                                    |
| Editor, service, or non-TypeScript integration  | RPC                                          |
| Substantially different interaction model or UI | separate client or fork                      |

A feature moves into mainline when it protects a universal invariant, is required by the reference product, or has repeated evidence across independent downstream implementations. Mainline does not add a generic hook merely because a future integration might need one.

## Supported building blocks

The intended externally supported surfaces are, in order:

1. the documented `zi` CLI and JSON event contracts;
2. a narrow `@with-zi/extension-api` package;
3. a versioned RPC process protocol;
4. a curated coding-agent SDK only after repeated external pressure.

The imperative OpenTUI implementation, session managers, stores, and private extension protocol remain implementation details unless a later decision promotes a specific interface.

## Completion standard

A public building block is complete only when it has:

- one narrow documented interface;
- one complete copyable example;
- compiled-release acceptance on every release platform;
- explicit ownership, lifecycle, cancellation, and shutdown semantics;
- bounded input, output, queues, retained state, and waits;
- source-attributed diagnostics;
- compatibility and versioning expectations;
- no dependency on private Zi modules.

Adoption is measured by useful downstream extensions, process clients, integrations, and forks as well as direct Zi use. No product telemetry is required to pursue that evidence.

## Non-goals

This strategy does not mean exporting every module, creating a universal plugin framework, weakening mainline quality, or accepting arbitrary UI callbacks. Deep internal modules and narrow external interfaces remain the desired shape.
