# extension events and interceptors

## status

contract for `zi-fex.4`.
it follows [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), [extensions-lifecycle.md](./extensions-lifecycle.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

## decision

- observer events and interceptors are separate public classes.
  they do not share one vague "event" bucket.
- observer classes are additive and post-fact.
  they observe committed product semantics.
- interceptor classes are pre-commit seams.
  each one declares its composition family directly: `middleware`, `cancellable`, `aggregate`, or an explicit combination.
- `session_compact` and `session_tree` stay.
  their `session_before_*` partners are the interception seams; the post events remain observer-only publication.
- public payloads are semantic extension contracts.
  they are not aliases of `AgentRequest`, `UiEvent`, snapshots, raw `AgentEvent`, or other owner-boundary/runtime-internal transport.
- parity target: match pi-mono's extension-visible class set and the field meaning/order that product behavior depends on.
  where zi v2 must diverge, do it explicitly and in service of the runtime-root and ownership contracts.

## model

```text
user action / session op / provider op
                │
                v
      +-------------------------+
      |     interceptor seam    |
      |  may transform/cancel   |
      |  or contribute results  |
      +-------------------------+
                │
                v
      +-------------------------+
      | host commits semantics  |
      | session swap, tool run, |
      | provider request, etc.  |
      +-------------------------+
                │
                v
      +-------------------------+
      |     observer seam       |
      | additive publication    |
      | cannot rewrite history  |
      +-------------------------+
```

## shared payload doctrine

all public payloads are semantic, product-grade objects.

the contract therefore uses these rules:

- every payload has a stable event `type`.
- payloads may embed semantic objects such as `message`, `tool_call`, `tool_result`, `model`, `session_entry`, or `runtime_root_descriptor`.
  those are public extension types, not borrowed internal structs.
- ids and timestamps are part of the public contract when consumers need them to correlate lifecycle edges.
  do not ship empty placeholder payloads just because an internal source event happened to be empty upstream.
- transport and owner-boundary shapes stay private.
  `AgentRequest`, `UiEvent`, published snapshots, mailbox wake details, and similar runtime machinery do not become extension payloads.
- low-level agent/provider structs may be implementation inputs, but the public extension payload is defined here.
  the host may translate from an internal source shape into the extension contract.

## composition families

### observe-only

- handler return values are ignored.
- all handlers run in precedence order.
- observers publish what already happened; they do not block or rewrite it.

### middleware

- the handler sees the current semantic payload.
- it may return a replacement payload of the same event-specific family.
- the replacement becomes the input to the next handler and to the host action if the chain completes.
- no replacement means identity.

### cancellable

- the handler may return `cancel = true` plus an optional reason.
- first cancellation wins.
- once cancelled, lower-precedence handlers do not run and the host action does not commit.

### aggregate

- handlers contribute event-specific partial results.
- the host reduces them with an explicit reducer for that event.
- reducers are part of the contract; no ad hoc "whatever the loop did" behavior.

## observer classes

these are the public observer classes for v2.

| class | payload core | notes |
| --- | --- | --- |
| `session_start` | `reason`, `binding`, `previous?`, `fork_parent_entry_id?` | first session-visible observer after bind; binding ids follow the rebinding contract |
| `session_shutdown` | `reason`, `binding`, `next?`, `fork_parent_entry_id?` | last session-visible observer before unbind; binding ids follow the rebinding contract |
| `agent_start` | run metadata | first run observer |
| `agent_end` | run metadata, `messages` | last run observer |
| `turn_start` | `turn_index`, timestamp | one assistant turn begins |
| `turn_end` | `turn_index`, timestamp, `message`, `tool_results` | one assistant turn settles |
| `message_start` | `message` | emitted for user, assistant, and tool-result messages |
| `message_update` | `message`, `assistant_message_event` | assistant streaming deltas only |
| `message_end` | `message` | final publication for that message |
| `tool_execution_start` | `tool_call_id`, `tool_name`, `args` | fires before tool-call interception outcome is known |
| `tool_execution_update` | `tool_call_id`, `tool_name`, `args`, `partial_result` | zero or more partial updates |
| `tool_execution_end` | `tool_call_id`, `tool_name`, `result`, `is_error` | final tool execution outcome |
| `model_select` | `model`, `previous_model?`, `source` | emitted for explicit set, cycling, and restore |
| `session_compact` | `compaction_entry`, `from_extension` | survives as the post-compaction observer |
| `session_tree` | `new_leaf_id?`, `old_leaf_id?`, `summary_entry?`, `from_extension?` | survives as the post-tree-navigation observer |

### why `session_compact` and `session_tree` survive

zi needs both the pre and post edges:

- `session_before_compact` and `session_before_tree` are where veto/customization happen.
- `session_compact` and `session_tree` are where other extensions can observe the committed session mutation.

without the post events, one extension could customize a session operation but another extension could not reliably react to the fact that the operation actually committed.

## interceptor classes

these are the public interceptor classes for v2.

| class | family | payload core | reducer / result contract |
| --- | --- | --- | --- |
| `session_directory` | aggregate | `cwd` | contributes `session_directory?`; first explicit claim wins; startup-only; no session-bound ctx |
| `resources_discover` | aggregate | `cwd`, `reason` | contributes ordered `runtime_root_descriptor[]`; appended in handler order; affects non-extension resource discovery only |
| `before_agent_start` | aggregate | `prompt`, `images?`, `system_prompt` | contributes `messages[]` and/or `system_prompt`; injected messages append in handler order; system-prompt replacements chain in handler order |
| `input` | middleware + cancellable | `text`, `images?`, `source` | may continue, replace input, or mark handled and short-circuit default prompt handling |
| `context` | middleware | `messages[]` | may replace the message list used for the next provider call |
| `before_provider_request` | middleware | provider/model metadata plus semantic request payload | may replace the request payload sent to the provider |
| `tool_call` | middleware + cancellable | `tool_call_id`, `tool_name`, `input` | may replace tool input and/or cancel before execution; replacement is the input seen by later handlers and by execution |
| `tool_result` | middleware | `tool_call_id`, `tool_name`, `input`, `content`, `details`, `is_error` | may replace `content`, `details`, and `is_error` before the final tool-result message is committed |
| `user_bash` | cancellable + aggregate | `command`, `exclude_from_context`, `cwd` | may claim execution with a concrete result; otherwise may supply execution operations; first concrete claim wins |
| `session_before_switch` | cancellable | `reason`, `target_session_file?` | may cancel session replacement |
| `session_before_fork` | cancellable + aggregate | `entry_id` | may cancel; `skip_conversation_restore` uses first explicit value |
| `session_before_compact` | cancellable + aggregate | `preparation`, `branch_entries`, `custom_instructions?` | may cancel; a supplied concrete `compaction` result wins and skips host compaction work |
| `session_before_tree` | cancellable + aggregate | `preparation` | may cancel; `summary`, `custom_instructions`, `replace_instructions`, and `label` each use first explicit value |

## ordering guarantees

these are product-significant.

### precedence order

for both observers and interceptors, handler order is the canonical extension precedence order for the bound generation.
it comes from runtime-root discovery and bind order, not ad hoc registration timing.

put differently:

```text
canonical root order
  -> extension discovery order
  -> namespace bind order
  -> handler order inside each event class
```

within one extension, handlers for the same class run in registration order.

### session lifecycle order

the lifecycle guarantees from [extensions-lifecycle.md](./extensions-lifecycle.md) stay authoritative.

extension-visible consequences:

```text
bind
  -> session_start
  -> resources_discover
  -> steady-state work
  -> session_shutdown
  -> unbind
```

rules:

- `session_start` is the first session-visible event for a bound generation.
- `resources_discover` runs after `session_start`.
  it may contribute more runtime roots for `lua/`, `prompts/`, `skills/`, `themes/`, and `agents/`, but not `extensions/` for the current generation.
- `session_shutdown` is the last session-visible event for a bound generation.
- no session-visible callback runs after unbind starts.

### session replacement order

for `/new` and `/resume`:

```text
session_before_switch
  -> session_shutdown
  -> unbind old generation
  -> teardown old generation
  -> discover/load/bind replacement generation
  -> session_start
  -> resources_discover
```

for `/fork`:

```text
session_before_fork
  -> session_shutdown
  -> unbind old generation
  -> teardown old generation
  -> discover/load/bind replacement generation
  -> session_start
  -> resources_discover
```

### compaction and tree order

these are split into pre and post edges on purpose:

```text
session_before_compact  -> host compaction commit -> session_compact
session_before_tree     -> host tree commit       -> session_tree
```

if the pre event cancels, the post event does not fire.

### run / turn order

for a normal prompt submission:

```text
input
  -> before_agent_start
  -> agent_start
  -> turn_start
  -> prompt message_start/message_end
  -> repeat per assistant turn:
       context
       -> before_provider_request
       -> assistant message_start
       -> message_update*
       -> assistant message_end
       -> tool_execution_start*
       -> tool_call
       -> tool_execution_update*
       -> tool_result
       -> tool_execution_end*
       -> tool-result message_start/message_end*
       -> turn_end
  -> agent_end
```

notes:

- `message_update*` and `tool_execution_update*` are zero-or-more.
- `tool_execution_start` fires before `tool_call` settles.
  blocked tool calls still produce a balanced execution end.
- `tool_result` is the last rewrite seam for tool output before `tool_execution_end` and the final tool-result message publication.
- `agent_end` is the last run event.
  the run does not become idle before that event chain settles.

## asymmetries worth keeping from pi-mono

zi v2 keeps these asymmetries on purpose:

- `session_shutdown` carries a `reason`.
  zi's lifecycle doc already makes shutdown reason product-significant for reload, new, resume, and fork; the public event should expose that instead of collapsing distinct flows into one empty post-fact edge.
- `resources_discover` contributes runtime roots, not just loose skill/prompt/theme path lists.
  zi v2 has an explicit runtime-root system, so the extension seam should speak the same abstraction.
- aggregate reducers are explicit and precedence-aligned.
  first-claim or ordered-append semantics are part of the contract, instead of hidden last-wins loop behavior.

## current zi drifts this contract replaces

this contract is meant to replace a few temporary drifts in the current seams:

- the current registry and parser only expose a subset of classes.
- observer and interceptor semantics are still partially inferred from implementation comments instead of one public contract.
- some current observer payload builders intentionally ship minimal tables.
- some current dispatcher comments mention future classes that the registry does not yet model.

v2 should remove those drifts instead of documenting them as the api.

## non-goals

this doc does not define:

- the exact surface syntax of the extension language bindings
- the full nested schema for `message`, `tool_result`, `model`, `session_entry`, or `runtime_root_descriptor`
- provider registration api shapes
- retained-object contracts for ui, progress, jobs, or state persistence
