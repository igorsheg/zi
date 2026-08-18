# Load global Zig model configuration

Status: Implemented and verified on 2026-08-18

## Intent

Admit credential-blind custom OpenAI Chat Completions-compatible providers from the global
`$HOME/.zi/agent/models.json` file without weakening the generated built-in catalog or teaching model runtime owners
about files.

```text
admitted home + cwd
    -> ZiPaths.global_models_file
    -> ModelConfigSnapshot.load
    -> owned catalog/provider composition + optional diagnostic
    -> borrowed ModelConfig
    -> ModelResolution
    -> private AgentSessionRuntime
```

This is startup-only immutable composition. Reload, project configuration, credentials, environment capture, model
defaults, and `src/main.zig` remain separate slices.

## Reference findings

Pinned Pi separates its immutable `models.json` snapshot from provider composition, credential resolution, model
selection, and live runtime ownership. Missing configuration preserves built-ins, and malformed configuration is retained
as a diagnostic rather than partially applied.

Pi's public schema and merge engine are substantially broader than Zi's approved surface: credentials, environment and
command references, headers, compatibility matrices, extensions, provider discovery, model overrides, fabricated model
defaults, and arbitrary adapter registration. Zi keeps the owner decomposition but defines a narrower versioned schema
whose valid values map completely to compiled Zi types.

## Approved product boundary

The first runtime file admits only new generic OpenAI Chat Completions-compatible providers. It does not override or
extend the built-in `openai` or `openai-codex` identities.

Normal OpenAI Responses remains the built-in `openai` provider. Codex Responses remains the distinct built-in
`openai-codex` provider and OAuth credential kind. A custom Responses endpoint, built-in endpoint override, or additional
Codex identity requires a later product decision rather than an extra durable tag now.

The file is credential-blind. Authentication describes only whether the provider requires an API key; secret values,
environment-variable names, commands, OAuth state, and headers are invalid fields.

## Durable schema

```json
{
  "version": 1,
  "providers": [
    {
      "id": "local",
      "name": "Local",
      "base_url": "http://127.0.0.1:11434/v1",
      "authentication": "none",
      "models": [
        {
          "id": "qwen-coder",
          "aliases": ["local-coder"],
          "profile": {
            "capabilities": ["streaming", "tools", "parallel_tool_calls"],
            "settings": ["temperature", "top_p", "max_output_tokens"],
            "context_window": 32768,
            "max_output_tokens": 8192
          }
        }
      ]
    }
  ]
}
```

`version`, `providers`, and every provider field are required. `aliases` and `settings` may be empty. Capabilities are
required and must include the coding-agent minimum described below. Unknown fields and unknown enum values reject the
document.

The compiled adapter is deliberately absent from the wire schema because every custom provider in this slice uses the
one admitted `openai_completions` implementation. Adding a durable adapter discriminator before a second custom adapter
is supported would expose implementation vocabulary without adding behavior.

Authentication is exactly `none` or `api_key`. Capabilities may contain `streaming`, `tools`, `parallel_tool_calls`, and
`thinking`; `image_input` is rejected. Settings may contain `temperature`, `top_p`, `max_output_tokens`,
`stop_sequences`, and `seed`; `reasoning_effort` is rejected because the compatible request codec does not encode it.

Every custom coding-agent model must explicitly advertise `streaming` and `tools`. Context and maximum output token
limits are required, positive, and maximum output cannot exceed context. Zi does not fabricate Pi's 128K/16K defaults
or infer capabilities from provider names.

## Owners and interfaces

### `ZiPaths`

`ZiPaths` adds one owned normalized field:

```zig
global_models_file: []const u8,
```

It derives the value as `<global_agent>/models.json` during initialization and includes it in the existing 32 KiB path
bound. No loader joins `.zi`, `agent`, or `models.json`, and the path owner does not parse model data.

### `ModelConfigSnapshot`

```zig
const ModelConfigSnapshot = @This();

pub const Diagnostic = enum {
    unreadable,
    too_large,
    invalid,
};

pub const LoadError = error{
    OutOfMemory,
    Cancelled,
};

arena: std.heap.ArenaAllocator,
state: union(enum) {
    builtin: ?Diagnostic,
    configured: ModelConfig,
},

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) LoadError!ModelConfigSnapshot;

pub fn view(self: *const ModelConfigSnapshot) ModelConfig;
pub fn diagnostic(self: *const ModelConfigSnapshot) ?Diagnostic;
pub fn deinit(self: *ModelConfigSnapshot) void;
```

The snapshot is the sole owner of file I/O, the private JSON wire structs, validation, merge policy, decoded allocations,
and the projected catalog/provider arrays. `ModelConfig` remains a shallow borrowed domain view. Neither type becomes
public through `coding_agent/root.zig`.

## Admission and publication

`load` reads only `paths.global_models_file` with a 1 MiB bound. It parses with exact typed JSON,
`.allocate = .alloc_always`, unknown-field rejection, and a bounded maximum value length, so the raw file buffer can be
released immediately.

The owner validates the complete decoded candidate before publishing it:

- version is exactly 1;
- provider IDs do not collide with built-ins or one another;
- model and alias identities are unique in their provider namespace;
- enum arrays contain no duplicates;
- endpoints are absolute HTTP or HTTPS URIs with a host and without user info, query, fragment, or control bytes;
- provider names and all identifiers are non-empty, bounded, valid UTF-8, and free of control characters;
- authentication, capability, setting, and profile cross-field rules match the durable schema;
- the final combined `ai.Catalog` and `ModelConfig` validate once before publication.

Built-in providers and catalog entries retain their generated order. Valid custom providers and entries append in file
order. There is no replacement, deletion, partial provider application, or model-override syntax in this slice.

## Failure behavior

The snapshot always represents one settled configuration:

| Input state                                                                 | Snapshot value | Diagnostic          |
| --------------------------------------------------------------------------- | -------------- | ------------------- |
| Missing global directory or file                                            | Built-ins      | none                |
| Existing unreadable path                                                    | Built-ins      | `unreadable`        |
| File exceeds 1 MiB                                                          | Built-ins      | `too_large`         |
| Invalid JSON, schema, bounds, collision, URI, profile, or final composition | Built-ins      | `invalid`           |
| I/O cancellation                                                            | no snapshot    | `error.Cancelled`   |
| Allocation failure                                                          | no snapshot    | `error.OutOfMemory` |

An invalid file never publishes a valid subset. The future process host must report a present diagnostic before model
selection; this slice does not print, exit, or mutate the file.

## Bounds

- document: 1 MiB;
- custom providers: 30, preserving the existing 32-provider total with two built-ins;
- custom models: 256 total and 64 per provider;
- aliases: 16 per model;
- provider IDs and names: 256 bytes;
- model IDs and aliases: 512 bytes;
- endpoint: 8 KiB;
- JSON value: 32 KiB.

The model and alias bounds keep catalog collision validation predictably bounded rather than relying only on document
size.

## Lifetime

```text
ZiPaths
└── global models filename

ModelConfigSnapshot
├── arena-owned decoded strings
├── arena-owned merged catalog/provider arrays
└── borrowed references to static built-ins

ModelResolution.Resolved
├── borrowed snapshot ModelConfig and canonical identity
└── owned selected credential copy

AgentSessionRuntime
└── independent deep copies of everything retained
```

Keep the snapshot alive through resolution and runtime creation. After successful runtime construction, dispose
`Resolved`, then the snapshot, then `ZiPaths`; the live runtime remains valid because `ModelRuntime` is the established
deep-copy lifetime barrier.

## Program design

```text
src/coding_agent/
~  ZiPaths.zig                 # derive global models filename
+  ModelConfigSnapshot.zig     # file/wire/admission/owned snapshot
~  AgentSessionRuntime.zig     # vertical FakeTransport acceptance
~  root.zig                    # private compilation/test import

plans/
+  zig-global-model-config.md
```

Dependency direction remains acyclic:

```text
ZiPaths <- ModelConfigSnapshot -> ModelConfig -> ai catalog
                                           ^
ModelResolution ---------------------------|
     |
AgentSessionRuntime
```

## Vertical slices

### Slice 1: path and snapshot

- Prove the exact normalized global filename and caller-buffer independence.
- Missing file returns built-ins without a diagnostic.
- A valid file owns a custom provider, canonical model, alias, endpoint, authentication policy, and profile.
- Mutation or deletion of the file after load cannot alter the snapshot.
- Malformed, unknown-field, collision, invalid URI/profile, oversized, and unreadable inputs return built-ins with the
  exact diagnostic and no partial custom provider.
- Settle every allocation failure.

Verification: focused tests, Debug suite, `ziglint`.

### Slice 2: runtime acceptance

Load an API-key custom provider and aliased model from a temporary global file, resolve it with an admitted CLI key,
create the existing runtime through private `createWithTransport`, then dispose `Resolved`, snapshot, and paths before
prompting.

The existing `FakeTransport` edge must observe the configured Chat Completions URL, canonical model ID, and Authorization
header, and the session must complete with the canonical response identity. No runtime or transport constructor becomes
public for this test.

Verification: Debug and ReleaseSafe suites.

## Deferred surfaces

- Built-in provider endpoint overrides or model upserts.
- Custom normal Responses or Codex providers.
- `modelOverrides`, compatibility flags, headers, costs, or unknown adapter registration.
- Project `<cwd>/.zi/models.json` before project trust.
- File watching, reload, writes, migration, comments, or JSON5.
- Credentials, environment or command interpolation, OAuth, and `auth.json`.
- Default, recent, restored-session, fuzzy, pattern, and picker model policy.
- Extensions, discovery, remote catalogs, and cached model stores.
- `src/main.zig` and process-host composition.

## Acceptance

- `ZiPaths` remains the sole `.zi` path-policy owner.
- Durable input is strictly bounded, validated once, and published atomically.
- The snapshot is credential-blind and owns every custom string retained by its `ModelConfig` view.
- Generated built-ins cannot be shadowed or modified by the global file.
- Only compiled, approved wire behavior can be selected.
- Missing and invalid files have explicit, behavior-tested outcomes.
- Snapshot disposal before prompting cannot invalidate a constructed runtime.
- No internal API becomes part of the curated package root.
- `src/main.zig` remains untouched.
- Catalog drift, Debug and ReleaseSafe tests, `ziglint`, diff checks, and the default build pass.
