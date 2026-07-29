# ADR 0025: Code Mode tool values are declared

## Status

Accepted.

## Context

ADR 0024 gave every nested Code Mode call the guest shape `{ text, details }`. That shape preserved Pi's `AgentToolResult` presentation contract, but it made generated JavaScript interpret model-facing prose and exposed tool result details as if they were an operational payload. A tool returning structured information as text required the model to guess whether `response.text` contained JSON and call `JSON.parse()` manually.

Cloudflare Code Mode demonstrates the useful alternative: tool output schemas become TypeScript declarations in model context, while sandbox transport decodes host-produced envelopes and returns the native tool value. Its implementation treats missing output schemas as `unknown` and does not enforce outputs at runtime; Zi can preserve the useful contract while validating its extension process seam.

Zi's extension API previously required every tool to return a string. That was sufficient for direct model calls but forced API-oriented extensions to encode structured values as strings, precisely where Code Mode provides the most leverage.

## Decision

Each admitted tool has one model-facing result and one Code-mode tool value. Model-facing content and tool result details retain their existing meanings. Code execution retains them host-side for error classification, nested tool trace projection, compaction accounting, and direct client presentation. Generated JavaScript receives only the bounded JSON-compatible Code-mode tool value.

A tool-specific Code Mode contract may declare an output schema and execute through the same underlying tool implementation while producing both projections. Tools without that internal contract return their model-facing text as a string value. Code Mode generates each guest method's return type from its output schema, using `string` for the fallback. Values are already decoded; generated code does not receive or parse transport envelopes.

Extension tools may declare `outputSchema` and return a matching JSON value. Omitting `outputSchema` preserves the released string-returning contract. The extension worker validates result JSON bounds and the declared schema before publishing the result. Direct agent calls render non-string extension values as compact JSON; Code Mode receives the native value. Tool result details never carry the operational value.

The extension worker protocol advances to version 4 and carries `value` in tool-result messages. The Code Mode worker protocol advances to version 2 and carries the native value separately from turn termination. Both protocol validators reject the previous presentation-envelope shapes.

Zi keeps its existing CodeExecution owner, QuickJS process isolation, cancellation, serialized call admission, bounds, and nested trace. It does not adopt Cloudflare's runtime, connectors, replay, approvals, or durable workflow architecture.

## Consequences

- Generated code can branch, filter, and aggregate structured extension results without parsing presentation prose.
- Tool output declarations become truthful model context, while extension output mismatches fail at the worker seam.
- String-returning extensions remain source compatible and now return strings directly in Code Mode rather than `{ text, details }`.
- Previous generated snippets that access `.text` are not reusable artifacts and must follow the new declarations if copied from history.
- Tool result details remain safe to evolve for client-neutral presentation without becoming an orchestration contract.
- Built-in tools can adopt structured Code-mode tool values individually when demonstrated workflows need them; no broad output registry is introduced.
