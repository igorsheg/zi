# Zi domain migration research

Status: approved research

## Intent

Zi should present and persist its own product domain. Hax remains the pinned behavior and architecture reference, not a runtime namespace, user configuration prefix, persisted writer identity, or public product name.

This distinction matters. Removing every mention of Hax would erase useful provenance. Keeping Hax names in Zi's runtime would make Zi look like a wrapper around another product. The target is a clean boundary:

- Zi owns runtime names, files, diagnostics, examples, and persisted writer identity.
- External protocols keep their established names.
- Engineering research and `THIRD_PARTY_NOTICES.md` keep exact Hax attribution.

## Current state

The primary product identity is already Zi:

- executable and module: `zi`
- CLI help and version: `zi`
- interactive banner and system prompt: Zi
- generic HTTP user agent: `zi/0.1.0-dev`
- OpenRouter title and referer: Zi
- child-process identity: `AI_AGENT=zi`
- config, state, and cache roots: `zi`
- private lock and temporary prefixes: `.zi-*`

The remaining active Hax identity is concentrated in four contracts:

1. 67 environment variables.
2. Child-process selection and recursion propagation.
3. The session header field `hax_version`.
4. User-facing diagnostics, examples, fixtures, and internal names.

## Environment-variable ABI

`src/config/Settings.zig` registers 66 public settings. Every environment name uses the `HAX_` prefix. `src/cli/SubagentDepth.zig` adds the process-only `HAX_SUBAGENT_DEPTH`, for 67 distinct names in total.

There are no accepted `ZI_*` setting aliases. `ZI_TRACE` and `ZI_TRANSCRIPT` only appear in the child-environment scrub list and have no input behavior.

### Selection and prompt

- `HAX_PRESET`
- `HAX_PROVIDER`
- `HAX_MODEL`
- `HAX_EFFORT`
- `HAX_SYSTEM_PROMPT`
- `HAX_SYSTEM_PROMPT_APPEND`
- `HAX_NO_ENV`
- `HAX_NO_AGENTS_MD`
- `HAX_NO_SKILLS`
- `HAX_NO_SUBAGENTS`
- `HAX_NO_TASKS`

### Presentation and process behavior

- `HAX_MARKDOWN`
- `HAX_SHOW_REASONING`
- `HAX_SORT_MODELS`
- `HAX_CONTEXT_LIMIT`
- `HAX_DISPLAY_WIDTH`
- `HAX_NOTIFY`
- `HAX_THEME`
- `HAX_TINT`
- `HAX_KEEP_AWAKE`

### Conversation, catalog, and persistence

- `HAX_COMPACT_AUTO`
- `HAX_COMPACT_THRESHOLD`
- `HAX_MAX_TURNS`
- `HAX_CATALOG_URL`
- `HAX_CATALOG_REFRESH`
- `HAX_NO_SESSION`
- `HAX_SESSION_RETENTION_DAYS`
- `HAX_TRANSCRIPT`
- `HAX_TRACE`
- `HAX_IMAGE_INPUT`

### Tools and HTTP

- `HAX_TOOL_OUTPUT_CAP`
- `HAX_BASH_TIMEOUT`
- `HAX_BASH_TIMEOUT_MAX`
- `HAX_BASH_TIMEOUT_GRACE`
- `HAX_BASH_BACKGROUND_YIELD`
- `HAX_BASH_SHELL`
- `HAX_TASK_WAIT_TIMEOUT`
- `HAX_TASK_MAX_RUNNING`
- `HAX_HTTP_MAX_RETRIES`
- `HAX_HTTP_RETRY_BASE`
- `HAX_HTTP_IDLE_TIMEOUT`

### OpenAI-compatible provider

- `HAX_OPENAI_BASE_URL`
- `HAX_OPENAI_API_KEY`
- `HAX_OPENAI_DISPLAY_NAME`
- `HAX_OPENAI_API`
- `HAX_OPENAI_REASONING_FORMAT`
- `HAX_REASONING_ROUNDTRIP`
- `HAX_OPENAI_SEND_CACHE_KEY`
- `HAX_OPENAI_REQUEST_COST`
- `HAX_OPENAI_CACHE`
- `HAX_OPENAI_CACHE_TTL`

These configure `providers.openai-compatible`. The first-party OpenAI provider correctly uses the standard `OPENAI_API_KEY` contract.

### Anthropic-compatible provider

- `HAX_ANTHROPIC_BASE_URL`
- `HAX_ANTHROPIC_API_KEY`
- `HAX_ANTHROPIC_DISPLAY_NAME`
- `HAX_ANTHROPIC_MAX_TOKENS`
- `HAX_ANTHROPIC_THINKING_MODE`
- `HAX_ANTHROPIC_THINKING_BUDGET`
- `HAX_ANTHROPIC_CACHE`
- `HAX_ANTHROPIC_CACHE_TTL`
- `HAX_ANTHROPIC_VERSION`

These configure `providers.anthropic-compatible`. The first-party Anthropic provider correctly uses `ANTHROPIC_API_KEY`.

### Local, OpenRouter, mock, and recursion

- `HAX_LLAMACPP_BASE_URL`
- `HAX_LLAMACPP_API_KEY`
- `HAX_LLAMACPP_PORT`
- `HAX_OPENROUTER_TITLE`
- `HAX_OPENROUTER_REFERER`
- `HAX_MOCK_SCRIPT`
- `HAX_SUBAGENT_DEPTH`

The standard provider variables `OPENROUTER_API_KEY` and `OPENCODE_API_KEY` should remain unchanged.

### Resolution flow

`src/config/Store.zig` resolves each setting in this order:

1. run overlay
2. conversation overlay
3. environment
4. state file
5. config file
6. default

The registry stores one environment name per setting. There is no alias or dual-prefix mechanism.

`src/cli/StartupConfig.zig` also reads five literals directly to preserve absent versus empty semantics:

- `HAX_PROVIDER`
- `HAX_MODEL`
- `HAX_EFFORT`
- `HAX_PRESET`
- `HAX_SYSTEM_PROMPT`

A prefix change must update the registry and these direct reads together.

## Child-process contract

`src/tool/Bash.zig` gives shell children `AI_AGENT=zi`, but its selection and recursion contract is still Hax-branded:

- `HAX_PROVIDER`
- `HAX_MODEL`
- `HAX_EFFORT`
- `HAX_PRESET`
- `HAX_SUBAGENT_DEPTH`

It also clears `HAX_TRACE`, `HAX_TRANSCRIPT`, `ZI_TRACE`, and `ZI_TRANSCRIPT` in every child.

The effective provider, model, and effort replace inherited values. This supports nested Zi invocations and must move atomically with startup reads. Updating only the reader or only the child writer would break nested selection and subagent depth.

## Filesystem namespaces

Zi's owned filesystem namespace is already correct.

| Namespace | XDG path | HOME fallback |
| --- | --- | --- |
| Config | `$XDG_CONFIG_HOME/zi` | `$HOME/.config/zi` |
| State | `$XDG_STATE_HOME/zi` | `$HOME/.local/state/zi` |
| Cache | `$XDG_CACHE_HOME/zi` | `$HOME/.cache/zi` |

### Config root

- `config.json`
- `AGENTS.md`
- `skills/<name>/SKILL.md`
- prompt files referenced by configuration

### State root

- `state.json`
- `auth.json`
- `history`
- `sessions/<cwd-bucket>/<timestamp>_<uuid>.jsonl`
- `.zi-state.tmp.*`
- `.zi-lock-*`
- `.zi-tmp-*`
- `sessions/.prune`

### Cache root

- `catalog.json`
- `.zi-lock-catalog.json`
- `.zi-tmp-catalog.json-*`

### Process-local output

Bash spill data uses `<cwd>/.zig-cache/tmp/zi-bash-*`, with `/tmp/zi-bash-*` as fallback. These are already Zi names. `.zig-cache` belongs to the Zig build ecosystem, not Hax.

### Namespaces that should not become Zi

- `$HOME/.codex/auth.json` and `$HOME/.codex/config.toml` belong to the external Codex CLI.
- project `AGENTS.md` and `.agents/skills` are provider-neutral agent conventions.
- provider variables such as `OPENAI_API_KEY` belong to provider contracts.
- wire names such as `openai-responses`, `anthropic-messages`, `chat`, and `responses` describe protocols.
- provider IDs such as `llamacpp`, `openrouter`, and `ollama` name integrations.

Zi does not read `$XDG_*_HOME/hax` and has no Hax-to-Zi data importer. That is consistent with a clean Zi product. Adding fallback lookup now would reintroduce the old domain and split ownership and locking.

## Persisted identity

New Zi sessions currently begin with a header shaped like:

```json
{"type":"session","version":1,"hax_version":"0.1.0-dev"}
```

`src/persistence/SessionFile.zig` writes `hax_version`, even though the value is Zi's writer version. The loader ignores both `version` and `hax_version` when it decodes session metadata.

This is the clearest persisted identity leak. New sessions should write `zi_version`. The reader can remain tolerant of older records without treating `hax_version` as Zi's canonical field.

`src/persistence/SessionIndex.zig` also names the canonical filename recognizer `isHaxStandardName`. The behavior is a Zi session naming rule now. A neutral name such as `isCanonicalName` fits its actual role.

The JSONL item vocabulary, cwd bucket algorithm, filename shape, prompt-history encoding, and retention behavior are compatible with Hax. Compatibility is behavior, not branding. Those formats do not need gratuitous changes.

## User-facing residue

Active diagnostics still tell Zi users to configure Hax variables:

- compatible-provider availability in `src/ProviderConfig.zig`
- model-listing fallback in `src/cli/InteractiveCommands.zig`
- llama.cpp startup advice in `src/cli/PrintRun.zig`

Public examples still use Hax names:

- `README.md`
- `scripts/mock/hello.txt`
- `scripts/mock/layout.txt`
- conversation lifecycle documents that name `HAX_TRANSCRIPT`

The mock layout fixture also renders paths and identifiers from the Hax C tree. Those examples should use the current Zi Zig layout when the fixture's purpose is presentation rather than provenance.

## Inert imported settings

Three registered settings have no production consumer:

- `notify`, exposed as `HAX_NOTIFY`
- `keep_awake`, exposed as `HAX_KEEP_AWAKE`
- `trace`, exposed as `HAX_TRACE`

Renaming them to `ZI_*` would make unsupported behavior look supported. The implementation plan should choose one outcome for each: implement it in its owning module, or remove it from the active registry until that capability exists.

There is a second mismatch around OpenRouter attribution. Settings claim title and referer can be changed or disabled, but provider resolution accepts only Zi's fixed defaults. This is not a Hax naming problem, but the domain cleanup will touch those entries and should not preserve misleading descriptions.

## Provenance boundary

Hax references should remain where they answer one of these engineering questions:

- Which behavior is Zi adapting?
- Which exact upstream revision defines that behavior?
- Where did an algorithm, fixture, or byte contract come from?
- Where does Zi intentionally narrow Hax behavior for safety?

That includes:

- `THIRD_PARTY_NOTICES.md`
- the engineering rules in `AGENTS.md`
- research documents with source citations
- focused comments and test names that pin parity

Hax should not remain in:

- environment names
- runtime diagnostics
- public usage examples
- active product documentation
- session writer fields
- internal names whose meaning is now a Zi concept
- fixture content that claims to show the current codebase

The public README ancestry sentence should move out of the product introduction. Legal and engineering attribution already has a precise home in `THIRD_PARTY_NOTICES.md`.

## Recommended Zi contract

Zi is still `0.1.0-dev`. I recommend a hard namespace cut rather than permanent aliases:

1. Rename all 67 `HAX_*` variables to the matching `ZI_*` names.
2. Do not read old Hax variables as fallback inputs.
3. Export only Zi names to child processes.
4. Continue clearing legacy trace and transcript names in children for isolation only if inherited old values could trigger another executable. Do not document or consume them.
5. Write `zi_version` in new session headers.
6. Keep the session reader tolerant of old JSONL records.
7. Keep Zi's current XDG roots. Do not add Hax root migration or fallback lookup.
8. Rename internal Hax-domain identifiers to neutral or Zi names.
9. Rewrite runtime diagnostics, README examples, mock fixtures, and active product docs in Zi terms.
10. Keep exact Hax attribution in notices, research, and parity tests.

A compatibility period would require alias precedence, duplicate-name handling, warnings, child-environment policy, and a removal schedule. That machinery has no product value for a development release unless existing Zi users already depend on Hax-prefixed variables.

## Likely implementation boundaries

### Configuration and startup

- `src/config/Settings.zig`
- `src/config/Store.zig`, only if aliases are chosen
- `src/cli/StartupConfig.zig`
- `src/ProviderConfig.zig`
- `src/cli/LocalStartup.zig`
- `src/cli/InteractiveCommands.zig`
- `src/cli/PrintRun.zig`

### Child process and recursion

- `src/cli/SubagentDepth.zig`
- `src/tool/Bash.zig`
- `src/ToolRuntime.zig`

### Persistence

- `src/persistence/SessionFile.zig`
- `src/persistence/SessionIndex.zig`

### Product text and fixtures

- `README.md`
- `scripts/mock/hello.txt`
- `scripts/mock/layout.txt`
- product and architecture documents that state active configuration names

No filesystem-root implementation change is currently required.

## Acceptance ledger

The migration is complete when all of these are true:

- `ZI_*` is the only documented and accepted Zi configuration prefix.
- all 66 registry entries use `ZI_*` names.
- startup's five direct reads use the same canonical names as the registry.
- nested Zi processes receive effective `ZI_PROVIDER`, `ZI_MODEL`, `ZI_EFFORT`, empty `ZI_PRESET`, and incremented `ZI_SUBAGENT_DEPTH`.
- trace and transcript cannot leak from a parent Zi process into a child.
- every runtime diagnostic names Zi variables.
- new session headers contain `zi_version` and not `hax_version`.
- old compatible session records remain readable if that tolerance is retained.
- current XDG paths and private sidecar names remain unchanged.
- README and mock commands run with Zi variables.
- no active product fixture claims Hax C paths as Zi's current tree.
- Hax mentions left in source and docs are provenance or explicit parity statements.
- the full project ready gate passes.

Useful mechanical checks:

```sh
git grep -n 'HAX_' -- src README.md scripts
git grep -n 'hax_version\|isHax' -- src
git grep -n -i 'hax' -- README.md
git grep -n 'ZI_' -- src/config/Settings.zig src/cli src/tool README.md scripts
zig fmt --check src/
zig build
zig build test
./zig-out/bin/zi --help
./zig-out/bin/zi --version
```

## Decisions for review

1. Confirm the hard environment-prefix cut with no Hax aliases.
2. Confirm that new sessions write only `zi_version`, while the reader remains tolerant of old records.
3. Confirm that Zi will not import or search Hax XDG roots.
4. Decide whether to remove or separately implement `notify`, `keep_awake`, and `trace`.
5. Confirm that public product docs stop naming Hax, while research, parity comments, and legal notices keep attribution.
