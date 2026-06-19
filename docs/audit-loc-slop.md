# LoC / slop audit — `src/coding_agent` + `src/tui`

> Date: 2026-06-19 · Method: a 118-agent workflow. Per-unit slop auditors (one
> per file ≥220 LoC, small files bucketed) → an independent adversarial verifier
> per finding (tries to *refute* each cut) → a 3-lens cross-file duplication sweep
> per module → a per-module synthesis. Graded against `AGENTS.md` / `CONTEXT.md`,
> with `.references/pi-mono` as the behavioral north star and Andrew Kelley's Zig
> mindset as the architectural one.
>
> This audit is a **different lens** than [`audit-coding-agent-tui.md`](audit-coding-agent-tui.md).
> That one asked "is it correct / AK-shaped?". This one asks only: **"how much of
> this LoC is removable slop — deletable or collapsible with zero observable
> behavior change and no contract violation?"** — to test the thesis that the
> implementation is AI slop that could be ~40% smaller.
>
> `code wins` — when a finding here disagrees with the code, re-check the code and
> correct this file.

## Verdict

**The "~40% AI slop" thesis is NOT supported — in either module, by an order of
magnitude.** After exhaustive per-file and cross-file verification, the genuinely
removable slop (behavior-neutral, contract-respecting, each cut adversarially
re-verified) is:

| Module | LoC | Confirmed removable | Reduction | 40% target |
|---|---:|---:|---:|---:|
| coding_agent | 16,693 | **328** | **~2.0%** | 6,677 |
| tui | 7,932 | **240** | **~3.0%** | 3,173 |
| **total** | **24,625** | **568** | **~2.3%** | 9,850 |

zi is **not** AI slop. It is close to minimal already. The verbosity a LoC-count
mistakes for slop is overwhelmingly the explicitness the contract *mandates*:
named bounds ("bounds pay rent"), direct-state encoding, single-owner mutation
paths, laddered `errdefer`/`select` cleanup, per-field optionals, and a large
behavior-test surface. To approach 40% you would have to delete that — which is
regression, not cleanup. The real, worth-doing cleanup is ~568 LoC of dead code,
write-only fields, byte-identical helpers, and dormant feature seams.

This corroborates the prior correctness audit ("already AK-shaped and close to
small/minimal") under an independent volume lens, and the standing project
verdict: **the artifact to maintain is the reconciled ledger, not a rewrite.**

### What the auditors tried to cut and were refuted on

The verify step earned its keep by *rejecting* attractive-looking cuts that turned
out to be load-bearing — exactly the failure mode of a naive LoC-minimizer:

- `read.zig` Config caps, `session_listing` `max_sessions` / `max_directory_entries`
  — enforced bounds with tests, not ceremony.
- `prompt_snippets` optionality — the deliberate sparse-overlay encoding the system
  prompt depends on.
- `setOAuthCredentials` — the owner's single mutation path.
- bash `"2000 lines / 50KB"` prose — active LLM-facing documentation, not a
  re-implemented bound.
- tui `slash_arg_completion_count_max`, shimmer/shuffle `Config` tunables,
  `ansi.Color` alias — documented eviction bound, test-injection seams, in-file
  palette consumer.

### How to read the "speculative-flexibility" rows

Some of the largest removable items (tui's modal-picker seam ~59 LoC, theme fg/bg
seam ~24 LoC, `CustomFormat.plain` ~10 LoC) are deliberately-reserved seams that
`CONTEXT.md` says should not exist until a second concrete owner proves them.
Cutting them is contract-*aligned*, but it is a **feature-deferral decision**, not
janitorial deletion — flagged `needs-verify`/Medium risk accordingly.

---

<!-- BEGIN coding_agent synthesis (verbatim from synthesis agent) -->
## coding_agent — Reduction Verdict

**Verdict: the ~40% AI-slop thesis is NOT supported.** Verified removable slop is **328 LoC (1.96% of 16,693)** — roughly one-twentieth of the ~6,677 LoC a 40% claim requires.

| Number | Value |
|---|---|
| Module LoC | 16,693 |
| Confirmed removable slop (verified `is_real_slop`) | **328** |
| Reduction | **1.96%** |
| 40%-thesis target | 6,677 LoC |
| Fraction of thesis actually supported | ~5% |

### By category (confirmed LoC)

| Category | LoC |
|---|---|
| collapsible-boilerplate | 98 |
| duplicated-truth | 86 |
| single-caller-indirection | 68 |
| dead-code | 57 |
| speculative-flexibility | 19 |

### Ranked opportunities (highest-LoC, lowest-risk first)

| Lever | Files | LoC | Risk |
|---|---|---|---|
| Hoist `*ErrorResult`/`*ErrorResultFmt` (5 copies) into one `path_utils.errorResult`/`errorResultFmt` | read.zig, write.zig, edit.zig, path_utils.zig | ~38 | safe |
| Collapse 5 repeated select() common-arm bodies into WakeResult helpers | session_runtime.zig:438-628 | 19 | safe |
| Remove unused `shell_path`/`command_prefix` override layer | tools/bash.zig | 19 | safe (no prod caller) |
| Dedup 6-arm readFileAlloc+catch ladder into `readFileOrNull` | resources.zig:205-253 | 18 | safe |
| Unify test-only `UpdateCapture` into test_support | write.zig, edit.zig, test_support.zig | 18 | safe (test-only) |
| Collapse `resolveExisting/CreatablePath` pass-throughs | paths.zig:50-66 | 17 | safe |
| Inline `discover*PromptFile` filename wrappers | resources.zig:105-119 | 15 | safe |
| Delete `lineAt` dead helper | tools/edit.zig:543-555 | 13 | safe (zero callers) |
| Embed `SessionListOptions` in `SessionSelectionOptions` | session_listing.zig | 12 | safe |
| Path-operand (`path`/`file_path`) extraction → `path_utils` | read/write/edit | 9 | safe |
| Delete dead `ArgKind` enum + `arg_kind` field | slash_commands.zig | 9 | safe |
| `resultFromOutput` null pass-through inline | tools/bash.zig | 9 | safe |
| Remove `setOAuthCredentials`/owned-config ladder etc. (misc <8 LoC each) | various | ~50 | mostly safe |

### Honest narrative

Every unit audited returned a "already lean / AK-shaped" verdict, and the prior correctness audit reached the same conclusion. The removable slop is real but small and uniformly low-severity: dead one-line guards (`nextBase`, `window==0`, `firstLineExceedsLimit`), zero-caller wrappers (`parseSlashCommand`, `parseName`, `lineAt`, `decodeRequestId`, `resolveExisting/CreatablePath`, `discover*PromptFile`), write-only state (`SettingsManager.allocator`, `Snapshot.full_output_path`, `ArgKind`), and byte-identical helpers begging for a single lower-layer owner (the `*ErrorResult` family is the single biggest lever at ~38 LoC).

What the thesis would mis-read as slop is mostly contract-mandated. Verbose `select`/`errdefer` ladders, per-field optionals, explicit named bounds, single-owner mutation paths, and the large behavior-test surface are all required by AGENTS.md ("bounds pay rent", "one owner, one mutation path", "test behavior") and CONTEXT.md. Several attractive "slop" candidates were affirmatively REFUTED on verification because they are load-bearing: `read.zig` Config caps and `session_listing` `max_sessions`/`max_directory_entries` are enforced bounds with tests; `prompt_snippets` optionality is the deliberate sparse-overlay encoding the system prompt depends on; `setOAuthCredentials` is the owner's mutation path; the bash "2000 lines/50KB" prose is active LLM-facing documentation, not a re-implemented bound. Two findings also collide (`write-1`/`write-2` target the same region) and were de-duplicated; cross-file error-helper credit was netted against the per-unit `write-1` count.

Bottom line: a disciplined pass removes ~330 LoC (~2%) with near-zero behavior risk and genuinely improves single-ownership. That is worth doing, but it is an order of magnitude away from "40% AI slop." The module is close to minimal; the artifact to maintain is the reconciled ledger, not a rewrite.
<!-- END coding_agent synthesis -->

---

<!-- BEGIN tui synthesis (verbatim from synthesis agent) -->
## tui module — reduction verdict

**Total module size:** 7932 LoC
**Confirmed removable slop (verified, de-duplicated):** ~240 LoC
**Reduction:** ~3.0%

### Verdict on the thesis

> "this is AI slop accumulated to X LoC, while it could be ~40% less"

**Not supported.** The honest, evidence-based number is **~3%, not ~40%** — an order of magnitude below the thesis. Every file was audited under a pure volume lens ("what can be deleted with zero observable-behavior change and no contract violation?"), and the verified real-slop reductions sum to ~240 LoC. The prior correctness audit's judgment ("already AK-shaped and close to small/minimal") survives the volume lens intact.

This module is not bloated. Its verbosity is almost entirely the kind AGENTS.md mandates: named bounds ("bounds pay rent"), state encoded directly in fixed-size inline stores, single-owner mutation paths, the dual count/draw producer in render, and the markdown stable-cache. Four candidate findings were **refuted as load-bearing**: `slash_arg_completion_count_max` (a documented eviction bound), the shimmer and shuffle `Config` tunables (test-injection seams + named-constant single-source-of-truth), and the `ansi.Color` type alias (consumed in-file by the palette).

### Ranked opportunities (highest-LoC, lowest-risk first)

| Lever | Files | LoC | Risk |
|---|---|---|---|
| Dormant modal-picker seam (no production owner) | src/tui/App.zig (+render.zig) | ~59 | Medium — deferred dialog feature, deletes tested-but-dormant surface |
| Three dead `clear_*` commands + stranded helpers | src/tui/App.zig | ~33 | Low — zero producers, safe |
| Dead `takeSubmit()` + its test | src/tui/Composer.zig | ~26 | Low — safe |
| fg/bg adaptive-theming seam + blend/luminance helpers | src/tui/theme.zig | ~24 | Medium — documented capacity, needs-verify |
| Four unused glyph constants | src/tui/glyphs.zig | ~12 | Low — safe |
| Cross-file sanitize idiom unification | App.zig, Picker.zig, Greeter.zig, status.zig, text.zig | ~11 | Low — multi-file refactor for modest gain |
| Dead `Row.suffix`/`suffix_style` slot | src/tui/render.zig | ~11 | Low — unreachable branch, safe |
| `CustomFormat.plain` single-consumer seam | src/tui/Transcript.zig (+render.zig) | ~10 | Low/Med — needs-verify (feature-cut) |
| `prependMessage` dead wrapper | src/tui/Transcript.zig | ~7 | Low — safe |
| Micro write-only fields + single-caller wrappers (long tail) | Picker.zig, Terminal.zig, text.zig, match.zig, markdown.zig, PromptHistory.zig, Composer.zig | ~30 | Low — each sub-noise-floor, safe |

### By category

| Category | LoC |
|---|---|
| dead-code | 116 |
| speculative-flexibility | 95 |
| duplicated-truth | 11 |
| collapsible-boilerplate | 9 |
| single-caller-indirection | 9 |

### Narrative

The removable LoC splits almost evenly between genuine **dead code** (~116: unused commands, write-only fields, unreachable branches, unused exports) and **speculative-flexibility seams** (~95: the modal-picker path, the theme fg/bg path, and the `CustomFormat.plain` variant). The speculative half is the only place where a maintainer's judgment matters: these are deliberately-reserved seams (confirm dialogs, adaptive theming, plain-text custom items) that CONTEXT.md and AGENTS.md say should not exist until a second concrete owner proves them — so cutting them is contract-*aligned*, but it is a feature-deferral decision, not pure janitorial deletion.

The duplication lens added almost nothing: the three cross-file lenses redundantly reported the same two sanitize idioms, which de-duplicate to ~11 net LoC of helper-extraction opportunity (and ~3 of that already overlaps the status.set() per-unit finding, so it is not double-counted here).

Bottom line: a maximally aggressive, behavior-neutral, contract-respecting sweep removes about 240 lines. To approach 40% (~3170 LoC) you would have to delete contract-mandated explicitness — the named bounds, direct-state encoding, and single-owner structure that the doctrine exists to protect. That is not slop removal; it is regression. The thesis is wrong for this module.
<!-- END tui synthesis -->
