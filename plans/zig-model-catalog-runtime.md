# Refactor model composition around a generated catalog

Status: Implemented and verified

## Intent

Replace `AgentSessionRuntime.ResolvedModel` as the model-system boundary with the Pi-shaped flow the runtime currently skips:

```text
compiled model catalog + admitted provider definitions + resolved credentials
    -> ModelRuntime
    -> ModelSelection { provider, model }
    -> canonical ai.Model
    -> AgentSession
```

The implementation remains internal. Process environment, persisted credentials, `models.json` loading, extensions, session replacement, and `src/main.zig` remain separate slices.

## Approved scope

- Port ZigAI's borrowed validated model catalog and deterministic JSON-to-Zig generation pattern.
- Seed only providers Zi can instantiate:
  - supported OpenAI entries from ZigAI;
  - OpenAI Codex entries explicitly curated by pinned Pi.
- Keep arbitrary OpenAI Chat Completions-compatible provider IDs available through admitted configuration; do not invent them as built-ins.
- Support three compiled API adapters:
  - `openai-completions`;
  - `openai-responses`;
  - `openai-codex-responses`.
- Preserve Codex as a distinct adapter and OAuth credential kind.
- Expose only models whose catalog entry and admitted provider definition both exist.

## Domain ownership

### `ai.ModelCatalog`

Owns trusted provider-scoped metadata:

```zig
pub const Entry = struct {
    identity: ModelIdentity,
    aliases: []const []const u8 = &.{},
    source_url: ?[]const u8 = null,
    profile: ModelProfile,
};

pub const Catalog = struct {
    entries: []const Entry,

    pub fn init(entries: []const Entry) Error!Catalog;
    pub fn resolve(self: Catalog, identity: ModelIdentity) ?Resolved;
};
```

The catalog borrows all storage. Validation owns non-empty identities, provider-scoped canonical/alias uniqueness, source safety, and coherent token limits. Catalog limits remain metadata; this slice does not add request clamping.

Catalog presence does not mean availability. A model becomes available only when `ModelRuntime` has installed its provider.

### Generated built-in snapshot

```text
data/model_catalog.json
    -> tools/model_catalog.zig
    -> src/ai/model_catalog_snapshot.zig
```

Build contracts:

```text
zig build update-model-catalog
zig build check-model-catalog
zig build test  # includes generator tests and drift check
```

The source is bounded to 1 MiB, rejects unknown JSON fields, requires deterministic ordering, validates enum ordering and duplicates, and writes the snapshot atomically.

### `coding_agent.ModelConfig`

Owns credential-blind provider composition over one catalog. A provider definition binds a string identity to a compiled adapter, display name, endpoint, and authentication kind. The built-in value contains only `openai` and `openai-codex`; user-file and extension overlays remain deferred.

```zig
pub const ProviderDefinition = union(enum) {
    openai_completions: OpenAi,
    openai_responses: OpenAi,
    openai_codex_responses: OpenAiCodex,
};

pub const builtin: ModelConfig;

pub fn findProvider(self: ModelConfig, provider_id: []const u8) ?*const ProviderDefinition;
pub fn resolve(self: ModelConfig, selection: ai.ModelIdentity) ?ai.ModelCatalog.Resolved;
```

`ModelConfig.resolve` returns only the intersection of a catalog entry and a defined provider. It does not imply that credentials make the provider available.

### `coding_agent.ModelRuntime`

Owns:

- a deep-copied catalog view;
- stable concrete provider implementations;
- the provider registry's borrowed erased views;
- copied endpoints, credentials, and Codex account IDs;
- secure credential cleanup;
- canonical selection resolution.

It receives an admitted credential-blind `ModelConfig` and already-resolved credentials. It installs no-auth providers immediately and credentialed providers only when their matching credential is present. It does not read paths, files, environment variables, or process state.

```zig
pub const Credential = union(enum) {
    api_key: { provider_id, value },
    openai_codex: { access_token, account_id },
};

fn init(
    allocator: Allocator,
    transport: ai.Transport,
    model_config: ModelConfig,
    credentials: []const Credential,
) !ModelRuntime;

fn resolve(self: *ModelRuntime, selection: ai.ModelIdentity) ?ai.Model;
```

The concrete provider-storage union remains private. Its tags identify compiled wire implementations, not provider or model identities.

### `AgentSessionRuntime`

Owns transport, `ModelRuntime`, and `AgentSession` in that disposal order. Creation receives `ModelConfig`, resolved credentials, and `ModelSelection`; it does not receive the old provider-specific `ResolvedModel` union.

## Required AI deepening

Current provider implementations contain one configured model, and `Model` invocation does not pass its identity to the concrete implementation. That prevents one provider implementation from serving a catalog of models.

Deepen the erased model ABI once:

```zig
VTable.invoke(context, result_allocator, scratch_allocator, io, identity, request, delivery)
```

`Model.invoke` passes its own immutable identity. Concrete providers then share endpoint/auth/transport state while encoding the selected model ID from the invocation identity.

Provider configuration becomes provider-scoped:

```zig
OpenAiCompatible.Config {
    provider_id,
    catalog,
    base_url,
    api_key,
    headers,
}
```

The OpenAI Responses and Codex providers follow the same catalog-backed model lookup. Canonical IDs are sent on the wire; aliases never are.

## OpenAI Responses adapter

Add `ai.providers.OpenAiResponses` rather than folding normal OpenAI and Codex behavior together.

Shared protocol code may decode the same Responses SSE events and encode common input/tool/history structures. Public entry points remain explicit:

```zig
encodeRequest(...)
encodeCodexRequest(...)
```

Normal OpenAI behavior:

- provider ID is data, with built-in `openai` as the initial definition;
- endpoint is `<base_url>/responses`;
- optional bearer API key;
- normal Responses handoff protocol identity;
- Responses input, tools, reasoning state, settings, streaming, usage, and failure mapping.

Codex behavior remains responsible for ChatGPT account extraction and Codex-specific URL, headers, and request fields.

## Catalog seed

The first source contains:

- ZigAI's supported `openai/gpt-5.6-sol` entry and `gpt-5.6` alias, mapped conservatively to Zi's existing profile vocabulary;
- pinned Pi's seven `openai-codex` entries:
  - `gpt-5.3-codex-spark`;
  - `gpt-5.4`;
  - `gpt-5.4-mini`;
  - `gpt-5.5`;
  - `gpt-5.6-luna`;
  - `gpt-5.6-sol`;
  - `gpt-5.6-terra`.

Profiles include only capabilities and settings supported by Zi and evidenced by the source. Unsupported `none`, `xhigh`, and `max` reasoning levels are not silently mapped into Zi's current enum.

Source URLs point at the exact upstream model documentation or pinned Pi source used for review.

No default model is selected in this slice. Defaults belong to later coding-agent model resolution policy.

## Stable ownership

```text
*AgentSessionRuntime
├── TransportOwner
│   ├── in-place HttpTransport
│   └── borrowed test Transport
├── ModelRuntime
│   ├── arena-owned copied catalog and configuration strings
│   ├── stable provider payloads allocated from the arena
│   ├── Provider.Registry with borrowed views
│   └── sensitive slices wiped before arena release
└── AgentSession
```

Initialization order is transport, copied catalog/configuration, provider payloads, registry, selected model, session. Cleanup reverses that order. Every partial-init path is covered by `errdefer` and exhaustive allocation-failure testing.

## Verification slices

### Slice 1: catalog and generation

- Catalog behavior tests for canonical IDs, provider-scoped aliases, collisions, invalid source, and invalid limits.
- Generator determinism, schema rejection, ordering, allocation failure, and drift checks.
- Generated snapshot validates and resolves every row.

Verification:

```text
zig build update-model-catalog
zig build check-model-catalog
zig build test
```

### Slice 2: normal OpenAI Responses

- Protocol fixtures cover input/tool encoding, empty tool output, reasoning/text/tool identity handoff, chunked SSE text/refusal/tool/reasoning output, usage, terminal variants, and provider errors.
- `StreamDecoder` rejects reuse of one Responses `output_index` with a different output-part kind and preserves final item IDs, phases, arguments, and encrypted reasoning state for replay.
- Provider integration uses `FakeTransport` and validates URL, content type, authorization, model ID, canonical aliases, and final response.

Verification:

```text
zig build test
zig build test -Doptimize=ReleaseSafe
```

### Slice 3: catalog-backed runtime

- One runtime installs multiple provider IDs and resolves canonical and aliased selections.
- The selected compatible model executes a real coding tool and provider follow-up.
- OpenAI Responses and Codex selections cross their real providers and protocol decoders.
- Caller buffers are mutated after creation to prove deep ownership.
- Exact credential/account allocations are zero after disposal.
- `checkAllAllocationFailures` covers complete construction and unwind.

Verification:

```text
zig build test --summary all
zig build test -Doptimize=ReleaseSafe
ziglint
git diff --check
zig build
```

Final result: 132/132 tests pass in Debug and ReleaseSafe. Catalog drift, `ziglint`, `git diff --check`, and the default build pass. Independent architecture, ownership/security, and Responses-protocol reviews found no remaining defect inside the approved slice.

## Deferred surfaces

- `ZiPaths` and runtime `models.json` loading.
- Persisted `auth.json` and permissions.
- Environment and CLI credential precedence.
- Codex browser/device OAuth acquisition and refresh.
- Extension provider registration.
- Provider model discovery.
- Model patterns, defaults, recent-model fallback, and picker behavior.
- Cost/accounting metadata.
- Request clamping against catalog limits.
- Session replacement and `src/main.zig`.
