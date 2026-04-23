# runtime roots, discovery, and precedence

## status

contract for `zi-fex.2`.
it follows the [v2 cutover adr](./adr/extensions-v2-cutover.md) and the runtime ownership rules in [runtime.md](./runtime.md).

## decision

- runtime roots are the primary loading abstraction.
- every loader and registry reduces to one canonical ordered root list.
- direct file/path inputs are ingress conveniences; precedence starts only after they normalize into roots.
- collisions are resolved by **first claimant wins** in the relevant registration class, with the canonical root order deciding who claims first.
  provider claims may keep same-name surviving registrations behind the active claimant, so teardown/unregister restores the next surviving claimant for that provider name deterministically instead of always falling straight to baseline.
- package installation is not a second architecture. it materializes more roots on disk.

## runtime root

a runtime root is a directory-like resource container.
a root may live on disk or be virtual/embedded, but it exposes the same anchors:

```text
<root>/
├─ extensions/
│  ├─ foo.lua
│  └─ bar/
│     └─ init.lua
├─ lua/
├─ prompts/
├─ skills/
├─ themes/
├─ agents/
└─ after/
   ├─ 00-base/
   └─ 10-local/
```

rules:

- `extensions/` holds loadable extensions.
  - flat single-file extension: `extensions/<id>.lua`
  - bundled multi-file extension: `extensions/<id>/init.lua`
- `lua/` holds shared lua modules for that root.
- `prompts/`, `skills/`, `themes/`, and `agents/` are root-owned resource namespaces.
  their namespace-specific file-shape rules live in their own contracts; this contract defines ownership and precedence.
- `after/` is optional.
  each direct child of `after/` is itself a runtime root, discovered lexically and inserted immediately after the parent root.

within a root, discovery is convention-based and deterministic:

- no code execution is needed to discover static roots or anchored files.
- each anchor is walked in lexical order.
- extension ids are derived from `<id>.lua` or `<id>/init.lua`.

## ingress normalization

all capability classes reduce to root descriptors before any loader-specific work starts.

```text
cli roots/paths ───────┐
settings roots/paths ──┼─> normalize ─> canonical ordered root list ─> discover/load
package installs ──────┤
default roots ─────────┤
builtin roots ─────────┘
```

normalization rules:

- a path to a runtime-root directory becomes one root.
- a path to `<name>.lua` becomes a synthetic root that contributes one extension with id `<name>`.
- a path to `<name>/` with `init.lua` becomes a synthetic root that contributes one bundled extension with id `<name>`.
- builtin resources are exposed as builtin roots, even if they are embedded instead of on disk.
- package entries from `settings.json` do not add a new loading mode.
  install/update logic materializes package contents on disk, then discovery treats those directories as ordinary runtime roots.

## canonical root order

precedence is derived from one ordered root list, highest to lowest:

1. explicit cli-provided roots and paths, in cli order
2. user-scope settings-provisioned roots and paths, in settings order
3. user-global root
4. user-scope package-provisioned roots/resources, in settings order
5. project-scope settings-provisioned roots and paths, in settings order
6. project-local root
7. project-scope package-provisioned roots/resources, in settings order
8. builtin roots/resources

that is the concrete form of the bead rule:

```text
explicit > user > project > builtin
```

inside a scope, direct roots beat package roots.
that keeps hand-authored local resources above installed package content, while still letting settings order explicit extra roots.

scope rules:

- the user-global root is the canonical user root, typically the agent directory.
- the project-local root is the canonical project root, typically `<project>/.zi`.
- settings-provisioned roots inherit scope from the settings file that declared them.
- package-provisioned roots inherit scope from the settings file that declared the package.
- builtins are always last.

### derived roots

some roots create more roots.
those derived roots do not get their own precedence system.
they inherit the owner root's scope and slot.

derived-root order for a given owner root:

1. static `after/` child roots, lexical order
2. extension-provided additional resource roots, in extension discovery order, then in emission order within that extension

extension-provided additional resource roots come from the `resources_discover` seam.
they may contribute `lua/`, `prompts/`, `skills/`, `themes/`, and `agents/`.
they do **not** participate in extension discovery for the current session.
if a package or extension wants to ship more loadable extensions, those extensions must live in a normal materialized root that discovery can see before code runs.

## collision model

collision resolution is **per registration class**.

that means:

- extension discovery is one registration class keyed by extension id
- skills are one registration class keyed by skill name
- prompts are one registration class keyed by prompt name
- themes are one registration class keyed by theme name
- shared lua modules are one registration class keyed by module name
- runtime extension registrations such as tools, providers, interceptors, shortcuts, flags, and similar future registries each resolve collisions on their own canonical key
- commands are a merged slash-surface registration class: canonical name still follows root precedence for ordering, but duplicate command names may stay callable through host-resolved invocation names as defined in [commands/flags/actions](./extensions-commands-flags-actions.md)
- `agents/` is ordered aggregation, not a collision registry

the default rule is:

1. walk the canonical root list in order
2. discover entries in deterministic within-root order
3. first claimant for a key wins
4. later claimants are ignored and may emit diagnostics, unless that registration class explicitly keeps same-key surviving claims for deterministic restoration when the active claim is removed

commands are the explicit exception above because their visible surface is ordered aggregation over colliding registrations, not silent drop.
providers also keep the same visible first-claimant rule, but same-name claims may retain deterministic fallback state behind the active claimant so unregister/teardown can restore the next surviving claim before baseline.

this keeps precedence out of ad hoc loader code.
a loader decides only its key shape and whether its visible surface is first-claimant or ordered aggregation, not its own source order.

## root-level resource behavior

### extensions

`extensions/` is the only static extension-discovery anchor.
zi discovers flat and bundled extensions there without executing code.

### skills, prompts, themes, agents

a root may contribute these directly from its anchors.
extensions may also contribute more of them through derived roots from `resources_discover`.
those derived roots keep the declaring root's precedence.

### packages

`settings.json` package installation reduces to:

1. resolve package source
2. materialize package contents on disk
3. expose one or more runtime roots from that materialized content
4. feed those roots into the same canonical ordered root list

filters in `settings.json` narrow which anchors a package exports.
they do not create a second discovery architecture.

## lua module loading

current static `package.path` mutation is not enough for v2.
v2 needs root-aware lua module resolution.

module lookup for extension `E`:

1. `E`'s private module root
   - flat extension `extensions/foo.lua` → private root `extensions/foo/`
   - bundled extension `extensions/foo/init.lua` → private root `extensions/foo/`
2. shared `lua/` anchors from the canonical ordered root list
3. lua's builtin/default searchers, if still enabled

consequences:

- root-level `lua/` becomes the shared-module surface for a runtime root.
- extension-relative modules work for both flat and bundled authoring.
- shared-module collisions follow the same root precedence as every other registration class.
- `package.path` built only from top-level `extensions/` directories is insufficient because it cannot express root-level `lua/`, root order across all capability classes, or caller-relative private modules.

## session lifecycle

new-session, resume, and reload all rebuild discovery from the same source of truth:

- current explicit cli roots/paths for this process
- current merged settings
- current materialized package roots on disk
- current builtin roots

none of those flows get bespoke precedence.
they all rerun normalization, rebuild the canonical root list, and then rediscover resources from that list.
session state may survive; discovery state does not.

## seams this contract collapses

this contract exists to replace a few drifting seams with one source of truth:

- `ResourceLoader` stops owning separate precedence rules per namespace.
  it should consume the canonical root list and load namespaces from it.
- settings getters for `packages`, `extensions`, `skills`, `prompts`, and `themes` stop feeding bespoke loaders directly.
  they only contribute root inputs.
- lua module loading stops assuming top-level `extensions/` directories are the whole module graph.
- new-session, resume, and reload stop rebuilding resources through subtly different call paths.

## non-goals

this contract does not define:

- package-manager transport, cache layout, or update policy
- the detailed file format of prompts, skills, themes, or agents
- lifecycle/scheduler details beyond what [extensions-lifecycle.md](./extensions-lifecycle.md) defines
