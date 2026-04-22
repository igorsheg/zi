# providers: registration, activation, and model visibility

## status

contract for `zi-fex.10`.

current implementation slice: `zi.register_provider(name, { api, base_url })` and `zi.unregister_provider(name)` now queue before bind, apply immediately after bind, and revoke on unbind/teardown. model catalog visibility rebuild, oauth/ui work, headers/auth config, and custom stream handlers are still follow-up work.
it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-events.md](./extensions-events.md), [extensions-retained-objects.md](./extensions-retained-objects.md), [extensions-state-rebinding.md](./extensions-state-rebinding.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

adjacent seams stay split on purpose: [runtime roots](./runtime-roots.md) defines precedence, [lifecycle](./extensions-lifecycle.md) defines `load/register -> bind -> unbind -> teardown`, [events/interceptors](./extensions-events.md) defines `before_provider_request`, and [state rebinding](./extensions-state-rebinding.md) defines what survives reload/new/resume/fork.

## decision

- providers are a first-class extension registration class.
- provider registration is namespace-owned at load/register, becomes active at bind, and is revoked at unbind/teardown.
- queued pre-bind registration and live post-bind registration are the same contract observed in different lifecycle phases.
- model visibility is coupled to provider registration through the model-registry view; provider registry and model catalog stay distinct owners.
- `before_provider_request` remains a request-payload transform seam, not auth/config/provider registration.

this is the smallest contract that fits the rest of v2: lifecycle already treats providers as namespace-owned registrations that become active only once a session binds and disappear again at unbind/teardown (`docs/extensions-lifecycle.md:10-18`, `docs/extensions-lifecycle.md:52-61`, `docs/extensions-lifecycle.md:104-158`); events already reserves `before_provider_request` for middleware over the semantic provider request payload (`docs/extensions-events.md:134-136`); rebinding already says provider registrations die with the generation while provider instances die at unbind (`docs/extensions-state-rebinding.md:18-26`, `docs/extensions-state-rebinding.md:127-131`, `docs/extensions-state-rebinding.md:377-409`).

## model

```text
canonical root order
        │
        v
┌───────────────────────────────────────────────────────────────────────┐
│ load/register                                                        │
│  namespace n claims provider name p with config + model metadata     │
│                                                                       │
│  runtime unbound  ───────────────────────────────┐                    │
│                                                  v                    │
│                                           pre-bind queue              │
│                                           owner: namespace claim      │
└──────────────────────────────────────────────────┬────────────────────┘
                                                   │
                                                   v
┌───────────────────────────────────────────────────────────────────────┐
│ bind                                                                  │
│  activate surviving claims for the bound generation                    │
│    -> host provider registry view                                      │
│    -> model registry view over built-ins + visible provider models     │
│                                                                       │
│  queued registration and live registration converge here:              │
│  same claim, same precedence, different lifecycle phase                │
└──────────────────────────────────────────────────┬────────────────────┘
                                                   │
                                                   v
┌───────────────────────────────────────────────────────────────────────┐
│ steady state                                                          │
│  register/unregister after bind mutates the same contract live         │
│  `before_provider_request` may rewrite request payload only            │
│  it does not claim providers, persist credentials, or swap ownership   │
└──────────────────────────────────────────────────┬────────────────────┘
                                                   │
                                                   v
┌───────────────────────────────────────────────────────────────────────┐
│ session_shutdown -> unbind -> teardown                                │
│  revoke namespace claims                                               │
│  drop session-live provider instances / bound services                 │
│  rebuild visible provider + model views without the revoked claims     │
│  destroy remaining generation-owned registration state                 │
└───────────────────────────────────────────────────────────────────────┘
```

## current zi evidence

- `src/coding_agent/extensions/api.zig:64-81` installs only `zi.register_tool`, `zi.on`, and `zi.spawn` into the public `zi` table. there is no public `zi.register_provider`. `rg "register_provider" src/coding_agent/extensions/api.zig` returns no matches.
- `src/coding_agent/extensions/registries/provider_queue.zig:1-18` and `src/coding_agent/extensions/registries/provider_queue.zig:40-78` already define `ProviderQueue` as pending custom-provider registrations awaiting bind, with `enqueue`, `drain`, and `count`.
- `src/coding_agent/extensions/runner.zig:155-159` says `provider_queue` is drained by `bindRuntime`, but `src/coding_agent/extensions/runner.zig:422-425` currently only flips `self.runtime` from `stub` to `bound`. no queue flush happens there today.
- `src/ai/provider.zig:62-132` is the live provider registry today. it is host-side and mutable, but it is keyed by api identifier string, not by extension provider name.
- `src/coding_agent/model_registry.zig:1-99` makes the model registry a session-owned, read-only snapshot built at session init and immutable for the session lifetime. there is no public register/remove path there today.

those facts matter because they show zi already has the right pieces, but not yet the full public provider contract: a load-time queue, a live provider registry, and a separate model catalog. this doc keeps those owners split instead of collapsing them into one bag.

## parity target

pi-mono sets the compatibility bar in `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts`:

- `registerProvider(name, config)` and `unregisterProvider(name)` are public extension api methods (`types.ts:1143-1210`).
- the same api is queued during initial extension load and immediate after bind: initial-load calls queue until the runner binds (`types.ts:1151-1154`), post-bind calls take effect immediately (`types.ts:1204-1205`), and shared runtime state models that split explicitly as `pendingProviderRegistrations`, `registerProvider`, and `unregisterProvider` (`types.ts:1347-1358`).
- `ProviderConfig` includes `baseUrl`, `apiKey`, `api`, `streamSimple`, `headers`, `authHeader`, `models`, and `oauth` (`types.ts:1220-1248`).
- provider model config carries model-local `headers` and `compat` overrides (`types.ts:1251-1273`).

zi does not need pi-mono's exact internal storage layout. it does need the same visible contract classes: register, unregister, pre-bind queueing, post-bind immediacy, provider-level config, and model-level compatibility metadata.

## ownership and collisions

- the canonical registration key is provider name.
- the same canonical root precedence rules apply here as everywhere else.
- unregister must restore built-ins and reapply any remaining dynamic providers deterministically.
- provider registry ownership stays host-side; the extension namespace owns the claim and teardown responsibility.

why:

- runtime-root precedence already says each registration class resolves collisions by canonical key under canonical root order, with first claimant winning (`docs/runtime-roots.md:10-15`, `docs/runtime-roots.md:121-143`). providers are not a special case.
- lifecycle already says merged registries are shared views over namespace-owned registrations and names providers as one of those retained classes (`docs/extensions-lifecycle.md:10-18`, `docs/extensions-lifecycle.md:41-61`).
- retained objects already split provider registrations from provider instances (`docs/extensions-retained-objects.md:77-79`). that split should survive the public api too.
- pi-mono unregister semantics explicitly restore overridden built-ins when a named provider goes away (`types.ts:1197-1209`). deterministic reapplication is not extra polish; it is part of visible behavior.

current zi adds one constraint here: `src/ai/provider.zig:62-132` is api-keyed today, while pi-mono's public api is provider-name keyed (`types.ts:1195`, `types.ts:1210`, `types.ts:1350-1358`). this contract resolves that mismatch by making provider name the extension claim key while letting the host project those claims into whatever runtime lookup tables it needs.

## relation to auth and config

current zi keeps auth storage host-internal. `src/coding_agent/model_registry.zig:4-6` and `src/coding_agent/model_registry.zig:79-98` show model availability reading a borrowed `*AuthStorage` through host code, not through extension-owned objects. [extensions-state-rebinding.md](./extensions-state-rebinding.md) already says durable extension stores are host-owned and keyed separately from live runtime handles (`docs/extensions-state-rebinding.md:21-23`, `docs/extensions-state-rebinding.md:128-131`).

that means:

- `oauth`, custom headers, `apiKey`, `authHeader`, `baseUrl`, `api`, and model metadata belong in the provider registration contract because pi-mono exposes them there (`types.ts:1220-1248`, `types.ts:1251-1273`).
- credential persistence, token refresh storage, and secret lifetime remain host-owned.
- `before_provider_request` stays narrow. it may rewrite request payload on the way to the provider (`docs/extensions-events.md:134-136`), but it is not the seam for credential storage, provider registration, or provider teardown.

## relation to state and rebinding

provider instances are session-live handles, not durable state.
reload, new, resume, and fork rebuild the active provider view from surviving registrations plus host-owned persisted config; they never reuse old provider pointers.

why:

- rebinding already classifies provider registrations as namespace/generation state and provider instances as session-live handles (`docs/extensions-state-rebinding.md:127-131`, `docs/extensions-state-rebinding.md:377-409`).
- reload/new/resume/fork already rebuild fresh generations and fresh session-live handles (`docs/extensions-state-rebinding.md:170-317`). provider state has to fit that rule too.
- current live providers are runtime handles with `{ ptr, vtable }` identity (`src/ai/provider.zig:7-60`). that is a live object shape, not a durable state shape.
- the current model registry is rebuilt at session init and then frozen for the session lifetime (`src/coding_agent/model_registry.zig:1-99`). so model visibility after rebinding has to come from reconstruction, not pointer survival.

## non-goals

this doc does not define:

- the exact lua api spelling beyond the parity class requirement that zi expose provider register/unregister as public extension registration seams
- the host-internal file format or storage backend for provider config, oauth credentials, or auth refresh state
- provider selection ux, `/login` ui details, or any other presentation policy
- the low-level in-memory layout of `src/ai/provider.zig` or `src/coding_agent/model_registry.zig`
- a catch-all interceptor that merges request rewriting, auth storage, provider registration, and teardown into one seam
- pointer-stable provider or model objects across reload/new/resume/fork
