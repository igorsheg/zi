# zi docs

this directory holds durable repo docs.

## what belongs here

- architecture boundaries
- runtime ownership
- extension doctrine and contracts

## what does not belong here

docs here should not mirror the codebase line by line.

if a doc is mostly:
- file inventories
- temporary migration plans
- exact call order that changes with refactors
- scratch notes for one implementation pass

put it in a bead, pr, or `docs/archive/` if it still matters.

## map

- `architecture.md` — system shape and owner boundaries
- `runtime.md` — mailbox/snapshot runtime doctrine
- `conversation-state.md` — agent-owned conversation snapshot and hot-frontier contract
- `agent-events-and-transport-boundaries.md` — public event/persistence/wire boundaries vs internal transport seams
- `extensions.md` — extension model and links to v2 contracts
- `runtime-roots.md` — runtime-root/discovery/precedence contract for extension v2
- `extensions-lifecycle.md` — lifecycle, namespace, and scheduler contract for extension execution
- `extensions-events.md` — observer/interceptor contract for extension-visible semantics
- `extensions-retained-objects.md` — retained-object ownership and publication contract
- `extensions-tools.md` — tool definition, phases, overrides, and renderer inheritance contract
- `extensions-jobs-subagents.md` — jobs/subagents/`zi.system` contract
- `extensions-ui-contract.md` — host-owned ui and custom presentation contract
- `extensions-state-rebinding.md` — state scopes, persistence, and rebinding contract
- `extensions-providers.md` — provider registration, activation, and model-visibility contract
- `extensions-commands-flags-actions.md` — command, shortcut, flag, and host-action contract
- `extensions-conformance-matrix.md` — parity/conformance matrix against pi-mono capability classes
- `extensions-cutover-boundaries.md` — repo-facing v2 cutover boundary plan for consumers and seams
- `adr/extensions-v2-cutover.md` — root cutover doctrine for extension system v2
- `adr/conversation-render-v2-cutover.md` — root cutover doctrine for conversation/render v2
