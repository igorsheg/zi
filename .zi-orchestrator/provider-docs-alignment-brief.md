You are the implementing agent for a small but contract-sensitive docs slice in /Users/igors/workspace/dev/personal/zi.

Model: openai-codex/gpt-5.4

## Mission
Align the extension v2 docs with the now-landed runtime behavior for same-name provider claims and deterministic restoration semantics.

This is follow-up to the provider override runtime slice and is on the path of:
- zi-fex
- zi-fex.2

## Context
Runtime behavior was sharpened so provider claims can stack by provider name and restore deterministically as claims are removed. That means the docs should not imply a too-simple story if it now drifts from real behavior.

We want the docs to stay truthful while preserving the broader doctrine:
- canonical root order still decides precedence
- registration classes still resolve deterministically
- first claimant still defines the active surface by default
- but provider claims with the same provider name may have surviving registrations that become active again after teardown/unregister, instead of collapsing to baseline immediately

## Read first
1. /Users/igors/workspace/dev/personal/zi/docs/runtime-roots.md
2. /Users/igors/workspace/dev/personal/zi/docs/extensions-providers.md
3. /Users/igors/workspace/dev/personal/zi/docs/extensions-conformance-matrix.md
4. /Users/igors/workspace/dev/personal/zi/src/ai/provider.zig
5. /Users/igors/workspace/dev/personal/zi/src/coding_agent/model_registry.zig

## Scope
Make the minimum doc edits needed so the written contract matches the runtime truth after the provider-claim stacking/restoration fix.

Priorities:
1. Preserve the high-level runtime-roots doctrine
   - canonical root order
   - per-registration-class collision semantics
   - first claimant wins as the default active surface rule
2. Clarify provider-specific restoration truth where needed
   - same-name provider claims can have a deterministic surviving claimant after unregister/teardown
   - removal of one claim does not imply immediate fallback to baseline if another surviving same-name claimant still exists
3. Keep wording tight and durable
   - do not overfit to one implementation detail
   - do not introduce new surface area
   - do not reopen auth_header, modifyModels, oauth callbacks, or stream handlers

## Likely files to edit
- /Users/igors/workspace/dev/personal/zi/docs/runtime-roots.md
- /Users/igors/workspace/dev/personal/zi/docs/extensions-providers.md
- optionally /Users/igors/workspace/dev/personal/zi/docs/extensions-conformance-matrix.md only if current wording is misleading after the runtime change

## What not to do
- no code changes unless you find a doc-blocking bug so severe that the docs would be false without it; if that happens, stop and report instead of widening scope
- no broad doc rewrites
- no style churn

## Deliverable
A small truthful docs patch.

## Validation
Run the minimum validation suitable for a docs-only change, e.g. inspect the diff for scope/accuracy. No broad test runs needed.

## Report
Return:
- summary
- files changed
- why the wording is now more truthful
- any open ambiguity you chose not to resolve
