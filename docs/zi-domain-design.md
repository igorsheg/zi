# Zi domain migration design

Status: implemented

Research: [`zi-domain-research.md`](zi-domain-research.md)

## Decision

Zi will make a hard product-namespace cut.

- Zi will not accept `HAX_*` aliases.
- Zi will not search or import Hax XDG roots.
- Zi will not emit Hax names to child processes.
- New persisted records will identify Zi.
- Runtime diagnostics and public examples will use Zi names.
- Hax remains only as engineering provenance and the pinned behavior reference.

Zi is still `0.1.0-dev`, so carrying a dual namespace would add precedence rules, warnings, tests, and a later removal migration without protecting a released Zi contract.

## Scope

### Included

- Rename every active product environment variable from `HAX_*` to `ZI_*`.
- Remove imported settings that have no runtime implementation.
- Update startup's direct environment reads.
- Update nested Zi child selection and subagent-depth propagation.
- Replace the session writer field `hax_version` with `zi_version`.
- Rename internal Hax-domain identifiers whose meaning is now Zi-owned.
- Update runtime diagnostics, README examples, mock fixtures, and active configuration docs.
- Remove Hax ancestry from the public product introduction.
- Keep Hax attribution and parity language where it records provenance.

### Excluded

- Hax config, state, cache, history, credential, or session import.
- Environment alias precedence or deprecation warnings.
- Changes to existing Zi XDG roots or lock names.
- Renaming external provider variables or paths.
- Renaming protocol dialects, provider IDs, `AGENTS.md`, or `.agents/skills`.
- Changing JSONL item vocabulary, session filenames, cwd buckets, or history encoding.
- Implementing notifications, keep-awake behavior, or wire tracing.

## Canonical environment contract

`src/config/Settings.zig` remains the source of truth for public setting metadata. Every retained registry row gets the mechanical `ZI_*` prefix.

The current inert rows are removed rather than renamed:

- `notify` / `HAX_NOTIFY`
- `keep_awake` / `HAX_KEEP_AWAKE`
- `trace` / `HAX_TRACE`

After removal, the registry contains 63 settings. `ZI_SUBAGENT_DEPTH` remains an internal process contract outside the registry.

Provider-standard names remain unchanged:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `OPENROUTER_API_KEY`
- `OPENCODE_API_KEY`

Arbitrary provider `api_key_env` and extra-header references also remain unchanged.

### Startup reads

`src/cli/StartupConfig.zig` changes its five direct reads together:

```text
ZI_PROVIDER
ZI_MODEL
ZI_EFFORT
ZI_PRESET
ZI_SYSTEM_PROMPT
```

The direct path still preserves absent versus present-empty semantics. Configuration precedence does not change.

`src/cli/SubagentDepth.zig` reads only `ZI_SUBAGENT_DEPTH`.

### Child environment

`src/tool/Bash.zig` exports this canonical nested-Zi contract:

```text
AI_AGENT=zi
ZI_PROVIDER=<effective provider>
ZI_MODEL=<effective model or empty>
ZI_EFFORT=<effective effort or empty>
ZI_PRESET=
ZI_SUBAGENT_DEPTH=<parent plus one>
ZI_TRANSCRIPT=
```

`ZI_TRANSCRIPT` remains forcibly empty so a nested Zi process cannot contend for or append to the parent's transcript.

`ZI_TRACE` is not exported because trace is not an implemented setting. No Hax-prefixed entry receives special treatment. An arbitrary inherited `HAX_*` value is just an unrelated environment entry, like any other unknown variable.

`RunSelection` documentation changes from Zi/Hax children to nested Zi children.

## Persistence contract

### Writer

`src/persistence/SessionFile.zig` writes:

```json
{"type":"session","version":1,"zi_version":"0.1.0-dev"}
```

It no longer writes `hax_version`.

### Reader

The current loader ignores unknown header metadata and does not inspect the writer-version field. That permissive behavior remains. No explicit Hax alias or migration branch is added.

Tests should prove two separate facts:

1. New Zi headers contain `zi_version` and omit `hax_version`.
2. Unknown header metadata does not block loading otherwise valid session data.

The second test protects format tolerance without making Hax a canonical runtime concept.

### Internal names

`isHaxStandardName` becomes `isCanonicalName`. Its filename-recognition behavior does not change.

Other Hax mentions in focused comments and tests remain when they explain exact adapted behavior. Product-domain wording changes where the Hax name is no longer explanatory.

## User-facing behavior

Diagnostics change mechanically to Zi names:

- `HAX_MODEL` becomes `ZI_MODEL`.
- `HAX_OPENAI_BASE_URL` becomes `ZI_OPENAI_BASE_URL`.
- `HAX_ANTHROPIC_BASE_URL` becomes `ZI_ANTHROPIC_BASE_URL`.
- `HAX_LLAMACPP_PORT` becomes `ZI_LLAMACPP_PORT`.
- `HAX_LLAMACPP_BASE_URL` becomes `ZI_LLAMACPP_BASE_URL`.

The README becomes a Zi product introduction. Hax ancestry remains in `THIRD_PARTY_NOTICES.md` and engineering research rather than the opening product description.

Mock commands use `ZI_PROVIDER`, `ZI_MOCK_SCRIPT`, and `ZI_DISPLAY_WIDTH`. Fixture paths that claim to show the current repository change from Hax C files to representative Zi Zig files. Rendering semantics stay the same.

Active product and architecture documents use `ZI_TRANSCRIPT` when naming the supported setting. Research documents may keep the old Hax path and variable names when documenting source behavior or this migration.

## OpenRouter metadata correction

The domain change touches the OpenRouter title and referer rows. Their current descriptions claim users can override or disable the headers, while `ProviderConfig` accepts only Zi's fixed defaults.

The cleanup will keep the fixed Zi attribution and make the setting metadata honest. Two options would be coherent:

1. Remove both settings and keep the headers entirely internal.
2. Keep the settings only if configuration is made functional.

This design chooses option 1. `providers.openrouter.title`, `providers.openrouter.referer`, `HAX_OPENROUTER_TITLE`, and `HAX_OPENROUTER_REFERER` leave the registry. The fixed headers in `src/ai/ProviderRegistry.zig` remain:

```text
X-Title: zi
HTTP-Referer: https://github.com/igorsheg/zi
```

The final registry therefore contains 61 settings, not 63.

## File-level design

```text
src/
├── config/
│   └── Settings.zig              rename active env names; remove five inactive/fixed rows
├── cli/
│   ├── StartupConfig.zig         direct ZI_* selection reads and tests
│   ├── SubagentDepth.zig         ZI_SUBAGENT_DEPTH
│   ├── InteractiveCommands.zig   ZI_MODEL diagnostics
│   └── PrintRun.zig              Zi llama.cpp diagnostics and tests
├── tool/
│   └── Bash.zig                  nested Zi environment contract
├── ToolRuntime.zig               child environment behavior tests
├── ProviderConfig.zig            compatible-provider diagnostics; remove dead OpenRouter setting checks
└── persistence/
    ├── SessionFile.zig           zi_version writer field and tests
    └── SessionIndex.zig          isCanonicalName

README.md                         Zi product introduction and ZI_* examples
scripts/mock/*.txt                ZI_* commands and Zi fixture paths
docs/*                            active setting names; provenance retained
```

`src/config/Store.zig` does not change because the hard cut needs no alias support.

`src/config/Loader.zig`, `src/cli/ProcessAdapters.zig`, and filesystem owners do not change because their namespaces are already Zi-native.

## Execution flow after the change

```text
process environment
  -> ProcessAdapters.Environment snapshot
  -> Settings registry resolves ZI_* overrides
  -> StartupConfig records direct ZI_* selection facts
  -> ProviderConfig resolves provider, model, and effort
  -> ToolRuntime passes effective selection to Bash
  -> Bash exports ZI_* selection and incremented ZI_SUBAGENT_DEPTH
  -> nested zi reads the same canonical contract
```

Session persistence follows a separate path:

```text
PrintRun.version
  -> SessionFile writer_version
  -> header zi_version
  -> SessionFile decoder ignores unneeded metadata on load
```

## Vertical implementation slices

### Slice 1: canonical environment contract

Change the registry, startup reads, provider diagnostics, and tests together.

Verification:

- registry test reports 61 unique `ZI_*` names
- no active registry name starts with `HAX_`
- explicit empty selection behavior still passes
- compatible-provider and llama diagnostics name Zi variables

### Slice 2: nested Zi process contract

Change subagent depth, Bash selection exports, transcript isolation, ToolRuntime probes, and tests together.

Verification:

- direct Bash environment probe sees effective `ZI_PROVIDER`, `ZI_MODEL`, and `ZI_EFFORT`
- `ZI_PRESET` is empty
- `ZI_SUBAGENT_DEPTH` increments and still enforces the depth cap
- `ZI_TRANSCRIPT` is empty in children
- no child override table contains a Hax name

### Slice 3: persisted and internal identity

Change the session header and canonical-name helper.

Verification:

- a fresh built-binary session starts with `zi_version`
- the header contains no `hax_version`
- resume and session indexing tests pass
- unknown header metadata remains tolerated

### Slice 4: product text and fixtures

Update README, mock scripts, active docs, and fixture paths.

Verification:

- README commands run with the mock provider
- `git grep 'HAX_' -- src README.md scripts` returns no matches
- product docs name `ZI_TRANSCRIPT`
- remaining lowercase Hax references are provenance or parity statements

### Slice 5: full certification

Run focused lint on changed Zig files, then the project ready gate and a binary-level mock probe.

## Acceptance checks

```sh
# No old runtime contract remains.
git grep -n 'HAX_' -- src README.md scripts

# No old persisted or internal product identity remains.
git grep -n 'hax_version\|isHax' -- src

# Public product introduction is Zi-only.
git grep -n -i 'hax' -- README.md

# Registry contract is Zi-prefixed and unique.
rg -o '"ZI_[A-Z0-9_]+"' src/config/Settings.zig

# Documentation and source formatting.
git diff --check
zig fmt --check src/
ziglint <changed-zig-files>

# Ready gate.
zig build
zig build test
./zig-out/bin/zi --help
./zig-out/bin/zi --version

# Highest-level environment and persistence probes.
ZI_PROVIDER=mock ./zig-out/bin/zi --print hi
ZI_PROVIDER=mock ZI_MOCK_SCRIPT=scripts/mock/hello.txt ./zig-out/bin/zi --print hi
```


## Implementation outcome

Implemented and verified on `main`.

- The registry contains 61 unique `ZI_*` settings.
- Startup and subagent-depth tests prove old product-prefixed variables are ignored.
- Nested Zi processes receive effective selection, depth, and an empty transcript path.
- New sessions write `zi_version`; an independent fixture proves unknown header metadata remains readable.
- Runtime source, README, scripts, and active product documents contain no `HAX_*` contract.
- The built binary accepts the Zi mock settings, records `zi_version`, and persists the exact nested child result `mock|mock-model|||1|`.
- A clean-environment binary probe with only the old provider variable fails instead of selecting the mock provider.
- Focused tests, `ziglint`, and the full ready gate pass.

## Expected residue after completion

A repository-wide case-insensitive search for `hax` will still find:

- `AGENTS.md`
- `THIRD_PARTY_NOTICES.md`
- migration research
- source research documents
- focused comments and test names that cite pinned behavior

It should not find Hax as Zi's runtime configuration, filesystem owner, writer identity, user instruction, or current internal domain noun.
