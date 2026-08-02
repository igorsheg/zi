# Extension reload UX

Status: implemented, 2026-07-30

This note characterizes Pi's `/reload` product path, compares it with Zi's already-shipped extension generation replacement, and proposes a Pi-aligned implementation that keeps session identity stable while teaching one author habit: edit trusted extensions or session resources, reload, keep working.

Reviewed against:

- Zi `main` at research time (host reload, custom entries, RPC, code mode shipped)
- Pi `v0.82.1` (`b4f293684bba718d59cc1157679bcf6157b3a7f5`) at [`docs/reference-pins.md`](reference-pins.md)
- Existing Zi decisions: [ADR 0012](adr/0012-agent-session-runtime-owns-replacement.md), [ADR 0021](adr/0021-compiled-zi-self-hosts-extension-workers.md), [ADR 0023](adr/0023-session-journal-separates-custom-state-and-custom-messages.md), [building-block strategy](building-block-strategy.md), [extension infrastructure spec](extension-system-infrastructure-implementation-spec.md)

Pi remains the coding-agent architecture and observable-behavior reference. Zi does not copy Pi's in-process runner, extension UI surface, or interactive screen architecture.

## Outcomes

The first Zi implementation should provide:

1. one product habit: edit extensions / skills / prompts / settings / context files → `/reload` → same session continues;
2. one client-independent `AgentSession.reload()` orchestration API that interactive mode calls and later headless surfaces can reuse;
3. stable session identity: same `SessionManager`, journal path, shell, code-mode owner, and cwd-bound `ZiPaths`;
4. reread of settings and session resources before extension rediscovery;
5. rediscovery through the existing trust-gated `discoverExtensionLoadPlan` policy;
6. whole-generation replacement through a typed `ExtensionHost.reload(...)` result;
7. tool catalog and system-prompt rebind from the host's existing catalog listener;
8. lifecycle order `session_shutdown(reason: "reload")` then candidate `session_start(reason: "reload")` when a generation was started;
9. recovery from a failed host generation via the same product path (no implicit auto-restart);
10. idle-only admission owned by `AgentSession`, not only by the TUI;
11. attempt-scoped, source-attributed diagnostics from settings, resources, discovery, and host reload;
12. one slash-command descriptor and interactive dispatch;
13. behavior tests for success, pre-commit candidate retention, concurrent refusal, crash recovery, durable-state restore on `session_start`, and interactive wiring;
14. docs and golden-path update: crash or edit requires explicit reload.

Print/JSON command surfaces and an RPC protocol operation are later mode-wiring slices over the same session API. They are not acceptance requirements for the first implementation.

## Non-goals

This slice does not require:

- whole `AgentSessionRuntime` rebuild (that remains `/new`, `/resume`, and project-trust resolution);
- extension-callable `ctx.reload()` / command-context reload (commands slice);
- package install, update, remove, or provenance;
- themes, models.json hot reload, or keybinding-file reload as part of the first cut;
- extension `resources_discover`, provider registration, interception, or UI contributions;
- automatic worker restart on crash;
- queued concurrent reloads;
- changing project-trust admission without the existing trust-decision replacement path;
- broad Pi extension API compatibility or in-process runner semantics;
- print/JSON command-loop or RPC protocol wiring in the first implementation slice.

## Recommendation

Treat reload as **in-session resource and extension-generation refresh**, not session replacement.

| Operation              | Owner                      | Session identity             | Journal                  | Extension process                              |
| ---------------------- | -------------------------- | ---------------------------- | ------------------------ | ---------------------------------------------- |
| `/reload`              | `AgentSession`             | same                         | same                     | replace generation via `ExtensionHost`         |
| `/new`, `/resume`      | `AgentSessionRuntime`      | new runtime                  | new or other file        | dispose old host; start new                    |
| project-trust decision | `AgentSessionRuntime`      | new runtime, often same file | usually resume same file | dispose old host; start new with new admission |
| worker crash           | `ExtensionHost` → `failed` | same                         | same                     | dead until explicit reload                     |

Pi collapses settings, resources, packages, extensions, themes, and runner rebuild into `AgentSession.reload()`. Zi should keep the same **product seam** on `AgentSession`, but route extension replacement through the already-accepted process host instead of constructing a new in-process `ExtensionRunner`.

## Pi provenance

### Product surface

| Surface           | Pi `v0.82.1` location                                           | Behavior                                                                                                              |
| ----------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Slash command     | `core/slash-commands.ts`                                        | `{ name: "reload", description: "Reload keybindings, extensions, skills, prompts, themes, and context files" }`       |
| Session API       | `core/agent-session.ts` `reload()`                              | Orchestrates shutdown → settings → resources → rebuild runner → optional `session_start`                              |
| Extension API     | `core/extensions/types.ts` `ExtensionCommandContext.reload()`   | Mode-bound handler; interactive routes to UI command, print/RPC call `session.reload()`                               |
| Interactive UX    | `modes/interactive/interactive-mode.ts` `handleReloadCommand()` | Blocks while streaming/compacting; shows reload chrome; refreshes keybindings/themes/editor/autocomplete; status text |
| Print / RPC       | `modes/print-mode.ts`, `modes/rpc/rpc-mode.ts`                  | `commandContextActions.reload → session.reload()`                                                                     |
| Lifecycle reasons | extension types                                                 | `session_start.reason` includes `"reload"`; `session_shutdown.reason` includes `"reload"`                             |
| Stale context     | runner / loader                                                 | Captured extension ctx throws after reload or session replacement                                                     |

### `AgentSession.reload()` sequence

From `packages/coding-agent/src/core/agent-session.ts` at `v0.82.1`:

```text
previousFlagValues = extensionRunner.getFlagValues()
emit session_shutdown { reason: "reload" }   // old runner, if handlers exist
settingsManager.reload()
syncQueueModesFromSettings()
resetApiProviders()
resourceLoader.reload()                      // settings again, packages, extensions, skills, prompts, themes
_buildRuntime({
  activeToolNames: current,
  flagValues: previousFlagValues,
  includeAllExtensionTools: true
})                                           // new ExtensionRunner + tool registry
if mode bindings present:
  beforeSessionStart?.()                     // interactive rebuilds chat before handlers notify
  emit session_start { reason: "reload" }
  extendResourcesFromExtensions("reload")
```

Important properties:

1. **Same `AgentSession` and `SessionManager`.** Reload is not `newSession` / `switchSession`.
2. **Old runner receives `session_shutdown` before teardown.** New runner receives `session_start` only after rebuild.
3. **Flag values survive reload.** Provider/tool allowlists and active tool names are intentionally preserved where possible.
4. **Bindings gate `session_start`.** If no UI/command/shutdown/error bindings exist, Pi rebuilds the runner but does not emit reload `session_start`. Zi should not copy that quirk: a started session should always complete host lifecycle replacement, because workers are already bound to session operations and tools.
5. **Admission is mostly UI-side.** `reload()` itself does not check `isStreaming`; interactive mode refuses streaming and compaction. Zi should move admission into `AgentSession` so headless modes cannot race a live turn.

### Resource loader reload

`DefaultResourceLoader.reload()`:

- clears extension module cache when already loaded;
- optionally runs a pre-trust extension pass when `resolveProjectTrust` is supplied;
- preserves current `projectTrusted` and reloads settings for that trust state;
- resolves packages and CLI extension paths;
- loads the final extension set, skills, prompts, themes;
- stores a new `extensionsResult` for the next runner build.

Zi has no package manager or theme loader in this slice. The analogous steps are: settings reload, `ResourceLoader.load()`, and `discoverExtensionLoadPlan(...)`.

### Interactive reload UX

`handleReloadCommand()`:

1. refuse when `session.isStreaming` or `session.isCompacting`;
2. `resetExtensionUI()`;
3. replace the editor with a "Reloading..." container and focus it;
4. call `session.reload({ beforeSessionStart: restoreChatBeforeSessionStart })`;
5. reload keybindings, themes, editor padding/autocomplete, hardware cursor, clear-on-shrink;
6. re-setup autocomplete and extension shortcuts;
7. show loaded-resource diagnostics;
8. optionally persist implicit project trust for a cwd that gained a `.pi` directory during an implicitly trusted session;
9. status on success; restore editor and show error on failure.

Zi-relevant lessons:

- users need a visible busy state and a single success/failure status;
- chat/transcript should remain coherent if reload handlers emit messages (`beforeSessionStart` ordering mattered enough for Pi regression `#5943`);
- project-trust mutation during reload is a special case. Zi already owns trust decisions through `AgentSessionRuntime.decideProjectTrust()` and should not reintroduce implicit trust-on-reload unless a concrete Zi path needs it.

### Lifecycle test pin

Pi's suite asserts:

```text
start:startup → shutdown:reload → start:reload
```

after `bindExtensions` and `session.reload()` (`agent-session-model-extension.test.ts`).

### What Pi reloads that Zi should split or defer

| Pi reloads                                       | Zi v1 reload                             | Later                                         |
| ------------------------------------------------ | ---------------------------------------- | --------------------------------------------- |
| Extensions                                       | yes, via `ExtensionHost`                 | —                                             |
| Skills / prompts / context / system prompt files | yes, via `ResourceLoader`                | —                                             |
| Settings files                                   | yes, via `SettingsManager`               | —                                             |
| Queue modes from settings                        | yes, apply steering/follow-up if changed | —                                             |
| Packages                                         | no                                       | package slice                                 |
| Themes                                           | no                                       | terminal polish / theme owner                 |
| Keybindings file                                 | no unless already file-backed            | keybinding owner                              |
| models.json                                      | no                                       | provider registration / model catalog         |
| Extension UI / shortcuts                         | n/a                                      | commands + declarative terminal contributions |
| `resources_discover`                             | no                                       | interception / resource contribution slice    |
| Extension flag values                            | n/a today                                | if flags ever exist                           |
| API provider reset                               | no                                       | provider registration                         |

## Current Zi state

### Already shipped

| Piece                                        | Location                                 | Status                                                      |
| -------------------------------------------- | ---------------------------------------- | ----------------------------------------------------------- |
| Generation replacement                       | `ExtensionHost.reload(plan, reason)`     | implemented + host tests                                    |
| Lifecycle reasons                            | protocol + `@with-zi/extension-api`      | `"reload"` already valid                                    |
| Pre-commit candidate failure retains current | host reload                              | tested                                                      |
| Stale generation rejection                   | host                                     | tested                                                      |
| Concurrent reload refusal                    | host throws while `replacing`            | tested                                                      |
| Crash → `failed`, session usable             | host + runtime-extension tests           | tested; recovery is explicit reload                         |
| Tool catalog listener                        | `AgentSession` binds `#applyActiveTools` | live rebind on catalog change                               |
| Session operations binding                   | custom entries/messages                  | survives host reload if binding kept                        |
| Settings file reload                         | `SettingsManager.reload()`               | implemented                                                 |
| Resource load                                | `ResourceLoader.load()`                  | one-shot today; no session apply path                       |
| Trust-gated discovery                        | `discoverExtensionLoadPlan`              | implemented                                                 |
| Whole-runtime replace                        | `AgentSessionRuntime`                    | `/new`, `/resume`, `decideProjectTrust` (reason `"reload"`) |
| Durable counter restore on `session_start`   | extension-api + journal                  | works for startup; reload should reuse                      |

### Missing product path

| Gap                                            | Why it matters                                                                 |
| ---------------------------------------------- | ------------------------------------------------------------------------------ |
| No `AgentSession.reload()`                     | Host reload is infrastructure; modes and users have no session-level operation |
| `#resources` assigned once                     | Skills/prompts/context cannot refresh without a new session field write        |
| Session does not retain rediscovery inputs     | Explicit extension paths + project admission live in runtime construction only |
| No `/reload` slash command                     | No teachable habit                                                             |
| No interactive `/reload` wiring                | Host path is not reachable through the reference product                       |
| No session-level reload admission              | Headless callers could overlap a turn                                          |
| Docs say "explicit reload" without shipping it | Golden path recovery story is incomplete                                       |

### Critical ownership distinction already in tree

`AgentSessionRuntime.decideProjectTrust()` calls `#replace(..., "reload")`. That reason string is an **extension lifecycle reason on a new runtime**, not product `/reload`.

```text
decideProjectTrust
  -> construct next AgentRuntime under new project admission
  -> dispose current session with reason "reload"
  -> startExtensionLifecycle("reload") on the next session
```

Product `/reload` must not go through `AgentSessionRuntime.#replace`. Trust changes can alter whether project settings, resources, and extensions are admitted; that is a cwd-bound service rebuild. Ordinary reload keeps the current admission snapshot and rereads files under it.

## Design

### One-sentence contract

`AgentSession.reload()` rereads cwd-bound settings and session resources, rediscovers trusted extension sources, replaces the extension generation in place, and leaves the conversation journal and session identity unchanged.

### Owners

| Concern                      | Owner                                                     | Notes                                                                       |
| ---------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| Admit reload                 | `AgentSession`                                            | idle, no model mutation, no pending input, lifecycle not disposing          |
| Settings reread              | `SettingsManager`                                         | existing `reload()`; preserve project excluded/absent/trusted state         |
| Apply settings side effects  | `AgentSession`                                            | steering/follow-up modes; other live settings only if already session-owned |
| Resource reread              | `ResourceLoader`                                          | existing `load()`; loader stays immutable about paths/admission             |
| Resource snapshot            | `AgentSession`                                            | replace private resources reference; rebuild system prompt                  |
| Extension rediscovery        | pure `discoverExtensionLoadPlan`                          | same paths, project admission, explicit paths as construction               |
| Generation swap              | `ExtensionHost`                                           | typed `reload(request, "reload")` result with attempt diagnostics           |
| Tool + prompt rebind         | `AgentSession` via catalog listener / `#applyActiveTools` | no second tool owner                                                        |
| Journal / messages           | `SessionManager`                                          | untouched                                                                   |
| Shell / code mode / paths    | remaining session services                                | untouched                                                                   |
| `/new` `/resume` trust       | `AgentSessionRuntime`                                     | not this operation                                                          |
| Slash descriptor             | `slash-commands.ts`                                       | coding-agent catalog                                                        |
| Interactive busy UX + status | `InteractiveMode` / prompt store                          | render + call session; no rediscovery in TUI                                |
| Later headless wiring        | each product mode                                         | reuse `session.reload()` without moving policy out of the session           |

### State

Extend the session-owned `Activity` union:

```ts
| { type: "reloading"; operationId: number; settled: Promise<void> }
```

Reload must mutually exclude runs, compaction, authentication, model mutation, queue admission, session replacement, and another reload through the same activity owner. A failed agent run is not a reload-admissible activity; failed extension-host state is separate and may be recovered while session activity is idle.

Extension lifecycle callbacks need a narrower exception than public session operations:

- host-bound custom-state reads and appends remain admitted while reloading so retiring `session_shutdown` and candidate `session_start` can persist and restore state;
- `custom_message_send` with delivery `append` is admitted only from the candidate `session_start` generation and flows through normal journal and transcript projection;
- conversation delivery is closed during retiring `session_shutdown`;
- `trigger_turn`, `steer`, `follow_up`, and `next_turn` are rejected while reloading because they would create or queue agent work before the reload transition settles;
- public `appendCustomEntry()` and `sendCustomMessage()` do not become generally reload-safe. The existing private extension-operation binding owns these source-specific exceptions.

Disposal supersedes reload without racing a second extension shutdown. It transitions session activity to `disposed`, asks the host to dispose, and includes the reload settlement in `waitForIdle()`. Reload completion changes activity back to `idle` only when it still owns the `reloading` state.

### Admission

`AgentSession.reload()` admits only when:

- activity is `idle`;
- authentication is idle;
- model mutation is `none`;
- pending input queue is empty;
- extension lifecycle is `absent` or `started`; pre-start reload from `unbound` is not a product operation;
- host snapshot is `disabled`, `ready`, or `failed`, never `starting`, `dispatching`, `replacing`, `stopping`, or `disposed`;
- session is not disposed.

This is stricter than Pi's UI-only streaming check and matches Zi's `assertReplaceable()` discipline without replacing the runtime.

### Sequence

```text
admit reload
activity = reloading

settingsManager.reload()
apply live settings side effects (queue modes)

resources = await resourceLoader.load()
#resources = resources
#applyActiveTools()                    // system prompt picks up new context/skills tooling text

discovery = discoverExtensionLoadPlan(paths, project, explicitExtensionPaths)
extensionResult = await host.reload({
  plan: discovery.plan,
  diagnostics: discovery.diagnostics.map(extensionDiscoveryDiagnostic),
  omittedDiagnostics: discovery.omittedDiagnostics
}, "reload")
// host:
//   owns one attempt-scoped diagnostic batch and typed outcome
//   spawn candidate, initialize
//   on pre-commit failure: retain current generation and return `retained`
//   on success: shutdown current(reason reload), commit tools, session_start(reason reload) if lifecycle started
//   on candidate session_start failure: old generation is already retired; return `failed`

emit reload result / surface this attempt's diagnostics
if activity still owns this reload: activity = idle
```

Notes:

1. **Settings and resources refresh even if extension reload retains the previous generation.** Authors still get skill/prompt/context updates when a bad extension candidate fails.
2. **Do not call `sessionShutdown` at the session layer before `host.reload`.** The host already shuts down the current generation after the candidate initializes. Doing both would double-shutdown or shut down before knowing the candidate is healthy.
3. **Keep session-operation bindings installed across reload.** Nested custom-entry reads and appends during candidate `session_start` and retiring generation `session_shutdown` use the private extension-operation admission above; host tests already cover shutdown append during replacement disposal.
4. **Tool invocations outstanding on the old generation settle failed when the generation retires.** That is existing host behavior; admission should make outstanding tools impossible by requiring idle.
5. **No `beforeSessionStart` chat rebuild hook in coding-agent.** If interactive needs to freeze chrome, it does that around the `reload()` await. Candidate `session_start` append-only custom messages flow through normal session events and transcript projection.

### Rediscovery inputs

Construction-time values required again at reload:

- `ZiPaths` (from services)
- project configuration admission (`trusted` / `untrusted` / `absent`)
- explicit CLI/extension paths
- `ResourceLoader` instance
- `ExtensionHost` instance

`AgentSession` should receive a narrow reload dependency at construction rather than growing a generic service locator:

```ts
interface SessionReloadDeps {
  readonly resourceLoader: ResourceLoader
  readonly paths: ZiPaths
  readonly project: ProjectConfigurationAdmission
  readonly extensionPaths: readonly string[]
}
```

Absent host ⇒ reload still refreshes settings/resources and is otherwise a no-op for extensions.

### Failure policy

| Failure                                            | Session after                              | Extensions after                                                | Resources/settings                                                 |
| -------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------------ |
| Settings invalid scope                             | idle; attempt diagnostic                   | unchanged until host step                                       | recomputed by existing `SettingsManager` merge/fallback rules      |
| Resource load diagnostic                           | idle                                       | continues                                                       | new snapshot may be partial; current resource diagnostics returned |
| Discovery diagnostic                               | idle                                       | host admits it into this attempt; may reload empty/partial plan | refreshed                                                          |
| Candidate spawn/init failure before commit         | idle; outcome `retained`                   | **current generation retained**                                 | refreshed                                                          |
| Candidate `session_start` failure after commit     | idle; outcome `failed`                     | old generation retired; host `failed`                           | refreshed                                                          |
| Current crashes during replace and candidate fails | idle; outcome `failed`                     | host `failed`                                                   | refreshed                                                          |
| Host already `failed`, reload succeeds             | idle; outcome `replaced`                   | new generation started                                          | refreshed                                                          |
| Host already `failed`, reload fails                | idle; outcome `failed`                     | still `failed`                                                  | refreshed                                                          |
| Reload admitted then dispose                       | disposed; outcome `superseded` if observed | host dispose supersedes                                         | best effort                                                        |

Never leave activity stuck in `reloading` without settlement. Never swap `SessionManager`. Never invent a second tool catalog.

### Durable extension state

Reload is the recovery path that makes ADR 0023 real for authors:

1. retiring generation may append final custom state during `session_shutdown` / dispose;
2. new generation `session_start(reason: "reload")` reads `getSessionEntries`;
3. conversation custom messages remain in the journal and transcript because the session identity did not change.

The durable-counter example should gain a reload acceptance path: increment → `/reload` → counter restores from journal, not memory.

### Mode wiring

| Mode             | First-slice behavior                                                                                                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Interactive      | `/reload` → closed intent → `session.reload()`; busy status; show attempt diagnostics/outcome; invalidate completion catalogs derived from resources |
| Print / JSON     | no new command surface; direct SDK callers may call `AgentSession.reload()`                                                                          |
| RPC              | deferred closed protocol operation with its own protocol tests and release note                                                                      |
| Extension worker | no `ctx.reload()` in this slice                                                                                                                      |

The accepted first cut is **coding-agent API + interactive `/reload` + tests**. RPC and any print/JSON command surface are later deliberate additions, not hidden behavior in this slice.

### Interactive UX shape

Keep Composer mounted (picker-stack rules). Do not replace the editor with a foreign focus root unless OpenTUI forces it.

Preferred Zi shape:

1. admit locally from prompt store / mode (optional early warning);
2. publish the keyed `Reloading…` prompt notice;
3. `await session.reload()`;
4. call an explicit `SlashController.invalidateCatalog()` after the session returns, because session generation remains stable while resources changed;
5. let the next completion read slash/skill/template commands from current `session` getters;
6. show `replaced`, `retained`, `disabled`, `failed`, or `superseded` status using the typed result;
7. project only this reload attempt's settings/resource/discovery/host diagnostics through existing diagnostic presentation.

The invalidation is client-owned transient cache control, not a copied resource revision or second command catalog.

Early UI warnings ("wait for the current response") are convenience only; `AgentSession` remains authoritative and must reject races.

### Public extension API

No new extension-api surface is required for v1 reload UX.

Already sufficient:

- `session_start` / `session_shutdown` reasons include `"reload"`
- custom entry read/append and custom message send
- tool registration on the new generation

Defer `ctx.reload()` until extension commands exist and have a mode-bound action host.

## Implementation plan

### 1. Session reload dependencies and mutable resources

- Thread `SessionReloadDeps` through `createAgentSession` / runtime construction.
- Change `#resources` from constructor-only assignment to a private reassignable field.
- Keep getters returning the current snapshot.

### 2. Typed host reload and attempt diagnostics

- Replace the void host result with a bounded result:

```ts
type ExtensionReloadOutcome = "replaced" | "retained" | "disabled" | "failed" | "superseded"

interface ExtensionReloadRequest {
  readonly plan: ExtensionLoadPlan
  readonly diagnostics: readonly ExtensionDiagnostic[]
  readonly omittedDiagnostics: number
}

interface ExtensionReloadResult {
  readonly outcome: ExtensionReloadOutcome
  readonly snapshot: ExtensionHostSnapshot
  readonly diagnostics: readonly ExtensionDiagnostic[]
  readonly omittedDiagnostics: number
}
```

- Move or expose the existing discovery-to-host diagnostic projection so startup and reload use one mapping.
- Admit mapped discovery diagnostics as part of the reload request rather than through the startup-only `admitDiagnostics()` API.
- Keep `ExtensionHostSnapshot.diagnostics` as bounded host-lifetime observability, but also return the bounded diagnostics produced by this attempt so stale or saturated history cannot hide the current result.
- Return `retained` only for a pre-commit candidate failure while a current generation remains. A candidate `session_start` failure is `failed` because retirement has already committed.
- Return `superseded` when host disposal wins the replacement race.
- Gate session operations by the requesting generation and lifecycle phase: old shutdown may read/append custom state but cannot send conversation messages; candidate start may read/append state and send only append-delivery custom messages.

### 3. `AgentSession.reload()`

- Add activity/admission/settlement and the private lifecycle-operation exceptions defined above.
- Orchestrate settings → resources → discover → `host.reload`.
- Apply queue modes from reloaded settings.
- Return a narrow result:

```ts
interface SessionReloadResult {
  readonly resources: SessionResources
  readonly extensions: ExtensionReloadResult | undefined
  readonly settingsErrors: readonly SettingsError[]
}
```

- The result is sufficient for direct callers. Do not add a session event in the first slice; interactive dispatch already retains the promise and result.

### 4. Slash command and completion invalidation

- Add `reload` to `builtinSlashCommands`.
- Interactive dispatches it to session reload.
- Add explicit `SlashController.invalidateCatalog()` and call it after any completed reload, including `retained`, because resources refresh before extension replacement.
- Completion lists `/reload` with the built-in catalog and reads refreshed resource commands after invalidation.

### 5. Tests

Coding-agent:

- lifecycle order `startup start → reload shutdown → reload start` through a real or fixture worker;
- skill/prompt/context text changes are visible after reload without new session id;
- settings queue-mode change applies;
- pre-commit candidate spawn/init failure returns `retained` and keeps old tools and session id;
- candidate `session_start` failure returns `failed` after the old generation retires;
- failed host recovers with outcome `replaced` on successful reload;
- concurrent reload rejected;
- reload refused while running / compacting / authenticating / changing model / queued input / failed-run recovery;
- retiring shutdown can append custom state and candidate start restores it while activity is `reloading`;
- candidate start can append a custom message, while turn-triggering delivery is rejected;
- dispose during reload returns/supersedes settlement and does not leak workers.

TUI:

- status distinguishes replaced, retained, disabled, and failed outcomes;
- refusal while streaming;
- explicit catalog invalidation picks up a new skill after reload.

Release/example:

- durable-counter or custom-tool docs: edit or crash → `/reload` → recover.

### 6. Docs and roadmap

- Update [`roadmap.md`](roadmap.md) as implementation begins and mark the slice complete only after acceptance passes.
- Update [`extensions.md`](extensions.md) and golden path recovery text.
- No new ADR unless implementation discovers an ownership conflict with ADR 0012. Expected result: **no ADR**, because reload stays on `AgentSession` and replacement stays on `AgentSessionRuntime`.

## Acceptance checklist

- [x] `AgentSession.reload()` exists and is the only product orchestration entry
- [x] Same session id and journal path before/after reload
- [x] Settings, resources, and extensions reread under current trust admission
- [x] Host generation replacement uses reason `"reload"` end-to-end
- [x] Pre-commit candidate failure returns `retained` and preserves the current generation
- [x] Candidate lifecycle failure after retirement returns `failed`
- [x] Failed generation can recover through `/reload`
- [x] Idle-only admission is enforced in coding-agent tests
- [x] Interactive `/reload` distinguishes typed outcomes and surfaces only current-attempt diagnostics
- [x] Completion catalogs invalidate without replacing session identity
- [x] Durable extension state survives reload via journal projection
- [x] No `AgentSessionRuntime` rebuild on ordinary reload
- [x] No package/theme/provider/command/UI contribution scope creep
- [x] Formatting, lint, types, unit tests, and relevant compiled acceptance pass

## Resolved boundaries

1. **Headless mode wiring**  
   The first slice ends at the client-independent session API and interactive command. RPC and any print/JSON command surface are later mode-owned additions.

2. **Reload when project config appears mid-session under unresolved trust**  
   Pi can auto-save implicit trust on reload. Zi keeps using the trust picker + `decideProjectTrust` replacement. `/reload` does not change admission.

3. **Ephemeral client UI state**  
   Invalidate only derived catalogs such as skills, prompts, and slash completion. Do not rebuild the transcript; journal identity is unchanged.

4. **ResourceLoader API**  
   `load()` remains the operation because the loader is stateless about previous snapshots. Do not add a mutable resource cache or a `reload()` alias without separate pressure.

## Summary

Pi's `/reload` is an **in-session rebuild of resources and the extension runner**, with interactive chrome and a broad secondary refresh list. Zi already owns the hard part—supervised generation replacement, stale rejection, and crash isolation—inside `ExtensionHost`. The missing product is a narrow `AgentSession.reload()` that rereads settings/resources, rediscovers extensions under current trust, calls the host, and exposes `/reload` without destroying conversation identity.

That is the right next slice: it completes the custom-tool and durable-state author loop, uses infrastructure already paid for, and stays clear of `AgentSessionRuntime` replacement, packages, interception, and extension UI.
