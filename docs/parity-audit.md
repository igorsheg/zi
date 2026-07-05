# TUI parity audit

Cut-over baseline: `46b6276~1`. Sources audited only: old `interactive.zig`, old `presentation_queue.zig`, current `tool_view.zig`, current `view_diff.zig`, current `engine_drain.zig`.

## Tool titles

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 1 | bash tool title renders as `$ {args.command}` and appends ` (timeout Ns)` when `args.timeout` is present. | `tool_view.formatCallTitleWithHome` via `applyToolCall`/`applyToolStart` | MISSING | `engine_drain.ensureTool` sets title to tool name only (`bash`). `tool_view.formatCallTitleWithHome` is orphaned. |
| 2 | read tool title renders `read {file_path/path}`. | `tool_view.formatCallTitleWithHome` | MISSING | `engine_drain.ensureTool`; `tool_view.formatCallTitle*` orphaned. |
| 3 | edit/write tool titles render `{tool_name} {file_path/path}`. | `tool_view.formatCallTitleWithHome` | MISSING | `engine_drain.ensureTool`; title is only `edit`/`write`. |
| 4 | custom/unknown tools get an empty formatted title, not a guessed title. | `tool_view.formatCallTitleWithHome` | CHANGED(now title is the raw tool name) | `engine_drain.ensureTool` |
| 5 | read title appends `:start-end` from positive `offset`/`limit`, default start `1`. | `tool_view.addReadLineRange` | MISSING | `tool_view.addReadLineRange` orphaned. |
| 6 | tool title paths under `$HOME` collapse to `~`/`~/suffix`. | `tool_view.TitleBuilder.addPath` | MISSING | Only composer cwd still does this in `view_diff.formatChromeCwd`. |
| 7 | tool titles sanitize newlines, carriage returns, and tabs to spaces, then trim to valid UTF-8. | `tool_view.TitleBuilder.add`/`slice` | MISSING | `tool_view.formatCallTitle*` orphaned. |
| 8 | compact read titles for `SKILL.md`, docs paths, and resource files render short labels plus `(ctrl+o to expand)`. | `tool_view.formatCompactCallTitle` | MISSING | `tool_view.formatCompactCallTitle` orphaned. |
| 9 | history tool-call rows recompute titles from retained `arguments_json`. | `tool_view.historyCallAppend` | MISSING | `tool_view.historyCallAppend` orphaned; `view_diff` has no history rendering. |
| 10 | history tool-call rows fall back to retained old title when `arguments_json` is invalid. | `tool_view.historyCallAppend` | MISSING | Orphaned. |
| 11 | pending tool-call previews append as pending tool rows with formatted title/compact title. | `applyToolCall` | CHANGED(non-write previews now show raw JSON body, title is name only) | `engine_drain.toolPreview`, `engine_drain.ensureTool` |
| 12 | final tool execution appends a status-only update with blank title/compact title. | `tool_view.endAppend` via `applyToolEnd` | CHANGED(no `endAppend`; item state/footer mutate in place) | `engine_drain.toolEnd`, `view_diff.toolStatus` |

## Tool bodies per tool

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 13 | bash streaming updates append the first text result chunk. | `applyToolUpdate`, `tool_view.firstResultText` | RESTORED | `engine_drain.toolUpdate`, `toolResultText` |
| 14 | live tool output removes `\r` and expands tabs to three spaces before display. | `tool_view.normalizedOutputChunk` | MISSING | `tool_view.normalizedOutputChunk` orphaned. |
| 15 | bash is treated as streaming, so terminal execution does not replace the streamed body at end. | `tool_view.streamsOutput`, `applyToolEnd` | RESTORED | `engine_drain.ensureTool`/`toolEnd` via `display.streams_output` |
| 16 | bash truncation details become footer metadata. | `tool_view.metadataForDetails`/`bashMetadata` | RESTORED | `view_diff.toolMetadata` calls `tool_view.metadataForDetails` |
| 17 | settled/history bash bodies strip legacy bracket notices and append exit/timed-out/signal status text. | `tool_view.historyFinish`, `bashBodyFromDetails`, `writeBashStatus` | MISSING | `tool_view.historyFinish` and `resultOutput` orphaned. |
| 18 | successful read bodies trim trailing empty lines. | `tool_view.resultOutput`, `trimTrailingEmptyLines` | MISSING | `engine_drain.toolResultBody` returns raw first text. |
| 19 | read continuation/truncation text is removed from body and moved to footer. | `readBodyFromDetails`, `readMetadata` | CHANGED(footer restored, raw body cleanup missing) | Footer: `view_diff.toolMetadata`; body: `engine_drain.toolResultBody` |
| 20 | read first-line-exceeds-limit body becomes empty with footer explaining truncation. | `readBodyFromDetails`, `readMetadata` | CHANGED(footer restored, body still raw first text) | Footer: `view_diff.toolMetadata` |
| 21 | successful edit result displays `details.diff` instead of generic text. | `tool_view.resultOutputFromOwnedText` | RESTORED | `engine_drain.toolResultBody` |
| 22 | edit errors display raw result text, not `details.diff`. | `tool_view.resultOutputFromOwnedText` | RESTORED | `engine_drain.toolResultBody` checks `!is_error` |
| 23 | write tool-call preview displays first collapsed content lines before execution. | `tool_view.callPreviewText` | RESTORED | `engine_drain.writePreview` |
| 24 | write preview footer says `Showing lines 1-N of M` when content exceeds collapse limit. | `tool_view.callPreviewFooter` | RESTORED | `engine_drain.writePreview` |
| 25 | write execution start clears the preview body. | `tool_view.clearsCallPreviewOnStart`, `applyToolStart` | CHANGED(restored for write, but current clears every tool body on start) | `engine_drain.toolStart` |
| 26 | write execution start clears the preview footer too. | `applyToolStart` | MISSING | `engine_drain.toolStart` clears text only. |
| 27 | successful write result is hidden so preview content remains the visible body. | `tool_view.shouldHideSuccessfulToolResult` | MISSING | `tool_view.shouldHideSuccessfulToolResult` orphaned. |
| 28 | mixed text/image tool results join text blocks and image fallbacks like `[Image: image/png]`. | `tool_view.formatResultContent`, `imageFallbackText` | MISSING | `engine_drain.toolResultText` keeps only first text item. |
| 29 | successful bash/read/write result text trims trailing empty lines. | `tool_view.shouldTrimResult` | MISSING | `engine_drain.toolResultBody` does no trim. |
| 30 | error results do not trim successful-only whitespace. | `tool_view.shouldTrimResult` | RESTORED | `engine_drain.toolResultBody` returns raw text for errors. |
| 31 | non-streaming final output joins all non-empty text blocks with newlines. | `tool_view.formatResultContent` | MISSING | `engine_drain.toolResultText` keeps first text block only. |
| 32 | output body clipping uses `details.truncation.outputBytes` and backs down to valid UTF-8. | `outputPrefixFromDetails`, `utf8Prefix` | MISSING | Only footer metadata uses details. |

## Tool footers/chips

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 33 | final/static footer can be derived from `details_json`. | `tool_view.metadataForDetails` | RESTORED | `view_diff.toolMetadata` |
| 34 | read limited footer: `Limited: X more lines in file; use offset=Y to continue`. | `readMetadata` | RESTORED | `tool_view.readMetadata` called by `view_diff.toolMetadata` |
| 35 | read first-line safety clipping footer says `Truncated: first line exceeds 50KB limit`. | `readMetadata` | RESTORED | `tool_view.readMetadata` called by `view_diff.toolMetadata` |
| 36 | multiple read footer chips are separated by ` • `. | `readMetadata` | RESTORED | `tool_view.readMetadata` |
| 37 | bash truncation footer says `Truncated: showing X of Y lines` or byte-limit variant. | `bashMetadata` | RESTORED | `tool_view.bashMetadata` via `metadataForDetails` |
| 38 | only process/stream tools show duration footer. | `tool_view.showsDuration` | RESTORED | `engine_drain.ensureTool` stores display; `view_diff.updateToolFooter` checks `shows_duration` |
| 39 | running duration chip label is `Elapsed 1.2s`. | `tickToolTimers`, `toolDurationChip` | CHANGED(label is `running 1.2s`) | `view_diff.renderToolFooter` |
| 40 | completed duration chip label is `Took 1.2s`. | `finishToolTimer` | CHANGED(label is `took 1.2s`) | `view_diff.renderToolFooter` |
| 41 | metadata and duration join as `{metadata} • {duration}`. | `tool_view.joinMetadata` | RESTORED | `view_diff.renderToolFooter` |
| 42 | live duration timers are capped to 8 tool ids of 96 bytes; overflow silently omits duration. | `startToolTimer` | CHANGED(no old timer table; cursor stores one id up to 128 bytes per sampled item) | `view_diff.ItemCursor` |
| 43 | error tool with no metadata explicitly clears footer. | `applyToolEnd` | MISSING | `diffExistingItem` only replaces non-empty footers. |
| 44 | errored tool status renders as `.err`. | `tool_view.endAppend`/`append` | MISSING | `view_diff.toolStatus` maps final to success; `is_error` is not present. |

## Arg previews

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 45 | preview rebuild cadence is 32ms. | `presentation_queue.tool_call_preview_interval_ms` | RESTORED | `engine_drain.preview_rebuild_interval_ms` |
| 46 | non-write tool-call args are not shown as raw JSON body. | `applyToolCall` | CHANGED(current displays JSON body for non-write previews) | `engine_drain.toolPreview`, `jsonPreview` |
| 47 | preview pacing was a UI reveal queue decision, not a VM mutation throttle. | `presentation_queue.ToolAppend.presentationIntervalMs` | CHANGED(now throttles engine preview rebuilds) | `engine_drain.toolPreview` |
| 48 | write preview output remains visually capped while footer count grows as args stream. | `tool_view.callPreviewText`/`callPreviewFooter` | RESTORED | `engine_drain.writePreview` |
| 49 | write preview footer appears only when visible lines are fewer than total lines. | `tool_view.callPreviewFooter` | CHANGED(current emits only when `total_lines > lines_max`; equivalent except trailing-empty-line behavior differs) | `engine_drain.writePreview` |
| 50 | write preview trims trailing empty lines before display/counting. | `tool_view.callPreviewText`, `callPreviewFooter` | MISSING | `engine_drain.writePreview` uses raw content. |
| 51 | call preview is cleared on start only for write. | `tool_view.clearsCallPreviewOnStart` | CHANGED(current clears all tool bodies on start) | `engine_drain.toolStart` |
| 52 | missing title args render as ellipsis, e.g. `$ ...`. | `tool_view.argStringOrEllipsis` | MISSING | Title formatter orphaned. |

## Streaming/reveal behavior

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 53 | assistant text/thinking reveal interval is 12ms. | `presentation_queue.assistant_reveal_interval_ms` | MISSING | `view_diff.diff` emits sampled deltas immediately. |
| 54 | tool-call preview interval is 32ms. | `presentation_queue.tool_call_preview_interval_ms` | CHANGED(engine throttle restored, UI reveal queue removed) | `engine_drain.preview_rebuild_interval_ms` |
| 55 | tool output reveal interval is 200ms. | `presentation_queue.tool_output_interval_ms` | MISSING | No current per-kind output reveal in audited sources. |
| 56 | background status/footer/tag work interval is 100ms. | `presentation_queue.background_pending_work_interval_ms` | MISSING | No pending presentation queue. |
| 57 | animation fallback interval is 16ms when queue empty. | `presentation_queue.animation_frame_interval_ms` | MISSING | Not represented in audited current diff/drain sources. |
| 58 | assistant/thinking pending chunks coalesce up to 4KiB. | `presentation_queue.tryCoalesce` | MISSING | No pending queue. |
| 59 | tool output pending chunks coalesce up to 8KiB per tool id. | `presentation_queue.tryCoalesce` | MISSING | No pending queue. |
| 60 | pending UI queue is bounded to 512 items / 256KiB and drops overflow. | `presentation_queue.count_max`, `bytes_max`, `push` | MISSING | No equivalent in audited current sources. |
| 61 | owner applies at most 4 pending UI works / 4KiB per tick. | `applyPendingUiWorkBounded` | MISSING | `view_diff.diff` may emit all sample changes for a diff. |
| 62 | first pending queue overflow shows `TUI update backlog dropped`. | `queuePendingUiWork` | MISSING | No pending queue/drop notice. |
| 63 | transcript message/tool chunks are sliced at 1024 bytes on UTF-8 boundaries. | `boundedUiChunk`, `appendToolOutput` | MISSING | Current diff emits sample suffixes as provided. |
| 64 | committed messages tag latest user/assistant/tool source ids for transcript navigation. | `queueSourceTag`, `presentation_queue.SourceTag` | MISSING | `view_diff` emits no source-tag commands. |

## Composer chrome

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 65 | greeter title is `zi {version}` and subtitle is `Type / for commands. Ask zi about zi if you get lost.` | `installGreeter` | MISSING | No greeter command in audited current sources. |
| 66 | composer-left cwd collapses `$HOME` to `~`. | `formatComposerCwd` | RESTORED | `view_diff.formatChromeCwd` |
| 67 | composer-left cwd of `.` is resolved to real path before formatting. | `applySessionChromeParts` | MISSING | `view_diff.emitChrome` formats sampled cwd directly. |
| 68 | composer cwd is bounded to status text buffer. | `formatComposerCwd` | CHANGED(current explicitly UTF-8 clips before copy) | `view_diff.formatChromeCwd` |
| 69 | composer-right context shows `{percent_tenths}/{window}`, e.g. `12.3%/200k`. | `formatContextUsage` | CHANGED(current shows integer percent only, no window) | `view_diff.formatChromeRight` |
| 70 | `no authenticated model` appears only when provider and model are both `unknown`. | `formatComposerRight` | CHANGED(current checks empty/unknown provider only) | `view_diff.formatChromeRight` |
| 71 | composer-right still includes `provider/model (thinking_level)`. | `formatComposerRight` | RESTORED | `view_diff.formatChromeRight` |
| 72 | old composer status contribution ids were 1/2. | constants `composer_cwd_slot_id`, `composer_session_slot_id` | OBSOLETE(internal id, not pixel output) | Current ids are 3/4 in `view_diff.zig`. |
| 73 | `loading completions` shimmer status while completions snapshot is in flight. | `setCompletionStatus` | MISSING | `view_diff.emitCompletion` only emits picker commands. |
| 74 | queue status copy is `queued: N steering, M follow-up`. | `applyQueueCounts` | CHANGED(copy restored, priority/tone changed) | `view_diff.emitQueue` |

## Status/notify copy

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 75 | notify command carries level mapped from transcript status level. | `notifyLevel` | CHANGED(current uses `failure_text.noticeCopy`; exact table not in audited sources) | `view_diff.emitNotices` |
| 76 | info notifications get empty annote; warning/error annote is null unless semantic overrides. | `notifyAnnote` | MISSING | `view_diff.emitNotices` does not pass annote. |
| 77 | operation failure fallback messages: missing credentials, rate limit, context overflow, network, etc. | `formatOperationalFailureMessage` | MISSING | `engine_drain.notice` receives raw text; fallback table absent from audited current sources. |
| 78 | operation failure semantics choose annote `auth`/`rate`/`context`/`provider`/`network`/`cancel`/`error`. | `operationalFailureNotifySemantic` | MISSING | `view_diff.emitNotices` does not pass annote. |
| 79 | operation failure semantics choose per-category TTLs from 3s to 15s. | `operationalFailureNotifySemantic` | MISSING | `view_diff.emitNotices` does not pass TTL. |
| 80 | retry status says `retry A/B in Dms[: reason]`. | `formatRetryStatus` | CHANGED(status is just bounded retry reason) | `engine_drain.retryStart`, `view_diff.emitOperation` |
| 81 | retry-start notification has annote `retry`, warning tone, TTL 5000ms. | `auto_retry_start` branch | MISSING | `engine_drain.retryStart` pushes generic notice. |
| 82 | retry-end failure notification has annote `retry`, err tone, TTL 10000ms. | `auto_retry_end` branch | MISSING | `engine_drain.retryEnd` pushes generic notice. |
| 83 | recovery notices: `recovering event gap`, `replay requires snapshot in TUI adapter`, `replay gap; requesting snapshot`. | `acceptEnvelope`, `applyClientEvent` | MISSING | No replay/recovery rendering in audited current sources. |
| 84 | event overflow copy is `event overflow: dropped N`. | `event_overflow` branch | MISSING | No event overflow rendering in audited current sources. |
| 85 | rejected queue-full copy is `prompt queue full ({max})`. | `formatRejectionMessage` | MISSING | No rejection rendering in audited current sources. |
| 86 | submit queue-full copy is `command queue full`. | `submitCommand` | MISSING | No equivalent in audited current sources. |
| 87 | cancel request shows keyed `cancel requested` with canceled tone. | `cancelActive` | CHANGED(status restored, keyed notify/TTL behavior gone) | `engine_drain.operationCancelRequested`, `view_diff.emitOperation` |
| 88 | operation canceled shows keyed `canceled` notify and marks pending tools canceled. | `applyOperationFinished` | CHANGED(tool cancel path partly restored; notify missing) | `engine_drain.cancelStreaming`, `view_diff.diffExistingItem` |
| 89 | shutdown-start event requests terminal stop. | `applyClientEvent.shutdown_started` | OBSOLETE(not a rendering decision in new diff/drain sources) | |
| 90 | selection copy statuses: `selection copied`, `selection copied via terminal clipboard`, `clipboard copy failed`, empty/too-large selection. | `finishReadyFrontendTask`, `handleCopySelection` | MISSING | No clipboard/copy rendering in audited current sources. |
| 91 | input warnings: `input truncated`, `input effects dropped`, `input reader stopped`, editor/clipboard image errors. | `pollAndDrainInput`, `appendClipboardImageError`, `handleExternalEditor` | MISSING | No input warning rendering in audited current sources. |

## History/paging notices

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 92 | when viewing older history and live output arrives, show `new output below; ctrl+end reloads tail`. | `noteHistoryHasNewerTail` | MISSING | `view_diff` tracks `history_rev` but emits no notice. |
| 93 | requesting tail snapshot clears the transcript-tail notice. | `requestTailSnapshot` | MISSING | No current tail notice. |
| 94 | history pages prepend older items in reverse page order. | `applyHistoryPage` | MISSING | No history page rendering in `view_diff`. |
| 95 | while an older history window is open, live tail presentation work is dropped until reload. | `applyHistoryPage`, `tailTranscriptWork` | MISSING | No current history-window policy in audited sources. |
| 96 | hidden-thinking history assistant rows append an empty hidden thinking placeholder before text. | `appendHistoryThinkingPlaceholder` | MISSING | No history rendering. |
| 97 | history message append splits large text into bounded chunks. | `appendHistoryMessage` | MISSING | No history rendering. |
| 98 | history tool results install settled body/footer directly, bypassing reveal queue. | `applyHistoryToolResult` | MISSING | `tool_view.historyFinish` orphaned. |

## Session lifecycle visuals

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 99 | `/session` transcript title is `Session Info`. | `appendSessionInfo` | MISSING | No prompt-command/session-info rendering in audited current sources. |
| 100 | `/session` output includes `File: {path}` or `File: In-memory`, then `ID`. | `formatSessionInfo` | MISSING | No current equivalent. |
| 101 | `/session` output has markdown sections `**Messages**`, `**Tokens**`, optional `**Cost**`. | `formatSessionInfo` | MISSING | No current equivalent. |
| 102 | generic prompt-command transcript output title is `Command` and markdown formatted. | `applyClientEvent.prompt_command` | MISSING | No prompt-command rendering in audited current sources. |
| 103 | session change clears transcript, working/queue/completion statuses, all notifications, timers, pending UI work. | `applySessionChanged` | CHANGED(epoch change clears transcript; other clears are not visible in audited current code) | `engine_drain.bumpEpoch`, `view_diff.diff` |
| 104 | session change shows `started new session` or `resumed session`. | `applySessionChanged` | MISSING | No current notice/status in audited sources. |
| 105 | snapshot clears transcript, replays history, updates chrome, then queue counts. | `applySnapshot` | CHANGED(new ViewModel sampling/diff replaces snapshot replay path) | `view_diff.diff` |
| 106 | compaction-start status text is `compacting context`. | `applyClientEvent.compaction_start` | CHANGED(current text is `compacting`) | `engine_drain.compactionStart`, `view_diff.emitOperation` |
| 107 | compaction summary transcript item title is `Context Compacted ({reason}, {tokens_before} tokens before)` with markdown summary. | `appendCompactionTranscriptItem` | MISSING | `view_diff` can render `.compaction_summary` as title `compaction`, but `engine_drain.compactionEnd` never creates it. |
| 108 | compaction end error message is a warning status and working status returns/clears based on retry/active operation. | `applyCompactionEnd` | CHANGED(current aborted compaction pushes generic warning notice only) | `engine_drain.compactionEnd` |
| 109 | operation finish clears working status for completed/failed/canceled. | `applyOperationFinished` | CHANGED(op phase drives status; no direct finish reason copy) | `engine_drain.operationIdle`, `view_diff.emitOperation` |
| 110 | canceled operation marks pending tools canceled. | `applyOperationFinished` | CHANGED(restored only when model marks items canceled) | `engine_drain.cancelStreaming`, `view_diff.diffExistingItem` |
| 111 | clipboard image paste inserts composer marker `@{path}`. | `finishReadyFrontendTask` | MISSING | No paste-marker command in audited current sources. |
| 112 | OSC52 fallback copy path reports `selection copied via terminal clipboard`. | `finishReadyFrontendTask` | MISSING | No copy-selection rendering in audited current sources. |
| 113 | custom transcript appends are bounded and can carry caller-provided title/markdown format. | `appendCustom` | CHANGED(current item kinds use fixed titles: `notice`, `compaction`, or status) | `view_diff.appendCommandForItem` |

## Summary

| Status | Count |
|---|---:|
| RESTORED | 19 |
| MISSING | 63 |
| CHANGED | 29 |
| OBSOLETE | 2 |
| TOTAL | 113 |

## Top 10 most user-visible MISSING items

1. Formatted tool titles (`$ command`, `read path:lines`, `edit/write path`) are gone; tools show raw names.
2. Read body cleanup is gone; continuation/truncation text can remain in the body even when footer metadata exists.
3. Successful write-result hiding is gone; write previews no longer reliably remain as the visible body.
4. History paging/tail notice (`new output below; ctrl+end reloads tail`) is gone.
5. `/session` transcript output (`Session Info` with messages/tokens/cost) is gone.
6. Compaction summary transcript item (`Context Compacted (...)`) is not produced.
7. Operational failure fallback copy/semantic annote/TTL table is absent from audited current sources.
8. Session change notices (`started new session` / `resumed session`) are gone.
9. Live tool-output normalization (remove `\r`, expand tabs) is gone.
10. Old presentation queue reveal cadences/coalescing/bounds/drop notice are gone.
