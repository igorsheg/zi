# Align global model configuration with Pi

Status: Implemented and verified on 2026-08-19

## Intent

Use Pi's `models.json` as the product-level configuration contract while keeping Zi's provider surface deliberately narrow and its Zig implementation independently owned.

This replaces the first Zig-only source schema. It is not a compatibility parser for the TypeScript Zi implementation: the pinned Pi coding-agent defines the user-facing data model, Zi selects the supported subset, and the loader projects validated external data into the existing credential-blind `ModelConfig`.

```text
Pi-shaped global models.json
    -> bounded typed ModelConfigSnapshot
    -> supported adapter/profile projection
    -> credential-blind ModelConfig
```

The private `ModelConfig`, model catalog, model runtime, and credential resolution interfaces do not change.

## Reference contract

Pinned Pi stores providers in an ID-keyed object:

```json
{
  "providers": {
    "custom-openai": {
      "name": "Custom OpenAI",
      "baseUrl": "https://example.test/openai/v1",
      "api": "openai-responses",
      "models": [
        {
          "id": "custom-reasoning-model",
          "name": "Custom Reasoning Model",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 272000,
          "maxTokens": 128000
        }
      ]
    }
  }
}
```

Provider IDs remain data: the object key becomes the canonical provider ID. `api` identifies the compiled wire adapter, matching the settled architecture that adapter tags are not provider identities.

The file has no Zi-specific `version`, provider array, `authentication`, snake-case fields, profile capability arrays, settings arrays, or custom model aliases.

## Supported Pi subset

Zi admits new custom providers using exactly these Pi adapter values:

- `openai-completions`
- `openai-responses`

Every custom provider requires provider-level `baseUrl`, `api`, and at least one model. `name` defaults to the provider ID. A model-level `api` or `baseUrl` is accepted only when it equals the provider-level value; Zi's current provider definition intentionally has one adapter and endpoint per provider.

Custom provider IDs may not collide with `openai` or `openai-codex`. Pi's built-in overlay and model-override behavior remains deferred until Zi has a concrete need for built-in endpoint replacement.

Custom providers use API-key authentication. Credential bytes do not enter `models.json`: Pi's `apiKey`, OAuth, header interpolation, `authHeader`, and command/environment configuration values are rejected. `--api-key`, the future global credential store, and admitted environment policy remain the credential owners.

Codex is never configurable through `models.json`; `openai-codex-responses` remains the distinct built-in OAuth provider.

## Model projection

The loader accepts the supported Pi model fields and derives Zi's effective profile. Configuration describes upstream capability; the effective profile is its intersection with the compiled adapter and current Zi feature surface.

| Pi field                  | Zi projection                                                                    |
| ------------------------- | -------------------------------------------------------------------------------- |
| `id`                      | canonical provider-scoped model ID                                               |
| `name`                    | validated metadata; display-name storage remains deferred                        |
| `api`, `baseUrl`          | must inherit or equal the provider definition                                    |
| `reasoning`               | enables thinking only for the Responses adapter                                  |
| `thinkingLevelMap`        | identity mappings intersect with Zi's `minimal` through `high` efforts           |
| `input`                   | must contain `text`; `image` is accepted as upstream metadata but not advertised |
| `contextWindow`           | profile context window; Pi default `128000`                                      |
| `maxTokens`               | profile maximum output; Pi default `16384`                                       |
| `cost`                    | bounded and validated metadata; normalized cost accounting remains deferred      |
| supported `compat` fields | bounded and validated metadata; cannot enable uncompiled behavior                |

`openai-completions` profiles advertise streaming, tools, parallel tool calls, and the settings its current codec writes: temperature, top-p, maximum output, stop sequences, and seed. They do not advertise thinking or reasoning effort because Zi's compiled Chat Completions codec does not implement them.

`openai-responses` profiles advertise streaming, tools, parallel tool calls, maximum output, and—when `reasoning` is true—thinking plus the identity-mapped reasoning efforts implemented by the codec.

Images remain unsupported. Accepting `input: ["text", "image"]` does not advertise image input or admit image content; it records that the upstream model can accept images while the current Zi adapter intersection cannot.

Duplicate provider keys, duplicate model IDs, empty IDs, unsupported adapter values, incoherent limits, model-only images, non-identity supported thinking mappings, and conflicting model-level adapter/endpoints invalidate the whole file. No partial custom configuration is published.

## Zig implementation

Keep `ModelConfigSnapshot.load(allocator, io, paths)` as the one deep module interface. Replace only its external source types and projection implementation.

Use ZigAI's proven implementation mechanics without importing its product model:

- preflight complete JSON with explicit document, value, nesting-depth, and collection bounds;
- decode into typed structs with `std.json.ArrayHashMap` for the provider record;
- retain Pi's omitted, explicit `null`, and string thinking-map states as a private tri-state wire value;
- reject unknown fields in the admitted Pi subset;
- allocate decoded strings and the projected catalog/config in one arena;
- preserve stable domain diagnostics and allocation failure;
- settle every partial initialization and allocation failure;
- preserve provider order from the input object for deterministic projection.

The scanner stays private to `ModelConfigSnapshot` until a second persisted owner proves a shared bounded-JSON module is warranted.

## Program changes

```text
plans/
+ zig-pi-model-config.md                 # product contract and projection
~ zig-global-model-config.md             # marked superseded at the source-schema layer

src/coding_agent/
~ ModelConfigSnapshot.zig                # replace source schema and projection
~ AgentSessionRuntime.zig                # custom Responses vertical behavior
```

No second parser, migration alias table, TypeScript import, runtime format switch, or public configuration type is added.

## Behavior coverage

- Load a representative custom `openai-responses` provider shape, including reasoning, image metadata, cost tiers, thinking mappings, and supported compatibility metadata.
- Resolve the provider/model canonically and compose `.openai_responses` with the configured endpoint.
- Exercise the existing private runtime path through FakeTransport, including a Responses tool loop, canonical model on the wire, and bearer credential.
- Load one `openai-completions` custom provider and prove the distinct endpoint and profile projection.
- Prove Pi defaults for omitted model name, input, cost, context window, and maximum output.
- Reject unsupported adapters, credential-bearing fields, built-in collisions, conflicting model overrides, duplicates, malformed URLs, unsupported-only input, unknown fields, and every JSON/resource bound.
- Prove invalid input retains built-ins with one diagnostic and never partially publishes custom providers.
- Settle every allocation failure and prove snapshot ownership survives source/path mutation.

The test fixture is embedded repository evidence. Tests never read or modify the user's actual `$HOME/.zi/agent/models.json`.

## Deferred Pi behavior

- Built-in provider overlays and `modelOverrides`.
- Per-model adapter or endpoint variation within one provider.
- `apiKey`, configured environment references, commands, headers, and header interpolation.
- OAuth providers and custom Codex configuration.
- Compatibility knobs not implemented by Zi's codecs.
- Cost accounting and pricing presentation.
- Image admission and transport.
- Extensions, provider discovery, refreshed catalogs, and hot reload.

These fields are not silently ignored when they could change request or authentication behavior.

## Acceptance

- An existing Pi-shaped custom provider file loads without a fallback diagnostic.
- `custom-openai/custom-reasoning-model` uses the normal Responses adapter and requests `https://example.test/openai/v1/responses`.
- The external file shape and defaults follow pinned Pi for the admitted subset.
- The implementation remains bounded, typed, arena-owned, credential-blind, deterministic, and private.
- No image capability, Codex impersonation, extra provider adapter, or hidden credential source is introduced.
- The executable remains the unchanged substrate stub; live CLI composition follows only after the approved durability and process-lifecycle slices.
- Debug, ReleaseSafe, catalog drift, `ziglint`, diff checks, and the default build pass.
