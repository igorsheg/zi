# Resolve Zig runtime paths, credentials, and model selection

Status: Implemented on 2026-08-18

## Intent

Construct the already-settled `AgentSessionRuntime.Config` without teaching the runtime about argv, environment variables, files, defaults, or process state.

```text
admitted absolute home and cwd
    -> ZiPaths

explicit provider/model request
    + credential-blind ModelConfig
    + admitted CLI/stored/environment credential values
    -> ModelResolution
    -> canonical selection + selected credential
    -> AgentSessionRuntime.Config
```

This is the first resolution slice. It establishes ownership and precedence before durable `auth.json`, runtime `models.json`, default-model policy, project trust, or `src/main.zig` consume it.

## Reference findings

Pinned Pi separates immutable `models.json` configuration, credential storage, provider composition, and model-selection policy. Its practical credential order is CLI override, stored credential, configured credential, then built-in environment fallback; a stored credential owns its provider and does not silently fall through after failure.

Pi also reads ambient paths and environment values in several owners and accepts a broad provider/configuration surface. Zi keeps the owner split but not those mechanics: process facts are admitted once, `ZiPaths` derives paths once, and the supported provider/model surface remains the curated catalog slice.

## Approved boundary

Add two private coding-agent owners:

- `ZiPaths` owns normalized absolute `cwd`, global `$HOME/.zi/agent`, and exact project `<cwd>/.zi` strings.
- `ModelResolution` owns canonical explicit selection, credential precedence, copied secret lifetime, and translation to `AgentSessionRuntime.Config`.

Both modules remain private imports in `coding_agent/root.zig`. They are not curated public building blocks and do not change `src/main.zig`.

## ZiPaths

```zig
const ZiPaths = @This();

arena: std.heap.ArenaAllocator,
cwd: []const u8,
global_agent: []const u8,
project: []const u8,

pub fn init(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: []const u8,
) Error!ZiPaths;

pub fn deinit(self: *ZiPaths) void;
```

`cwd` and `home` are already-admitted process facts. `ZiPaths` does not call `Dir.cwd()`, read `$HOME`, open a directory, or own the cwd `std.Io.Dir` used by `AgentSessionRuntime`.

Initialization requires absolute, non-empty, UTF-8 paths without NUL bytes. It lexically normalizes them, deep-copies the results, and derives only the two roots required by current product policy. File-specific paths join through this owner only when a consuming slice admits those files.

## ModelResolution

```zig
pub const Inputs = struct {
    model_config: ModelConfig = ModelConfig.builtin,
    requested_provider: ?[]const u8,
    requested_model: ?[]const u8,
    cli_api_key: ?[]const u8 = null,
    stored_credentials: []const Credential = &.{},
    openai_environment_api_key: ?[]const u8 = null,
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    model_config: ModelConfig,
    credentials: []const Credential,
    selection: ai.ModelIdentity,

    pub fn runtimeConfig(self: *const Resolved) RuntimeConfig;
    pub fn deinit(self: *Resolved) void;
};

pub fn resolve(
    allocator: std.mem.Allocator,
    inputs: Inputs,
) Error!Resolved;
```

The resolver performs no I/O. Inputs borrow caller storage; `Resolved` owns its selected secret copy and wipes it before releasing its arena. `model_config` remains borrowed until `AgentSessionRuntime.create`, which validates and deep-copies all retained configuration.

`ModelResolution` owns the already-resolved `Credential` and `RuntimeConfig` value types. The private `AgentSessionRuntime` aliases and consumes them; it does not own credential precedence, and the resolver does not import runtime construction. This keeps the dependency one-way and lets the existing same-module FakeTransport edge exercise the handoff without exporting a test seam.

The result supplies only the credential required by the selected provider. Installing unrelated authenticated providers is deferred until model switching or discovery proves that need.

## Selection policy

Both provider and model are required in this slice. Supplying neither returns `SelectionRequired`; supplying only one returns `IncompleteSelection`.

The model value is interpreted only inside the explicit provider namespace. `ModelConfig.resolve` accepts a canonical ID or provider-scoped alias, and `Resolved.selection` always contains the canonical provider/model identity.

Do not add bare-model inference, fuzzy matching, `provider/model` splitting, catalog-order defaults, recent-session fallback, or thinking suffix parsing. Those are separate selection-policy decisions.

## Credential precedence

For an API-key provider:

| Priority | Source                     | Rule                                                     |
| -------- | -------------------------- | -------------------------------------------------------- |
| 1        | CLI `--api-key`            | Applies only to the explicitly selected API-key provider |
| 2        | Stored credential snapshot | Matching provider entry blocks environment fallback      |
| 3        | OpenAI environment value   | Applies only to built-in `openai`                        |

For `openai-codex`, the selected credential must be an already-resolved stored Codex OAuth value. A CLI API key is rejected because it cannot be reinterpreted as a Codex OAuth token. OAuth acquisition, refresh, and ambient Codex token conventions remain deferred.

Empty credentials, duplicate stored provider entries, unrelated credential kinds, unknown selections, unavailable providers, and missing selected credentials fail with typed errors. Error values and diagnostics never retain or print secret bytes.

## Ownership and cleanup

```text
caller
├── admitted cwd/home strings
├── borrowed ModelConfig
└── borrowed credential source values

ZiPaths
└── owned normalized path strings

ModelResolution.Resolved
├── borrowed ModelConfig
├── canonical selection borrowed from that config
└── owned selected credential copy

AgentSessionRuntime
├── deep-copied ModelConfig/catalog/provider strings
├── deep-copied and wiped credential
└── AgentSession
```

The caller keeps `ZiPaths`, `ModelConfig`, and `Resolved` alive through runtime creation. Runtime creation then owns everything it retains. `Resolved.deinit` securely wipes its credential copy even after failed runtime creation.

## Bounds and validation

- Paths are bounded to 32 KiB each before derived joins.
- Stored credential inputs are bounded by the runtime's existing 32-credential contract.
- Provider/model identifiers reuse `ModelConfig` and catalog validation rather than adding sibling validators.
- Secret values are non-empty and bounded to 1 MiB.
- All allocations and partial initialization have one reverse-order cleanup path.

These bounds prevent path joins, credential snapshots, and secret copies from becoming unbounded process-input allocations.

## Program design

```text
src/coding_agent/
+  ZiPaths.zig                 # immutable cwd/home-derived path owner
+  ModelResolution.zig         # pure selection and credential precedence
~  AgentSessionRuntime.zig     # consumes resolved config; vertical seam test
~  root.zig                    # private imports for compilation/tests

plans/
+  zig-runtime-model-resolution.md
```

No generic configuration loader, environment vtable, provider registry, credential manager, or path bag is added.

## Vertical behavior tests

### Slice 1: immutable paths

- Normalize absolute home/cwd and derive exact global/project roots.
- Prove caller-buffer mutation cannot change retained paths.
- Reject relative, empty, invalid UTF-8, NUL-containing, and over-bound paths.
- Settle every allocation failure.

Verification: focused owner tests, Debug suite, `ziglint`.

### Slice 2: pure model resolution

- Resolve a canonical model and an alias to the same canonical selection.
- Prove CLI overrides stored and environment API keys.
- Prove a stored OpenAI key blocks environment fallback.
- Resolve an already-admitted Codex credential without accepting CLI API-key substitution.
- Reject missing/partial/unknown selection, duplicate or empty credentials, and missing selected authentication.
- Prove copied secret bytes are zero after disposal.
- Settle every allocation failure.

Verification: focused owner tests plus the existing runtime tests.

### Slice 3: vertical runtime handoff

Resolve an OpenAI alias and credential, translate with `runtimeConfig`, construct the existing runtime through private `createWithTransport`, and assert the canonical model ID and selected credential cross the real provider/protocol/FakeTransport seam.

Do not export the runtime or transport constructor for this test.

## Deferred surfaces

- Reading or writing `auth.json`.
- Loading or merging global `models.json`.
- Any project `<cwd>/.zi` configuration before project trust exists.
- Environment capture and CLI process composition.
- Default, recent, restored-session, pattern, and picker model policy.
- OAuth acquisition, refresh, login, logout, and device/browser flows.
- Provider discovery, remote catalogs, extensions, or additional adapters.
- Session replacement and `src/main.zig`.

The next slice may add bounded global `auth.json` and `models.json` readers using `ZiPaths`. Invalid durable input must be rejected or returned as an explicit diagnostic without partially applying it; raw credential buffers and decoded intermediates must be wiped.

## Acceptance

- No owner below the future process host reads cwd, home, or environment state.
- `ZiPaths` is the only owner deriving `.zi` paths.
- Model resolution is deterministic, provider-scoped, and canonical.
- Credential precedence is explicit and behavior-tested.
- Only the selected provider credential crosses into the runtime.
- Secrets are copied once per owner and securely wiped on every exit path.
- Existing provider scope and runtime visibility remain unchanged.
- `src/main.zig` remains untouched.
- Debug and ReleaseSafe tests, catalog drift, `ziglint`, diff checks, and the default build pass.
