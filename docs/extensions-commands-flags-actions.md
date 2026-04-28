# commands, shortcuts, flags, and host actions

## status

contract for `zi-fex.13`.

it follows [extensions](./extensions.md), [runtime](./runtime.md), [runtime roots](./runtime-roots.md), [extensions-lifecycle](./extensions-lifecycle.md), [extensions-events](./extensions-events.md), and [extensions-state-rebinding](./extensions-state-rebinding.md).

why these links matter:

- [extensions](./extensions.md) defines the v2 cutover stance: one public extension api, no direct tui → lua reach-through, and parity-or-better against pi-mono capability (`docs/extensions.md:5-10`, `docs/extensions.md:18-28`).
- [runtime](./runtime.md) defines ownership: agent thread owns extension execution; tui owns input/render and consumes published state (`docs/runtime.md:5-19`).
- [extensions-lifecycle](./extensions-lifecycle.md) defines namespace ownership, bind timing, and the scheduler (`docs/extensions-lifecycle.md:10-18`, `docs/extensions-lifecycle.md:104-117`, `docs/extensions-lifecycle.md:160-199`).
- [extensions-events](./extensions-events.md) defines the `input` interceptor and the session-control interception seams this doc depends on (`docs/extensions-events.md:128-142`).
- [extensions-state-rebinding](./extensions-state-rebinding.md) defines what survives reload/new/fork and why live handles do not (`docs/extensions-state-rebinding.md:20-29`, `docs/extensions-state-rebinding.md:190-240`).

## decision

commands, shortcuts, flags, and host actions are separate classes with one shared rule: the namespace owns registrations; the host exposes merged views.

- **commands** are slash-surface registrations. built-in interactive commands stay tui-owned local interceptors. extension commands are agent-owned extension execution.
- **shortcuts** are semantic intent registrations over keybindings. the tui detects keys, but extension code runs later on the agent thread.
- **flags** are merged declarations with one effective value per canonical flag name.
- **host actions** are host-mediated capabilities surfaced to extensions after bind. some are generic session actions; some are session-control actions and stay command-only.

why split them instead of one vague "interaction" bucket:

- commands and shortcuts start from different raw inputs and different ownership boundaries.
- flags are configuration lookup, not execution.
- host actions are capability seats, not registrations.
- collapsing them would blur the runtime rule that tui input/render hot paths do not call lua inline (`docs/runtime.md:5-19`, `docs/extensions-lifecycle.md:10-18`).

## model

```text
user input
   │
   ├─ key press ───────────────────────────────────────────────────────────────┐
   │                                                                          │
   │   tui thread                                                             │
   │   ├─ built-in reserved keybinding? ── yes ──> local tui/app action       │
   │   └─ extension shortcut winner?  ── yes ──> publish semantic intent ─────┼──> request queue
   │                                                                          │
   └─ submitted text                                                          │
       ├─ starts with "/" ? ── no ────────────────────────────────────────────┤
       │                                                                      │
       └─ yes                                                                 │
           ├─ built-in interactive slash command? ── yes ──> local tui action │
           ├─ extension slash command?          ── yes ──> publish command ───┼──> request queue
           ├─ prompt template / skill match?    ── yes ──> expand text        │
           └─ else keep submitted text                                        │
                                                                              │
agent thread                                                                  │
   ├─ extension command execution -> `ExtensionCommandContext`                │
   ├─ `input` interceptor over surviving prompt text                          │
   ├─ `before_agent_start` prompt assembly                                    │
   └─ `session.prompt()` / provider run                                       │
```

ordering rule:

1. built-in interactive slash commands intercept first.
2. extension slash commands intercept next.
3. prompt-template and skill expansion run only on a command miss.
4. the `input` interceptor sees only text that survived slash resolution.
5. prompt assembly and provider execution happen after that.

why this order:

- current zi already intercepts built-in slash commands before prompt submission (`src/tui/interactive.zig:1821-1827`, `src/tui/interactive.zig:1868-1976`).
- the slash surface already distinguishes builtin, extension, prompt-template, and skill actions (`src/coding_agent/slash_commands.zig:3-38`).
- the `input` interceptor is the seam for default prompt handling, not for slash-command dispatch (`docs/extensions-events.md:132-133`).
- extension command execution belongs on the agent thread under the host scheduler (`docs/extensions-lifecycle.md:162-190`).

## current zi evidence

current zi does not ship this full v2 surface yet. the code shows four relevant facts.

### 1. public extension api is tools + events + spawn + register_command

`installZiTable` installs `zi.register_tool`, `zi.register_command`, `zi.on`, and `zi.spawn`, then publishes the table as global `zi` (`src/coding_agent/extensions/api.zig:64-87`).

`zi.register_command` takes a table with `name` (required string), `handler` (required function), and `description` (optional string). Duplicate canonical names aggregate deterministically into visible invocation names (`x:1`, `x:2`, …) in the runner's `command_registry` (`src/coding_agent/extensions/registries/command_registry.zig:33-85`).

### 2. command/session-control seams already exist as reserved seats

- `src/coding_agent/extensions/registries/command_registry.zig:1-18` says the command registry exists even though `zi.register_command` is not yet exposed.
- `src/coding_agent/extensions/runner.zig:150-159` keeps a generation-local `command_registry` slot and describes it as a reserved target for the bind seam.
- `src/coding_agent/agent_session.zig:2444-2475` defines `ExtensionCommandContext` with command-only session-control methods and says those methods are only safe inside user-initiated commands.

### 3. slash-command dispatch: builtins stay tui-local, extension commands go to the agent thread

- `src/coding_agent/slash_commands.zig:3-38` defines the slash command action families. the `extension` action is now a marker (no inline handler storage); the TUI registry only holds visible name + description.
- `src/tui/interactive.zig` intercepts `/...` input before prompt submission. built-in commands execute locally; extension commands enqueue `AgentRequest.extension_command` through the idle-request path (`dispatchIdleRequest`).
- `src/tui/interactive.zig` rebuilds its TUI-owned `command_registry.dynamic` from the runner's visible command list at startup and after every session replacement (`new`, `fork`, `resume`). this is a tui-owned copy/sync, not direct runner reads and not queued snapshot transport.

### 4. bind still leaves command actions unwired

`bindExtensionRuntimeIfNeeded` passes `.command_actions = null` when binding the runner (`src/coding_agent/agent_session.zig:597-607`).

that combination means the contract in this doc is mostly a reserved-seam decision, not a description of already-shipped zi behavior.

## parity target

pi-mono is the capability target, not the bug-for-bug target.

- **command registration**: pi-mono exposes `RegisteredCommand` and `ResolvedCommand { invocationName }`, and command handlers run on `ExtensionCommandContext` (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:965-975`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:300-324`).
- **shortcut registration**: pi-mono exposes `registerShortcut` on the extension api and models registered shortcuts as extension-owned records (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1047-1054`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1295-1300`).
- **flag registration + `getFlag`**: pi-mono exposes `registerFlag` and `getFlag`, and models flags as extension-owned declarations with `type`, `description`, `default`, and `extensionPath` (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1056-1067`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1287-1293`).
- **generic host actions**: pi-mono exposes `sendMessage`, `sendUserMessage`, `appendEntry`, `setSessionName`, `getSessionName`, `setLabel`, `getActiveTools`, `getAllTools`, `setActiveTools`, `getCommands`, `setModel`, `getThinkingLevel`, and `setThinkingLevel` (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1080-1137`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1365-1379`).
- **command-only session control**: pi-mono keeps `waitForIdle`, `newSession`, `fork`, `navigateTree`, `switchSession`, and `reload` on `ExtensionCommandContext`, not on the base extension api (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:300-324`).
- **scope contrast only**: pi-mono places provider registration nearby in `ExtensionAPI`, but provider contracts are out of scope here (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1195-1210`).

two pi-mono implementation details matter as contrast:

- command duplicates are resolved into deterministic invocation names with numeric suffixes in the runner (`.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:474-520`).
- flag defaults currently seed a shared `flagValues` map at registration time, while visible flag declarations are merged separately; zi v2 does not preserve that duplicate-flag quirk (`.references/pi-mono/packages/coding-agent/src/core/extensions/loader.ts:201-218`, `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:374-383`).

## commands

### classes

the slash surface has four related classes:

1. **built-in interactive commands** — local tui/session shell actions.
2. **extension commands** — extension-owned command handlers.
3. **prompt templates** — slash names that expand into prompt text.
4. **skills** — slash names that expand into skill-driven prompt text.

why keep those distinct:

- built-ins may need immediate local ui/session behavior.
- extension commands may need host-mediated session control.
- prompt templates and skills are expansion sources, not handlers.

### interception and execution

- built-in interactive slash commands intercept before `session.prompt()`.
- extension slash commands are agent-owned and run before `input` hooks, prompt-template expansion, and skill expansion.
- extension command handlers run on the agent thread through `ExtensionCommandContext`, not inline on the tui thread.

why:

- built-ins already intercept on the tui side before prompt submission (`src/tui/interactive.zig:1821-1827`, `src/tui/interactive.zig:1868-1953`).
- `ExtensionCommandContext` exists specifically for command-only session control and explicitly forbids tool/event-style mid-turn use (`src/coding_agent/agent_session.zig:2444-2475`).
- the lifecycle contract says command bodies are agent-thread work and may suspend only under the host scheduler (`docs/extensions-lifecycle.md:162-190`).

### what is still pending after this slice

- **command-only session-control actions** (`new_session`, `fork`, `switch_session`, `navigate_tree`, `reload`, `wait_for_idle`) are not yet wired on `ExtensionCommandContext`. the context fields are present as `nil` so extensions that try to use them get an honest Lua error rather than a missing-key diagnostic.
- **yieldable command bodies** are not supported. if a command handler calls a yieldable host function (e.g. `zi.spawn`), dispatch returns `error.UnexpectedYield` and the command path fails.
- **fallback to old inline tui execution** was removed entirely; extension commands that cannot reach the agent thread (e.g. queue full) surface the failure honestly in status text.

### naming and visibility

- command registrations are namespace-owned.
- the visible command list is a merged host view.
- built-ins stay built-in entries in that host view; extension commands contribute namespace-owned entries to the same visible slash surface.
- if exactly one extension registers command name `x`, its visible invocation name is `x`.
- if multiple extensions register `x`, the visible invocation names are `x:1`, `x:2`, `x:3`, in canonical namespace order derived from [runtime roots](./runtime-roots.md): `explicit > user > project > builtin`, then deterministic discovery/bind order inside that precedence. the bare `x` does not exist in the duplicate case.

why:

- namespace ownership and merged views are already the lifecycle rule (`docs/extensions-lifecycle.md:10-18`).
- pi-mono already resolves duplicates into `ResolvedCommand.invocationName` values; numeric suffixing is the parity shape worth keeping (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:973-975`, `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:474-520`).
- zi should not keep the current silent first-wins placeholder from the reserved registry once commands become public (`src/coding_agent/extensions/registries/command_registry.zig:54-69`). a merged visible command surface needs every colliding command to stay callable.

## shortcuts

- shortcut registration is namespaced.
- some built-in shortcuts are reserved and cannot be overridden.
- other built-in shortcuts are overridable.
- extension-vs-extension shortcut conflicts resolve in canonical namespace order into one visible shortcut winner.
  that order comes from [runtime roots](./runtime-roots.md): `explicit > user > project > builtin`, then deterministic discovery/bind order inside that precedence.
- shortcut activation publishes semantic intent to the agent thread; raw tui key events do not call lua inline.

why:

- pi-mono already separates reserved built-ins from overridable built-ins for shortcut conflicts (`.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:55-95`, `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:394-437`).
- zi's runtime contract forbids direct tui hot-path lua execution (`docs/runtime.md:5-19`, `docs/extensions-lifecycle.md:10-18`).
- current tui input handling already turns raw keys into local semantic actions instead of routing terminal key events into extension code (`src/tui/interactive.zig:960-1018`).

practical consequence:

the thing that crosses the thread boundary is the shortcut meaning, not the original terminal key bytes. that keeps key decoding, overlays, and redraw local to the tui while keeping extension execution on the agent thread.

## flags

- flags are extension registrations with `type`, `description`, and `default`.
- flag registrations are namespace-owned.
- `getFlag(name)` reads the merged effective value for canonical flag name `name`.
- duplicate flag registrations do not create multiple effective values.

### deterministic precedence rule

for each canonical flag name:

1. pick the visible declaration from canonical namespace precedence from [runtime roots](./runtime-roots.md): `explicit > user > project > builtin`, then deterministic discovery/bind order inside that precedence.
2. if cli parsing supplied a value for that canonical flag name, that value wins.
3. otherwise, if the visible declaration has a `default`, that default wins.
4. otherwise the effective value is `undefined`.

corollaries:

- losing duplicate declarations do not seed defaults.
- losing duplicate declarations do not contribute alternate cli parse seats.
- `getFlag(name)` returns the same merged effective value no matter which extension registered that canonical name.
- the visible declaration is also the source of truth for flag type and help text.

why this exact rule:

- pi-mono's type surface is right: registration plus merged lookup (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1056-1067`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1287-1293`).
- pi-mono's current duplicate behavior is not: registration-time writes to shared `flagValues` can make one declaration visible while another declaration's default remains sticky (`.references/pi-mono/packages/coding-agent/src/core/extensions/loader.ts:201-218`, `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts:374-383`).
- zi v2 normalizes that away so help text, parse rules, defaulting, and `getFlag` all speak about the same visible declaration.

## host actions

host actions split into two classes.

### generic actions

these are ordinary extension capabilities:

- `sendMessage`
- `sendUserMessage`
- `appendEntry`
- `setSessionName` / `getSessionName`
- `setLabel`
- `getActiveTools` / `getAllTools` / `setActiveTools`
- `getCommands`
- `setModel`
- `getThinkingLevel` / `setThinkingLevel`

why these stay generic:

they are host-mediated queries or mutations over the current bound session, not session replacement. pi-mono already groups them as shared extension actions (`.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1080-1137`, `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:1365-1379`). zi's bind contract says session-local host actions become valid at bind (`docs/extensions-lifecycle.md:104-117`).

### command-only session-control actions

these stay on `ExtensionCommandContext` only:

- `waitForIdle`
- `newSession`
- `fork`
- `navigateTree`
- `switchSession`
- `reload`

why these stay command-only:

- current zi already documents that fork/switch/reload-style actions are only safe inside user-initiated commands, never inside tool execution or event observers (`src/coding_agent/agent_session.zig:2444-2452`).
- the event contract gives these actions dedicated interception seams like `session_before_switch`, `session_before_fork`, and `session_before_tree` (`docs/extensions-events.md:139-142`).
- reload/new/fork tear down live handles and create fresh generations; that is a session-boundary transition, not an ordinary mid-turn mutation (`docs/extensions-state-rebinding.md:25-26`, `docs/extensions-state-rebinding.md:190-240`).

practical rule:

if an action can replace the session, move the tree head, or force a generation swap, it is command-only.

## relationship to lifecycle, events, ui ownership, and state/rebinding

### lifecycle

commands, shortcuts, and flags are generation-scoped namespace registrations. host actions become callable only after bind (`docs/extensions-lifecycle.md:10-18`, `docs/extensions-lifecycle.md:104-117`). command execution is scheduled agent work, not a tui callback (`docs/extensions-lifecycle.md:162-190`).

### events

the `input` interceptor stays the seam for default prompt handling, after slash-command resolution (`docs/extensions-events.md:132-133`). session-control commands feed into the dedicated session interception seams already defined in the event contract (`docs/extensions-events.md:139-142`).

### ui ownership

the tui owns raw key events, local slash interception for built-ins, rendering, and autocomplete surfaces. extensions do not get raw key callbacks and do not execute lua in input/render hot paths (`docs/runtime.md:5-19`, `docs/extensions-lifecycle.md:10-18`). current autocomplete code already warns that future extension command visibility must come from a tui-owned published snapshot, not direct runner reads (`src/tui/autocomplete.zig:153-160`).

### state and rebinding

reload/new/resume/fork rebuild the merged command, shortcut, and flag views from the new generation. live handles do not survive. persisted extension state may survive, but registrations and session-live capabilities are rebound from scratch (`docs/extensions-state-rebinding.md:20-29`, `docs/extensions-state-rebinding.md:190-240`).

for flags, this means the host re-applies the same deterministic effective-value rule against the newly visible declarations after each generation rebuild.

## non-goals

this doc does not define:

- the full event payload schemas; see [extensions-events](./extensions-events.md)
- provider registration contracts
- tool contracts; see [extensions-tools](./extensions-tools.md)
- ui retained objects or semantic presentation records
- persistence storage formats
- exact cli parsing syntax for boolean vs string flags beyond the merged precedence rule above
- the transport shape of the agent↔tui publication used to surface merged commands or shortcuts
