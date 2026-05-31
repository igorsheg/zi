# behavioral parity with pi-mono

Zi preserves pi-mono behavior at the `coding_agent` boundary. Zi does not
preserve pi-mono's TUI architecture.

This file is the parity ledger. A row is complete only when the behavior has a
Zi owner, a pi-mono reference, and a test that proves the behavior through the
public coding-agent boundary.

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
sdk
  creates RuntimeServices before AgentSessionRuntimeHost

RuntimeServices
  owns cwd-bound settings, paths, auth/model/provider owners

session_config
  resolves explicit options plus RuntimeServices into host base options

AgentSessionRuntimeHost
  owns current AgentSession and replacement

AgentSession
  owns session policy, preflight, public events, persistence, resources, tools

agent.Agent
  owns generic transcript loop, provider stream, tool execution, queued steering

ai
  owns provider protocol, model catalog, registry, wire adapters, streams
```

## ledger

| behavior | pi-mono reference | Zi owner | current status | proving test |
| --- | --- | --- | --- | --- |
| Shared session core across print, TUI, RPC, and tests | `packages/coding-agent/src/core/agent-session.ts` | `AgentSession` | implemented | `agent session initializes policy spine with definition-first builtin tools` |
| Runtime host owns current session replacement | `core/agent-session-runtime.ts` | `AgentSessionRuntimeHost` | implemented | `runtime host replacement invalidates old session before rebinding new session` |
| Replacement only when old session is idle/stopped | `core/agent-session-runtime.ts` | `AgentSessionRuntimeHost` | implemented | `runtime host replacement rejects active old session` |
| Prompt path runs preflight before agent submission | `AgentSession.prompt()` | `AgentSession` | implemented | `agent session prompt uses preflight spine before agent submission` |
| Prompt while running requires explicit queue behavior | `PromptOptions.streamingBehavior` | `AgentSession` | implemented | `agent session prompt requires streaming behavior while running` |
| Follow-up queue is observable before delivery | `_followUpMessages`, `queue_update` | `AgentSession` | implemented | `agent session prompt queues follow up while running` |
| Steering queue is observable before delivery | `_steeringMessages`, `queue_update` | `AgentSession` | implemented | `agent session prompt queues steering while running` |
| Queue snapshots expose text without copying full text into every event | `queue_update` plus queue arrays | `AgentSession` | implemented | `agent session queue update carries revision and snapshot exposes queued text` |
| Public event drain is caller-driven | `subscribe()` over session events | `AgentSession` | implemented | `agent session public event drain is caller driven` |
| Event order is session policy before frontend policy | `AgentSession` event subscription/persistence path | `AgentSession` | implemented | `agent session terminal policy runs after persistence` |
| Session history is durable truth | `core/session-manager.ts` | `SessionManager` / `session_store` | implemented for new SDK sessions and explicit resume; fork/import/export missing | `session store appends entries and round trips context`; `runtime host preserves session header active leaf and context after public drain`; `runtime host persists session store that loads after host deinit`; `runtime host resumes session store into agent context and appends new history`; `sdk runtime creates session store under service session path`; `sdk runtime resumes existing session store from service session path` |
| Persistent message events are written before public drain | `AgentSession` subscription persistence | `AgentSession` | implemented | `agent session persists message_end through session event drain` |
| Public event queue overflow is explicit | `AgentSessionEvent` listeners | `AgentSession` | implemented | `agent session public event queue overflow is explicit` |
| Cancellation intent remains observable until terminal event | abort/cancel flow | `AgentSession` | implemented | `agent session cancel while running is observable until terminal event` |
| Shutdown is request, drain, stopped, deinit | session dispose/shutdown | `AgentSession` | implemented | `agent session shutdown complete requires stopped idle and drained events` |
| Active tools are definition-first | `createAllToolDefinitions`, `wrapRegisteredTools` | `ToolRegistry` / `AgentSession` | implemented | `tool registry stores definitions first and exposes active agent tools` |
| Tool active set changes validate before mutation | tool registry active names | `ToolRegistry` | implemented | `tool registry rejects duplicate and unknown tool names without changing active set` |
| Built-in read/ls/grep/find/write/edit are definition-first and bounded | `core/tools/*` | `tools/*` | implemented | `tool registry stores definitions first and exposes active agent tools`; per-tool behavior tests |
| Model selection resolves explicit before settings | `model-resolver.ts` | `session_config` | implemented | `session config uses explicit model thinking and stream before settings` |
| Project settings beat global settings atomically | `settings-manager.ts`, `resolve-config-value.ts` | `session_config` | implemented | `session config keeps provider and model settings scope atomic` |
| Auth lookup supports env and stored credentials | `auth-storage.ts`, `auth-guidance.ts` | `auth` / `RuntimeServices` | implemented | `auth manager returns configured env api key`; `auth store loads oauth credentials from global auth file` |
| Prompt resources load project/global context and system prompt | `resource-loader.ts`, `system-prompt.ts` | `resources` / `system_prompt` | implemented | `prompt resources load context and prompt overrides` |
| Skills are resource input to system prompt | `skills.ts` | `skills` / `system_prompt` | implemented | `skills are included only when read tool is selected` |
| Print JSON mode exposes session header and public event stream | `modes/print-mode.ts`, `modes/rpc/jsonl.ts` | `print_mode` | implemented | `json print mode streams session header and public events` |
| TUI observes public session behavior only | interactive mode over `AgentSession` | `tui_mode` / `tui.App` | partial | build/test compile boundary; needs behavior test after TUI settles |
| Auto compaction events and policy | `core/compaction/*` | `AgentSession` future terminal policy | protocol only | missing |
| Manual compaction | `AgentSession.compact()` | `AgentSession` future terminal policy | missing | missing |
| Auto retry events and policy | `auto_retry_start/end` in `AgentSession` | `AgentSession` future terminal policy | protocol only | missing |
| Bash/process tool with timeout/cancel | `core/bash-executor.ts`, `tools/bash.ts` | `tools/BashTool` / `AgentSession` | minimal implemented: cwd-bound, sequential, no stdin/env/PTY/background/streaming | `bash tool runs one cwd-bound command`; `bash tool treats nonzero exit as result data`; `bash tool cancels running process through owner race`; `runtime host preserves bash output limit details through public events` |
| Find/grep/ls tools | `core/tools/find.ts`, `grep.ts`, `ls.ts` | `tools/*` | implemented | `find tool recursively filters paths`; `grep tool searches directory files with literal pattern`; `ls tool lists one directory with bounds` |
| Slash commands and prompt templates | `slash-commands.ts`, `prompt-templates.ts` | future frontend/session command owner | missing | missing |
| Session fork/resume/import/export HTML | `agent-session-runtime.ts`, `export-html/*` | future host/session manager | missing | missing |
| Extension hooks | `core/extensions/*` | future explicit extension owner | deferred | missing |

## next slices

Work down this list. Do not add a framework to satisfy a row.

1. Harden durable session truth.
   - Add listing/selection policy for resumable session files.
   - Keep fork/import/export separate from resume.
   - Keep frontend event drains observational; they must not alter persisted
     history, active leaf, or session header.

2. Harden the bounded process tool.
   - Add session/agent-loop behavior coverage for cancellation.
   - Keep stdin, env overrides, PTY, background jobs, and streaming out until
     each has an owner, bound, and drain site.

3. Add retry and compaction as terminal session policies.
   - Events already exist; behavior does not.
   - Keep provider protocol free of retry/compaction policy.

4. Reintroduce frontend affordances only after session behavior exists.
   - Slash commands and prompt templates are command/session behavior first.
   - TUI display follows public events after the behavior is stable.

## non-goals

- Do not copy pi-mono's interactive widget model.
- Do not add a generic extension runtime before one concrete extension behavior
  has an owner, capacity, and failure policy.
- Do not let `main.zig`, print mode, TUI mode, or future RPC own session policy.
- Do not make provider adapters know about retry, compaction, persistence, TUI,
  or tools.
