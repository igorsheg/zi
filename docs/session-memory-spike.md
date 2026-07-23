# Session memory spike

Date: 2026-07-23

## Question

Can lower-level byte ownership materially reduce Zi's long-session memory without replacing Bun, Pi, or OpenTUI?

The spike implemented five production paths:

1. fixed-buffer streaming JSONL restore;
2. parsed resident session tails with cold durable history;
3. format-2 content-addressed raw image blobs;
4. fixed UTF-8-aligned shell output tails;
5. aggregate live session storage admission.

ADR 0018 records the resulting ownership model.

## Method

Measurements used a standalone executable compiled from the working tree with Bun 1.3.14 on macOS 15.7 arm64. The TUI ran at 120×35 with `ZI_TUI_MEMORY=1`. Each scenario ran in a fresh process and received one harmless input edit after loading so the frame-driven diagnostic overlay sampled settled state. RSS values are single-run characterization evidence, not CI thresholds.

The long-session fixture contains 4,000 alternating user/assistant messages and a 32.5 MiB format-1 JSONL file. Its compacted variant retains 21 active messages. Using format 1 keeps the before/after journal payload identical, so those rows isolate restore and residency changes.

## Results

| Scenario                            | Before RSS | After RSS | Change    | Before heap used | After heap used |
| ----------------------------------- | ---------: | --------: | --------- | ---------------: | --------------: |
| Idle interactive                    |  122.7 MiB | 124.0 MiB | +1.3 MiB  |         16.3 MiB |        15.9 MiB |
| 4,000-message uncompacted restore   |  362.2 MiB | 305.0 MiB | −57.2 MiB |         52.6 MiB |        56.1 MiB |
| Same journal, compacted active tail |  303.7 MiB | 240.5 MiB | −63.2 MiB |         50.1 MiB |        18.1 MiB |

The compacted restore retained 22 physical entries out of 4,002 after runtime bootstrap metadata, while preserving full-journal materialization. Streaming restore reduced the uncompacted allocator high-water mark by about 16%. Cold parsed-entry release reduced compacted JS heap by about 64% and RSS by about 21%.

RSS remains much higher than active heap after scanning a large format-1 journal. JSC keeps allocator pages after temporary per-record strings are collected. Avoiding full-file decode and parsed cold retention pays, but it does not make cold JSON parsing free.

### Image blobs

A compacted session with one 8 MiB base64 image was restored through both formats under the new reader:

| Format                    | Journal | Blob bytes | Settled RSS |
| ------------------------- | ------: | ---------: | ----------: |
| Format 1 inline base64    | 8.0 MiB |          0 |   189.6 MiB |
| Format 2 SHA-256 raw blob | 1.7 KiB |    6.0 MiB |   125.9 MiB |

Format 2 reduced durable storage by 25% and settled restore RSS by about 64 MiB for this cold-image case. Active images still require Pi's base64 value and therefore do not receive the same heap reduction until compaction makes them cold.

### Shell tail

An isolated allocation stress fed 64 MiB as 4 KiB chunks while retaining the same 100 KiB tail:

| Tail implementation        | Median RSS |
| -------------------------- | ---------: |
| Repeated `Buffer.concat()` |   50.8 MiB |
| Fixed in-place buffer      |   29.7 MiB |

This is deliberately adversarial and does not predict ordinary command RSS, where operating-system chunks are often larger. It proves that fixed ownership removes allocator growth while preserving the same retained bytes. Session-shell behavior tests cover UTF-8 alignment and truncation semantics.

### Storage admission

Live journal plus unique image-blob bytes are now rejected transactionally before crossing 64 MiB. This does not lower ordinary RSS; it closes the previous state where a committed live session could become impossible to resume.

## Verdict

All five changes produced either a measured memory reduction or a new hard ownership invariant. The largest wins came from changing lifetimes—cold parsed history and image base64—not from packing ordinary message metadata into typed arrays. Neither mmap nor SIMD was required for this slice.

The remaining large compacted-restore RSS is temporary JSON parsing high-water, not retained session payload. A future experiment should target metadata-only cold-record validation before adding a native parser, mmap, Wasm, or SIMD dependency.
