# Zig Agent Session Runtime

**Status:** Superseded by `plans/zig-model-catalog-runtime.md`

The stable ownership, cleanup, transport-injection, and client-independent session boundaries remain in force. The provider-specific `ResolvedModel` construction contract was replaced before commit by credential-blind `ModelConfig`, generated model metadata, resolved credentials, and catalog-backed `ModelRuntime` composition.

## Product intent

Close the coding-agent construction seam without teaching `AgentSession` about process configuration, credentials, transports, or concrete providers. The supported runtime remains deliberately narrow: one selected OpenAI-compatible or OpenAI Codex model, one cwd, the existing coding tools, and one caller-owned session lifetime.

A live request is acceptance evidence for this architecture, not a temporary architecture to replace later. Runtime construction must already own erased-pointer stability, copied configuration, credential cleanup, partial-initialization cleanup, and reverse-order disposal.

## Reference split

Pi coding-agent supplies the product decomposition:

- model infrastructure is distinct from `AgentSession`;
- effective cwd is fixed before cwd-bound tools and services are created;
- runtime creation returns typed failures instead of printing or exiting;
- the owner that creates a session disposes it before its dependencies;
- session replacement belongs to an `AgentSessionRuntime` host, but new/resume/fork/switch are deferred until Zi admits persistence and replacement.

ZigAI supplies Zig construction mechanics:

- allocator and `std.Io` are explicit values;
- transport, provider, and model handles borrow concrete storage;
- concrete storage is initialized before erased views are derived;
- cleanup runs in reverse dependency order;
- transport injection is an internal test seam, not a public model factory.

Zi does not adopt ZigAI's broad CLI configuration, provider enum, default model catalog, direct environment reads, or ephemeral `Agent{...}.run()` composition.

## Owner graph

```text
AgentSessionRuntime (heap allocated at final address)
├── TransportOwner
│   ├── production: HttpTransport
│   └── tests: borrowed Transport
├── ModelRuntime (private implementation owner)
│   ├── owned copied model/provider/endpoint strings
│   ├── owned copied credential
│   ├── concrete provider storage
│   └── resolved borrowed Model view
└── AgentSession
    ├── Agent
    ├── coding tools bound to cwd
    └── canonical history
```

`AgentSessionRuntime` is the sole heap-stable owner. It is allocated before any erased view is created and is never returned by value. Its private `ModelRuntime` and provider payload therefore remain at stable addresses until `deinit`.

A provider registry would add no behavior while one resolved model is selected per runtime. Model discovery and switching can add one inside `ModelRuntime` later without changing the `AgentSessionRuntime` interface.

## Admitted configuration

```zig
pub const ResolvedModel = union(enum) {
    openai_compatible: OpenAiCompatible,
    openai_codex: OpenAiCodex,

    pub const OpenAiCompatible = struct {
        provider_id: []const u8 = "openai-compatible",
        model_id: []const u8,
        base_url: []const u8,
        api_key: ?[]const u8 = null,
    };

    pub const OpenAiCodex = struct {
        model_id: []const u8,
        access_token: []const u8,
        account_id: ?[]const u8 = null,
        base_url: []const u8 = "https://chatgpt.com/backend-api",
    };
};
```

This is resolved application configuration, not argv or environment state. Runtime construction copies every borrowed string before deriving provider/model views. It rejects empty provider IDs, model IDs, endpoints, present-but-empty API keys, empty Codex tokens, and present-but-empty account IDs before session construction.

Custom headers, display names, model catalogs, profile overrides, settings files, auth stores, environment precedence, OAuth refresh, and additional providers are deferred. They are not placeholders in this interface.

## Interfaces

### ModelRuntime

```zig
fn init(
    self: *ModelRuntime,
    allocator: std.mem.Allocator,
    transport: ai.Transport,
    resolved: ResolvedModel,
) InitError!void;

fn model(self: *const ModelRuntime) ai.Model;
fn deinit(self: *ModelRuntime) void;
```

`ModelRuntime` is private implementation, not a separately exported module interface. It owns copied configuration, concrete provider storage, and the selected model view. It borrows the transport supplied by `AgentSessionRuntime`.

### AgentSessionRuntime

```zig
pub const Options = struct {
    limits: RunLimits = .{},
    events: ?AgentSession.EventSink = null,
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    resolved: ResolvedModel,
    options: Options,
) CreateError!*AgentSessionRuntime;

pub fn session(self: *AgentSessionRuntime) *AgentSession;
pub fn deinit(self: *AgentSessionRuntime) void;
```

Production `create` owns an `HttpTransport`. A private same-module constructor accepts a borrowed erased transport for deterministic integration tests. No test-only constructor is exported through `coding_agent.root`.

The runtime module remains internal during this slice. It becomes a curated public building block only with documented embedding, cancellation, bounds, versioning, and compiled-release acceptance.

## Construction and disposal

Construction order:

1. allocate `AgentSessionRuntime` at its final address;
2. initialize the transport owner;
3. validate resolved configuration;
4. initialize `ModelRuntime` in place and copy its borrowed strings;
5. initialize concrete provider storage;
6. derive the selected model view from its final provider storage;
7. initialize `AgentSession` with that model and cwd;
8. return the stable runtime pointer.

Every admitted stage has an `errdefer` that settles already-created owners. A failed construction leaves no session, configuration allocation, credential copy, or runtime allocation behind.

Disposal order:

1. `AgentSession.deinit`;
2. securely wipe `ModelRuntime` credential and Codex account bytes so release optimization cannot remove the stores;
3. release model configuration storage;
4. release the runtime allocation.

Provider adapters securely wipe formatted Authorization scratch allocations before freeing them. Codex also wipes decoded JWT payload and derived account-ID scratch; disposing the runtime alone would not cover those per-request copies.

`std.Io.Dir.cwd()` remains borrowed and is never closed by the runtime. Explicit owned cwd support is deferred to the process/config slice.

## Vertical behavior tests

Use `ai.transport_testing.FakeTransport` at the real transport seam.

1. OpenAI-compatible runtime copies its resolved strings, survives mutation of caller buffers, executes the real `read` tool against a temporary cwd, performs the follow-up provider request, and returns only the final text.
2. OpenAI Codex runtime sends the expected credential/account headers, normalizes its Responses SSE payload, and preserves the selected model identity in session history.
3. Invalid resolved configuration fails before transport admission and without allocation leaks.
4. Runtime disposal wipes copied credential bytes; verify with caller-independent backing storage rather than inspecting freed memory.
5. The production constructor can create and dispose a runtime without moving erased storage.

Provider protocol encoding already has focused provider tests. Runtime tests assert the cross-module result and only enough request evidence to prove the selected adapter and cwd-bound tool path were used.

## Deferred surfaces

- argv, environment, settings, auth-file, and OAuth resolution;
- `ZiPaths`, explicit `--cwd`, and owned directory handles;
- model discovery, model switching, remote catalogs, and provider availability;
- session persistence and new/resume/fork/switch replacement;
- settings, resource loaders, extensions, trust, skills, templates, and themes;
- process signals and CLI-owned cancellation;
- JSON, RPC, and interactive clients;
- `src/main.zig` wiring and live network acceptance.

The next slice after this runtime is Pi-compatible model and credential resolution. The process host follows only after it can consume a fully resolved model without inventing provider policy in `main.zig`.

**Verification:** `zig build`; 117/117 debug and ReleaseSafe tests; exhaustive allocation-failure checks; `ziglint`; `git diff --check`; two independent ownership and architecture reviews with no remaining findings.
