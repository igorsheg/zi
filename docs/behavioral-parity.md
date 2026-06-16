# behavioral parity with pi-mono

Zi preserves pi-mono behavior at the `coding_agent` boundary. Zi does not
preserve pi-mono's TUI architecture.

This file is the parity ledger. A row is complete only when the behavior has a
Zi owner, a pi-mono reference, and a test that proves the behavior through the
public coding-agent boundary.

Reconciled 2026-06-13 against the mailbox architecture: the pre-mailbox
owners (`sdk`, `AgentSessionRuntimeHost`, `session_config`, `session_events`)
were collapsed into `session_runtime` + `client_protocol`, and most proving
tests were renamed in that refactor. Rows below pin live test names. Two
behaviors changed shape deliberately (session replacement, prompt streaming
behavior) and are recorded as such, not as regressions.

## rules

- Port behavior, not TypeScript structure.
- Keep `src/coding_agent` boring: one owner, one mutation path, explicit errors.
- Frontends observe and command session behavior; they do not own policy.
- TUI may drift visually and architecturally by design.
- Prefer deleting or deepening a module over adding a pass-through seam.
- If a behavior needs a queue, name the owner, capacity, drain site, and full
  policy before implementing it.
- If a behavior can fail, fail before mutation or make the commit atomic.

## owner map

```text
cli
  parses args, resolves mode and resume selection, dispatches frontends

session_runtime.openSessionRuntime
  builds RuntimeServices, resolves session options (explicit -> project ->
  global -> default, provider/model scope-atomic), opens or resumes the
  session store, constructs the one AgentSession

RuntimeServices
  owns cwd-bound settings, paths, auth/model/provider owners

SessionRuntime
  the mailbox host: bounded command/event queues, sequenced envelopes,
  retained replay ledger, slash commands, and the active-operation phases
  (running | compacting | retry_wait)

AgentSession
  owns one session's policy spine: resources, system prompt, builtin tools,
  durable history, the long-lived agent, the public event drain, lifecycle,
  and the compaction/retry terminal policies (settle verdicts)

client_protocol
  owns the public command/event/snapshot vocabulary, ownership, and JSON shape

session_manager
  owns durable jsonl truth: entries, bounds, encoding, store, compaction
  projection

agent.Agent
  owns generic transcript loop, provider stream, tool execution, queued steering

ai
  owns provider protocol, model catalog, registry, wire adapters, streams
```

## ledger

| behavior | pi-mono reference | Zi owner | current status | proving test |
| --- | --- | --- | --- | --- |
| Shared session core across print, TUI, RPC, and tests | `packages/coding-agent/src/core/agent-session.ts` | `AgentSession` | implemented | `agent session initializes policy spine with definition-first builtin tools` |
| One owner for the live session and its mailbox | `core/agent-session-runtime.ts` | `SessionRuntime` | implemented; session *replacement* is deliberately unsupported — a new session is a new runtime, opened by the CLI | `session runtime owns services session and bounded mailboxes` |
| Prompt while running has explicit queue semantics | `PromptOptions.streamingBehavior` | `SessionRuntime` / `Submit.Mode` | implemented as command vocabulary (`auto`/`start`/`steer`/`enqueue`) instead of a required option | `session runtime queues prompt while active` |
| Steering/follow-up queues are observable before delivery | `_steeringMessages`, `_followUpMessages`, `queue_update` | `AgentSession` + queue mirror | implemented | `session runtime queues prompt while active`; `session runtime acknowledges queue clear with a correlated queue fact` |
| Queue snapshots expose text without copying full text into every event | `queue_update` plus queue arrays | `EventDrain` / `client_protocol.QueueSnapshot` | implemented | `session runtime request snapshot emits owned bounded snapshot event` |
| Public event drain is caller-driven | `subscribe()` over session events | `AgentSession` / `EventDrain` | implemented | `agent session persists message_end and exposes caller-drained events` |
| Event order is session policy before frontend policy | `AgentSession` event subscription/persistence path | `EventDrain` (mirror -> public -> persistence -> terminal policy) | implemented | `agent session terminal policy classifies context overflow after persistence`; `agent session terminal policy runs when persistence fails` |
| Session history is durable truth | `core/session-manager.ts` | `session_manager` | implemented for create/resume/listing/selection, durable compaction entries, torn-tail repair, and context projection; fork/import/export missing | `session store appends entries and round trips context`; `session store round trips compaction entries`; `context messages project latest compaction summary then kept messages`; `session store load repairs torn trailing line before future appends`; `loaded entries reject non linear parent links and foreign ids`; `session listing returns resumable leaf names newest first`; `session selection chooses newest only from complete listing`; `session selection rejects traversal and reports absent sessions`; `cli selects newest resumable session through runtime policy`; `cli selects explicit resumable session through runtime policy`; `cli reports absent resumable session` |
| Persistent message events are written before public drain | `AgentSession` subscription persistence | `EventDrain` | implemented | `agent session persists message_end and exposes caller-drained events` |
| Public event queue overflow is explicit | `AgentSessionEvent` listeners | `EventDrain` | implemented | `agent session public event queue overflow is explicit` |
| Cancellation intent remains observable until terminal event | abort/cancel flow | `SessionRuntime` / `AgentSession` | implemented, including cancel during retry backoff and cancel reaching a running process tool | `session runtime cancels targeted active operation`; `session runtime cancel during retry backoff settles operation as canceled`; `bash tool cancels running process through owner race` |
| Shutdown is request, drain, stopped, deinit | session dispose/shutdown | `AgentSession` / `SessionRuntime` | implemented | `agent session shutdown complete requires stopped idle and drained events`; `session runtime shutdown remains observable under event pressure` |
| Active tools are definition-first | `createAllToolDefinitions`, `wrapRegisteredTools` | `tool_registry.BuiltinTools` | implemented; the active set is the fixed builtin set — runtime set mutation returns when extension tools exist | `tool registry exposes builtin tools names and snippets in order` |
| Built-in read/bash/edit/write are definition-first and bounded | `core/tools/*` | `tools/*` | implemented | per-tool behavior tests in `tools/*.zig` |
| Model selection resolves explicit before settings | `model-resolver.ts` | `session_runtime.resolveSessionOptions` | implemented; **proving test missing** since the mailbox refactor | missing |
| Project settings beat global settings atomically | `settings-manager.ts`, `resolve-config-value.ts` | `session_runtime.resolveSessionOptions` | implemented (provider/model resolve as a scope-atomic pair); **proving test missing** since the mailbox refactor | `settings manager loads global and project default model settings` (loading only) |
| Auth lookup supports env and stored credentials | `auth-storage.ts`, `auth-guidance.ts` | `auth` / `RuntimeServices` | implemented | `auth manager returns configured env api key`; `auth store loads oauth credentials from global auth file` |
| Prompt resources load project/global context and system prompt | `resource-loader.ts`, `system-prompt.ts` | `resources` / `system_prompt` | implemented | `prompt resources load context and prompt overrides` |
| Skills are resource input to system prompt | `skills.ts` | `skills` / `system_prompt` | implemented | `skills are included only when read tool is selected` |
| Print JSON mode exposes the public event stream | `modes/print-mode.ts`, `modes/rpc/jsonl.ts` | `frontends/print` | implemented | `json print mode streams client protocol events` |
| RPC mode is sequenced jsonl over the same mailbox | `modes/rpc/*` | `frontends/rpc` | implemented | `rpc stdout is sequenced jsonl for malformed and valid commands`; `rpc submit command runs to completed operation`; `rpc replay command is terminal and returns retained facts` |
| TUI observes public session behavior only | interactive mode over `AgentSession` | `frontends/tui` adapter / `tui.App` | implemented: mailbox adapter with seq-gap replay and snapshot recovery; architecture gates in `docs/mailbox-contract.md` | build/test compile boundary; gates |
| Agent terminal events are facts, not snapshots | `AgentSessionEvent` lifecycle events | `agent.AgentEvent` / retained ledger | implemented | `retained ledger terminal agent events do not carry message payloads` |
| Tool result display and model context are separate bounded projections | pi tool output accumulator + session context transformation | `agent.defaultConvertToLlm`, `tool_output_policy` | implemented | `default llm conversion bounds tool result text` (src/agent) |
| Auto compaction events and policy | `core/compaction/*` | `AgentSession` settle verdicts + `SessionRuntime` phases | implemented: threshold compaction as the operation's opening phase, overflow compaction with one bounded resubmit retry, durable entry before in-memory commit | `agent session auto compaction summarizes persists and replaces context`; `overflow settle starts compaction and arms the resubmit retry`; `session runtime runs threshold compaction as the operation's opening phase`; `agent session auto compaction failure does not mutate history`; `compaction summary input keeps bounded recent suffix`; `serialize compaction summary input truncates tool results and bounds output` |
| Manual compaction | `AgentSession.compact()` | future `SessionRuntime` command | **missing at the public boundary**: the pre-mailbox host API had it; the mailbox protocol has no `compact` command. The session-side machinery (`startCompactionRun`/settle) exists and is exercised by auto compaction | missing |
| Auto retry events and policy | `auto_retry_start/end` in `AgentSession` | `AgentSession` settle verdicts + `SessionRuntime.retry_wait` | implemented: bounded transient-error continue retry with exponential backoff (capped), owner-driven waiting, cancel during backoff | `settle verdict arms backoff retry and repairs the runtime transcript`; `settle verdict fails after exhausted attempts with terminal retry end`; `session runtime retries transient failure through the live owner loop`; `drain settles in-flight retry on successful assistant message` |
| Bash/process tool with timeout/cancel | `core/bash-executor.ts`, `tools/bash.ts` | `tools/bash` | implemented over the zio process runner: cwd-bound, env passthrough, timeout/cancel/output-limit as result data; no stdin/PTY/background/streaming | `bash tool runs one cwd-bound command`; `bash tool treats timeout as bounded result data`; `bash tool treats output limit as bounded result data`; `bash tool cancels running process through owner race` |
| Slash commands | `slash-commands.ts` | `SessionRuntime` | implemented first slice (restored 2026-06-13 after being dropped in the mailbox refactor): `/help` and `/session` reply with request-correlated `prompt_command` events; unknown commands reply `unknown`; never reaches the model or queues, active operation or not | `session runtime handles slash command without starting an operation`; `session runtime session command reports session facts`; `session runtime replies unknown for unrecognized slash command`; `session runtime slash command never queues while an operation is active`; `prompt command event serializes public shape` |
| Prompt templates | `prompt-templates.ts` | future | missing; keep separate from slash dispatch | missing |
| Session fork/import/export HTML | `agent-session-runtime.ts`, `export-html/*` | future `session_manager` | missing | missing |
| Extension hooks | `core/extensions/*` | future explicit extension owner | deferred | missing |

## next slices

Work down this list. Do not add a framework to satisfy a row.

1. Re-pin settings precedence. `resolveSessionOptions` implements
   explicit -> project -> global -> default with a scope-atomic
   provider/model pair, but no test proves it through `openSessionRuntime`
   since the mailbox refactor. Two focused tests, no new machinery.

2. Manual compaction as a mailbox command. The session machinery exists;
   add a `compact` client command whose operation runs the compacting phase
   without the resubmit retry, plus rejection while an operation is active.

3. Harden the bounded process tool. Keep stdin, PTY, background jobs, and
   streaming out until each has an owner, bound, and drain site.

4. Frontend affordances after behavior. A public command catalog only when a
   frontend needs autocomplete; prompt templates separate from slash dispatch.

## non-goals

- Do not copy pi-mono's interactive widget model.
- Do not add a generic extension runtime before one concrete extension behavior
  has an owner, capacity, and failure policy.
- Do not let `main.zig`, print mode, TUI mode, or RPC own session policy.
- Do not make provider adapters know about retry, compaction, persistence, TUI,
  or tools.
- Do not reintroduce session replacement inside a live runtime; opening a new
  session is the supported path.
