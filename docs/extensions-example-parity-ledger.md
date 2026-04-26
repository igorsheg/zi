# extension example parity ledger

## status

work item: `zi-rep0.1`.

this ledger is the product-level companion to `zi-fex`.

`zi-fex` defined the v2 extension architecture and contracts. this file tracks whether zi can express the same product capabilities demonstrated by pi-mono's extension examples in `.references/pi-mono/packages/coding-agent/examples/extensions/`.

## source of truth

pi-mono's examples readme groups the target product surface into lifecycle/safety, custom tools, commands/ui, git integration, system prompt/compaction, resources, messages, session metadata, providers, and dependency-bearing extensions (`.references/pi-mono/packages/coding-agent/examples/extensions/README.md:17-130`). the top-level examples readme says extension examples cover lifecycle handlers, custom tools, commands/shortcuts, custom ui, git integration, prompt/compaction, external integrations, and custom providers (`.references/pi-mono/packages/coding-agent/examples/README.md:10-19`).

zi's v2 docs intentionally keep the architecture different:

- extensions execute on the agent-owned lua runtime; the tui renders host-owned state and does not call lua directly (`docs/extensions.md:20-24`).
- raw `custom()` component trees, raw editor replacement, and raw terminal input listeners are excluded across the lua boundary (`docs/extensions-ui-contract.md:90-92`).
- advanced ui remains possible only through host-owned surfaces, renderer refs, retained handles, or semantic records (`docs/extensions-ui-contract.md:81-89`).
- subagent/job observer classes are called out as incomplete (`docs/extensions-jobs-subagents.md:267-290`).

## status labels

| label | meaning |
| --- | --- |
| shipped | current zi code exposes enough api to build the example class now. |
| partial | core pieces exist, but product parity needs missing events, ui, persistence, rendering, or tests. |
| blocked | an existing open bead or missing architecture seam must land first. |
| product-equivalent needed | pi-mono uses a raw host object seam that zi deliberately excludes; zi needs a native retained/semantic equivalent. |
| deliberate non-goal | zi should not reproduce the pi-mono seam, and no product-equivalent is required. |

## current implementation baseline

`src/coding_agent/extensions/api.zig` installs the current lua `zi` table with:

- `register_tool`
- `register_command`
- `register_provider`
- `unregister_provider`
- `on`
- `spawn`

source: `src/coding_agent/extensions/api.zig:68-102`.

current event registry tags cover lifecycle, tool, session start/shutdown/switch/fork, and model select (`src/coding_agent/extensions/registries/event_registry.zig:30-55`). the v2 events doc defines a wider target including resource discovery, input/context/provider transforms, user bash, compaction, and tree hooks (`docs/extensions-events.md:128-142`).

## open bead anchors

| bead | why it matters |
| --- | --- |
| `zi-gxr` | closed: ExtensionRunner generation swap substrate is implemented; treat reload/rebind as available foundation, not an open blocker. |
| `zi-xb8` | closed: event registry and `zi.on` parser reserve all 28 v2 events. |
| `zi-c7v` | provider queue seam for custom providers. |
| `zi-bbq` | flag registry for `register_flag` product parity. |
| `zi-rep0.4` | closed: first host-owned command output panel primitive (`ctx.ui.show_panel`) for `/todos`-class commands. |
| `zi-rep0.5` | closed: prompt family request boundary (`ctx.ui.confirm/select/input/editor`) with host-owned records and default unbind cancellation. |
| `zi-rep0.6` | closed: retained status/title/working/thinking/widget/header/footer surface lease intents with TUI snapshot consumption for status/header/footer/widgets. |
| `zi-rep0.7` | closed: editor buffer action records (`set_editor_text`, `paste_to_editor`, `clear_editor_text`, `get_editor_text`) plus editor-modal prompt request from `zi-rep0.5`. |
| `zi-rep0.8` | closed: advanced overlay surface lease intent via `ctx.ui.show_overlay`, retained as host-owned semantic payload without raw components/input listeners. |
| `zi-rep0.9` | closed: interactive confirm/select/input/editor prompt materialization and response path through host-owned TUI overlays. |
| `zi-rep0.10` | closed: text input and editor prompt materialization via TUI-owned editor overlays; lua receives only semantic string/nil results. |
| `zi-0j8` | message renderer registry / custom transcript presentation. |
| `zi-30e` | editor component seam; likely needs a zi-native product-equivalent, not raw component replacement. |
| `zi-9qt` | editor interface parity needed by editor-modal and editor-buffer actions. |
| `zi-v3j.10` | compaction subsystem; extension compaction hooks depend on it becoming first-class. |

## capability ledger

| pi-mono example(s) | product capability | zi status | target zi product surface | blocker / next bead |
| --- | --- | --- | --- | --- |
| `hello.ts` | minimal custom tool | shipped | `examples/extensions/hello.lua` registers a minimal `greet` tool with schema and Lua execution, covered by a load-and-execute boundary test | closed in `zi-g40k`. |
| `todo.ts` | custom tool + command + persisted state + custom rendering + command output UI | shipped | `examples/extensions/todo.lua` ships tool, command registration, branch-replayed `ctx.state` persistence, tool-result details, `render_result`, and `/todos` host-owned command panel output via `ctx.ui.show_panel` | closed in `zi-rep0.4`. |
| `tool-override.ts` | override builtin tools while preserving behavior/rendering where desired | shipped | `examples/extensions/tool_override.lua` overrides `read`; first-claimant registry keeps the extension definition when builtin `read` arrives later, and same-name builtin renderer fallback remains available when no `render_result` is supplied | closed in `zi-us3x`. |
| `built-in-tool-renderer.ts`, `minimal-mode.ts` | override builtin tool rendering | partial | `render_call` and `render_result` are the first tool presentation-slot verticals: Lua returns host-owned line/span presentation documents, custom renderers win over fallback, failing hooks fail open, and empty collapsed result output supports minimal-mode semantics; `examples/extensions/minimal_mode.lua` demonstrates a builtin-name `read` override with custom call/result presentation | remaining `zi-0j8`: explicit reusable renderer refs and broader message-renderer registry. |
| `truncated-tool.ts` | custom tool with output truncation policy | shipped | `examples/extensions/truncated_rg.lua` demonstrates a custom rg-like tool that bounds output by lines/bytes, returns truncation metadata and an optional full-output temp path, and uses `render_call`/`render_result` for compact/expanded host-owned presentation | closed in `zi-ej2x`. |
| `dynamic-tools.ts` | register tools during lifecycle/runtime | shipped | `examples/extensions/dynamic_tools.lua` registers `echo_session` from `session_start` and more echo tools from `/add-echo-tool`; accepted runtime registrations update the generation-owned registry and refresh the session's visible tool list + prompt metadata, while duplicate claims keep first-claimant semantics and fail open | closed in dynamic runtime registration slice. |
| `antigravity-image-gen.ts` | external integration tool with files/images | partial | tool execution + image/file result semantics | depends on image/result rendering parity; likely after tool renderer slice. |
| `ssh.ts` | delegate tool operations to remote host | partial | tool override + subprocess/system substrate + policy hooks | after `zi.system`/job substrate decision. |
| `subagent/` | first-class delegated child agents | blocked | retained subagent/job scheduler, progress, observer events, default transcript rendering | define/implement `subagent_*` / `job_*` events; docs mark this open (`docs/extensions-jobs-subagents.md:267-290`). |
| `permission-gate.ts`, `protected-paths.ts` | block or modify tool calls | partial | `tool_call` middleware/cancellable + host-owned ui confirm/select request records | complete event dispatch coverage + interactive prompt materialization. |
| `confirm-destructive.ts`, `dirty-repo-guard.ts` | veto session switch/fork/new operations | partial | `session_before_switch`, `session_before_fork`, future compact/tree gates + host-owned ui prompt requests | complete event dispatch, interactive prompt materialization, and command/session-control context. |
| `sandbox/` | OS-level sandbox wrapping tool execution | blocked | tool-call/user-bash interception plus process sandbox substrate | requires `user_bash` event and system/job substrate. |
| `commands.ts` | slash command registration | shipped | `examples/extensions/commands.lua` registers `/hello`, dispatches on the agent-owned command path, and publishes host-owned panel output through `ctx.ui.show_panel` | closed in `zi-ovmg`. |
| `preset.ts` | command + flag + runtime model/tools/thinking changes | blocked | command registry, flag registry, host actions (`set_model`, tool policy, thinking level) | `zi-bbq`; host action coverage. |
| `plan-mode/` | command-driven mode with tool restrictions and progress ui | blocked | commands + retained mode state + status/widgets + tool policy | after commands, flags, widgets, and tool-policy hooks. |
| `tools.ts` | interactive command for enabled/disabled tools with persistence | partial | command + select prompt request + persisted workspace/session state + tool policy | tool policy. |
| `handoff.ts` | command + custom loader ui + editor prompt + session handoff | partial | command + working surface + editor modal request + editor buffer action + handoff host action | handoff action. |
| `qna.ts` | prompt-generator command: extract questions from last assistant message, run model completion, show working/notification UI, then mutate editor buffer | partial | `examples/extensions/qna.lua` is only a seed that proves command-driven editor mutation through host-owned `ctx.ui.set_editor_text`; full qna parity needs semantic branch/message reads, extension-initiated model completion without exposing raw provider auth, notification/working UI, and async/cancellable command execution | `zi-2wn2` closed only the editor-action sub-capability; create a full qna bead after those seams exist. |
| `status-line.ts`, `model-status.ts` | footer/status items from events | partial | keyed status items in retained ui state via `ctx.ui.set_status` | event-time snapshot flushing and richer styling. |
| `widget-placement.ts` | widgets above/below editor | shipped | `examples/extensions/widget_placement.lua` handles `session_start` and publishes above/below editor widgets through host-owned `ctx.ui.set_widget` surface updates with placement metadata | closed in `zi-0scq`; richer arbitration/styling remains future scope. |
| `hidden-thinking-label.ts` | customize collapsed thinking label | partial | singleton thinking-label surface intent | materialization in thinking-block renderer. |
| `custom-header.ts` | claim/restore header | shipped | `examples/extensions/custom_header.lua` claims the header on `session_start` with host-owned `ctx.ui.set_header` line/span payloads and registers `/builtin-header` to restore the built-in header surface | closed in `zi-uo7u`; raw component factories remain deliberately excluded. |
| `custom-footer.ts` | claim footer with dynamic branch/model/token data | partial | footer `surface_lease` intents via `ctx.ui.set_footer`; full parity also needs semantic footer data helpers or renderer refs for git branch/status/token/model data | richer renderer refs, footer data helpers, and conflict arbitration. |
| `summarize.ts` | command/event producing transient ui output | blocked | command + retained panel/widget/notification + model/tool access | ui surfaces + context usage/model helpers. |
| `send-user-message.ts` | send/steer/follow-up user messages from extensions | blocked | host action for idle send, steering, and queued follow-up | command actions across request boundary. |
| `shutdown-command.ts`, `reload-runtime.ts` | command-triggered shutdown/reload | partial | command-only `ExtensionCommandContext` actions | command action tests on top of closed `zi-gxr`. |
| `notify.ts`, `titlebar-spinner.ts` | terminal/desktop notification and title changes | blocked | notification and title surfaces | retained notification/title api; terminal-specific materialization optional. |
| `timed-confirm.ts` | abortable confirm/select ui | partial | prompt request records with cancellation/default resolution | timeout/abort semantics. |
| `rpc-demo.ts` | exercise extension ui via rpc host | blocked | same retained ui primitives over non-tui host | rpc-host materialization for retained ui primitives. |
| `question.ts`, `questionnaire.ts` | interactive tool asks user for input/selection | partial | prompt/select/input/editor request records callable from lua tool/event contexts | runnable example parity and rpc-host materialization; raw custom ui excluded. |
| `overlay-test.ts`, `overlay-qa-tests.ts`, `doom-overlay/`, `snake.ts`, `space-invaders.ts` | advanced custom overlays / games / keyboard-driven ui | partial | retained overlay surface intent via `ctx.ui.show_overlay`; future renderer refs/focus leases/input intents stay host-owned | richer overlay materialization, renderer refs, and constrained host-owned input intents. |
| `modal-editor.ts`, `rainbow-editor.ts` | replace editor component | product-equivalent needed | editor modal, editor buffer actions, maybe constrained editor decoration surface | raw component replacement excluded (`docs/extensions-ui-contract.md:91`). |
| `pirate.ts`, `system-prompt-header.ts`, `claude-rules.ts` | system prompt modification from extension | partial | `before_agent_start` aggregate system-prompt/message contribution | complete event dispatch and resource/path helpers. |
| `input-transform.ts`, `inline-bash.ts` | transform submitted input | blocked | `input` middleware/cancellable event | `zi-xb8` + dispatch wiring. |
| `provider-payload.ts` | inspect/modify provider payload | blocked | `before_provider_request` middleware over semantic payload | `zi-xb8` + provider request seam. |
| `custom-compaction.ts`, `trigger-compact.ts` | customize or trigger compaction | blocked | `session_before_compact`, `session_compact`, command action `compact` | `zi-v3j.10`. |
| `git-checkpoint.ts`, `auto-commit-on-exit.ts` | git lifecycle integration | partial | lifecycle/session events + `zi.system`/exec helper + ui prompts | event coverage + system substrate. |
| `mac-system-theme.ts` | external watcher updates theme | blocked | file/process watcher or job + theme host action | resources/theme action design needed. |
| `dynamic-resources/` | add skills/prompts/themes dynamically | blocked | `resources_discover` aggregate returns runtime root descriptors | `zi-xb8` + resource loader integration. |
| `message-renderer.ts` | custom message rendering | blocked | message renderer registry / transcript attachment renderer refs | `zi-0j8`. |
| `event-bus.ts` | inter-extension communication | blocked | generation-local event bus or extension namespace pub/sub | no current public api; design after generation model. |
| `session-name.ts`, `bookmark.ts` | session metadata and labels | blocked | session metadata actions: set/get session name, label entries | session action api + persistence. |
| `custom-provider-anthropic/`, `custom-provider-gitlab-duo/`, `custom-provider-qwen-cli/` | custom providers, oauth, models | partial | `zi.register_provider`, `zi.unregister_provider`, provider claims, oauth callbacks, model projection | `zi-c7v`, generation model, provider lifecycle tests. |
| `file-trigger.ts` | file watcher injects prompt/message | blocked | job/watch substrate + send/follow-up host action | job substrate + send user message action. |
| `bash-spawn-hook.ts`, `interactive-shell.ts` | user bash hook / interactive process takeover | blocked | `user_bash` interceptor + host-owned terminal process handoff | `zi-xb8`; decide what interactive terminal ownership means. |
| `with-deps/` | extension with package/dependencies | blocked | package/resource root resolution for lua modules or chosen package format | package seam design; not solved by current lua runtime alone. |

## recommended implementation order

1. **foundation:** generation/reload (`zi-gxr`) and all-event reservation (`zi-xb8`) are closed; next foundation gaps are provider queue (`zi-c7v`) and flag registry (`zi-bbq`) when their vertical slices need them.
2. **first vertical slice:** `todo.ts` parity is closed by `zi-rep0.4`: `examples/extensions/todo.lua` uses host-owned command panel output on top of the shipped tool, renderer, and branch-replayed `ctx.state` persistence.
3. **tool surface:** `tool-override.ts`, truncated custom output, and the first tool call/result presentation-slot verticals are shipped; remaining work is explicit renderer refs and broader builtin/message renderer registry semantics.
4. **command/config surface:** finish commands, flags, shortcuts, command actions, and editor-buffer actions.
5. **event/interceptor surface:** ship `input`, `context`, `before_provider_request`, `resources_discover`, `user_bash`, session gates, and compaction/tree hooks.
6. **retained ui primitives:** prompts, notifications, status, widgets, header/footer, title, editor modal, and overlays as host-owned records.
7. **providers:** prove provider registration, oauth, model projection, reload/rebind, and unregister/claim restoration.
8. **jobs/subagents:** replace today's `zi.spawn`-centric model with first-class retained jobs/subagents and observer events.
9. **advanced ui/editor parity:** decide constrained retained overlay/editor extension points for games and modal editors, or mark specific raw seams as deliberate non-goals with product alternatives.
10. **example suite:** every shipped class gets a runnable zi example and 2-4 boundary tests per slice.

## first slice acceptance

for the first vertical slice, do not start with overlays or providers. start with a `todo`-class extension because it exercises many common seams without forcing raw tui reach-through:

- custom tool registration and execution
- slash command registration and dispatch
- session/workspace state persistence
- transcript/tool presentation
- resume/reload behavior under generation ownership

current status: `examples/extensions/todo.lua` covers the runnable tool/command/details/render-result core, branch-replayed `ctx.state` persistence, and host-owned `/todos` command panel output with boundary coverage.
