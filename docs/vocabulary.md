---
slug: vocabulary
title: Know the vocabulary
order: 5
---

# Know the vocabulary

A few pages into this manual you will hit a sentence like "prompt-template and skill expansion still apply to admitted input," and its meaning will turn on a word nobody defined for you.

These guides borrow their vocabulary from Zi's own source, on purpose. Ten words carry most of the weight, and each one names a rule the runtime actually enforces. Read them once here and the contract pages stop reading as jargon and start reading as design.

## The words

`session`
: One unit of work: a conversation, the resources loaded for it, its work plan, and everything Zi did while it ran. A session is either a journal session on disk or a memory session that vanishes when the process exits.

`journal`
: The append-only file that makes a session durable. Zi appends messages, work plans, extension state, and bounded results for meaningful background work, so a resumed session can rebuild what it knew instead of guessing.

`admitted`
: Zi checked an input or operation against its type, its bounds, and the current state, and accepted it. Admission is the moment a request becomes real, and it is deliberately separate from the work finishing.

`settled`
: An operation reached a terminal state — succeeded, failed, or cancelled — and will not transition again. Zi rejects late completions from work that already settled.

`bounded`
: The thing has a hard limit: a byte size, a count, or a deadline. At that limit its owner either refuses new work or evicts on a stated policy, and the guide for that feature says which. What no owner does is keep growing until the process discovers the limit as a crash.

`owner`
: The single component responsible for a piece of mutable state or a resource's lifetime, including its disposal. Whoever created a process, subscription, or session is the one who releases it, which is why these guides keep telling you which layer owns what.

`evidence`
: The bounded, durable facts an operation leaves behind once it settles — a result, a duration, a stable failure code. Evidence is what you read afterwards instead of re-deriving the story from a transcript.

`projection`
: A read-only view derived from authoritative state and safe to hand to a client. A projection never becomes a second copy you have to keep in sync, and it deliberately omits things like credentials and provider configuration.

`trusted`
: Project configuration that an explicit decision admitted. Until then, a repository's `.zi` directory and any ancestor `.agents/skills/` are discovered but not loaded, because cloning a repository should not hand it your agent.

`generation`
: One loaded set of extension registrations. Reload replaces the whole generation at once, so you never end up running half of an old extension and half of a new one.

## Admitted is not settled

This is the distinction that trips people, and it appears in every protocol on the system:

```text
Admitted   Zi accepted the request.          The response tells you.
Settled    The work reached a terminal end.  The evidence tells you.
```

An RPC `session.prompt` response means your text was admitted, not that the model did anything with it. A successful agent message delivery means the target session accepted it, not that the target read it. An AgentTeam turn result becomes durable only after that turn settles, which is exactly why its completion remains trustworthy after restart.

Keeping the two apart is what lets Zi answer immediately, refuse early when something is out of bounds, and still give you one durable answer later.

See [RPC](rpc.md) for how admission and settlement are framed on the wire and [Delegate work to agents](subagents.md) for durable turn evidence and what message delivery does not promise.
