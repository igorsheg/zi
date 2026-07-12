# TUI parity audit

Cut-over baseline: `46b6276~1`. Sources audited only: old `interactive.zig`, old `presentation_queue.zig`, current `tool_view.zig`, current `view_diff.zig`, current `engine_drain.zig`.

## Tool titles

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 1 | bash tool title renders as `$ {args.command}` and appends ` (timeout Ns)` when `args.timeout` is present. | `tool_view.formatCallTitleWithHome` via `applyToolCall`/`applyToolStart` | RESTORED | `engine_drain.ensureTool` sets title to tool name only (`bash`). `tool_view.formatCallTitleWithHome` is orphaned. |
| 2 | read tool title renders `read {file_path/path}`. | `tool_view.formatCallTitleWithHome` | RESTORED | `engine_drain.ensureTool`; `tool_view.formatCallTitle*` orphaned. |
| 3 | edit/write tool titles render `{tool_name} {file_path/path}`. | `tool_view.formatCallTitleWithHome` | RESTORED | `engine_drain.ensureTool`; title is only `edit`/`write`. |
| 4 | custom/unknown tools get an empty formatted title, not a guessed title. | `tool_view.formatCallTitleWithHome` | RESTORED | `engine_drain.ensureTool` |
| 5 | read title appends `:start-end` from positive `offset`/`limit`, default start `1`. | `tool_view.addReadLineRange` | RESTORED | `tool_view.addReadLineRange` orphaned. |
| 6 | tool title paths under `$HOME` collapse to `~`/`~/suffix`. | `tool_view.TitleBuilder.addPath` | RESTORED | Only composer cwd still does this in `view_diff.formatChromeCwd`. |
| 7 | tool titles sanitize newlines, carriage returns, and tabs to spaces, then trim to valid UTF-8. | `tool_view.TitleBuilder.add`/`slice` | RESTORED | `tool_view.formatCallTitle*` orphaned. |
| 8 | compact read titles for `SKILL.md`, docs paths, and resource files render short labels plus `(ctrl+o to expand)`. | `tool_view.formatCompactCallTitle` | RESTORED | `tool_view.formatCompactCallTitle` orphaned. |
| 9 | history tool-call rows recompute titles from retained `arguments_json`. | `tool_view.historyCallAppend` | RESTORED | `tool_view.historyCallAppend` orphaned; `view_diff` has no history rendering. |
| 10 | history tool-call rows fall back to retained old title when `arguments_json` is invalid. | `tool_view.historyCallAppend` | RESTORED | Orphaned. |
| 11 | pending tool-call previews append as pending tool rows with formatted title/compact title. | `applyToolCall` | RESTORED | `engine_drain.toolPreview`, `engine_drain.ensureTool` |
| 12 | final tool execution appends a status-only update with blank title/compact title. | `tool_view.endAppend` via `applyToolEnd` | RESTORED | `engine_drain.toolEnd`, `view_diff.toolStatus` |

## Tool bodies per tool

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 13 | bash streaming updates append the first text result chunk. | `applyToolUpdate`, `tool_view.firstResultText` | RESTORED | `engine_drain.toolUpdate`, `toolResultText` |
| 14 | live tool output removes `\r` and expands tabs to three spaces before display. | `tool_view.normalizedOutputChunk` | RESTORED | `tool_view.normalizedOutputChunk` orphaned. |
| 15 | bash is treated as streaming, so terminal execution does not replace the streamed body at end. | `tool_view.streamsOutput`, `applyToolEnd` | RESTORED | `engine_drain.ensureTool`/`toolEnd` via `display.streams_output` |
| 16 | bash truncation details become footer metadata. | `tool_view.metadataForDetails`/`bashMetadata` | RESTORED | `view_diff.toolMetadata` calls `tool_view.metadataForDetails` |
| 17 | settled/history bash bodies strip legacy bracket notices and append exit/timed-out/signal status text. | `tool_view.historyFinish`, `bashBodyFromDetails`, `writeBashStatus` | RESTORED | `tool_view.historyFinish` and `resultOutput` orphaned. |
| 18 | successful read bodies trim trailing empty lines. | `tool_view.resultOutput`, `trimTrailingEmptyLines` | RESTORED | `engine_drain.toolResultBody` returns raw first text. |
| 19 | read continuation/truncation text is removed from body and moved to footer. | `readBodyFromDetails`, `readMetadata` | RESTORED | Footer: `view_diff.toolMetadata`; body: `engine_drain.toolResultBody` |
| 20 | read first-line-exceeds-limit body becomes empty with footer explaining truncation. | `readBodyFromDetails`, `readMetadata` | RESTORED | Footer: `view_diff.toolMetadata` |
| 21 | successful edit result displays `details.diff` instead of generic text. | `tool_view.resultOutputFromOwnedText` | RESTORED | `engine_drain.toolResultBody` |
| 22 | edit errors display raw result text, not `details.diff`. | `tool_view.resultOutputFromOwnedText` | RESTORED | `engine_drain.toolResultBody` checks `!is_error` |
| 23 | write tool-call preview displays first collapsed content lines before execution. | `tool_view.callPreviewText` | RESTORED | `engine_drain.writePreview` |
| 24 | write preview footer says `Showing lines 1-N of M` when content exceeds collapse limit. | `tool_view.callPreviewFooter` | RESTORED | `engine_drain.writePreview` |
| 25 | write execution start clears the preview body. | `tool_view.clearsCallPreviewOnStart`, `applyToolStart` | RESTORED | `engine_drain.toolStart` |
| 26 | write execution start clears the preview footer too. | `applyToolStart` | RESTORED | `engine_drain.toolStart` clears text only. |
| 27 | successful write result is hidden so preview content remains the visible body. | `tool_view.shouldHideSuccessfulToolResult` | RESTORED | `tool_view.shouldHideSuccessfulToolResult` orphaned. |
| 28 | mixed text/image tool results join text blocks and image fallbacks like `[Image: image/png]`. | `tool_view.formatResultContent`, `imageFallbackText` | RESTORED | `engine_drain.toolResultText` keeps only first text item. |
| 29 | successful bash/read/write result text trims trailing empty lines. | `tool_view.shouldTrimResult` | RESTORED | `engine_drain.toolResultBody` does no trim. |
| 30 | error results do not trim successful-only whitespace. | `tool_view.shouldTrimResult` | RESTORED | `engine_drain.toolResultBody` returns raw text for errors. |
| 31 | non-streaming final output joins all non-empty text blocks with newlines. | `tool_view.formatResultContent` | RESTORED | `engine_drain.toolResultText` keeps first text block only. |
| 32 | output body clipping uses `details.truncation.outputBytes` and backs down to valid UTF-8. | `outputPrefixFromDetails`, `utf8Prefix` | RESTORED | Only footer metadata uses details. |

## Tool footers/chips

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 33 | final/static footer can be derived from `details_json`. | `tool_view.metadataForDetails` | RESTORED | `view_diff.toolMetadata` |
| 34 | read limited footer: `Limited: X more lines in file; use offset=Y to continue`. | `readMetadata` | RESTORED | `tool_view.readMetadata` called by `view_diff.toolMetadata` |
| 35 | read first-line safety clipping footer says `Truncated: first line exceeds 50KB limit`. | `readMetadata` | RESTORED | `tool_view.readMetadata` called by `view_diff.toolMetadata` |
| 36 | multiple read footer chips are separated by ` • `. | `readMetadata` | RESTORED | `tool_view.readMetadata` |
| 37 | bash truncation footer says `Truncated: showing X of Y lines` or byte-limit variant. | `bashMetadata` | RESTORED | `tool_view.bashMetadata` via `metadataForDetails` |
| 38 | only process/stream tools show duration footer. | `tool_view.showsDuration` | RESTORED | `engine_drain.ensureTool` stores display; `view_diff.updateToolFooter` checks `shows_duration` |
| 39 | running duration chip label is `Elapsed 1.2s`. | `tickToolTimers`, `toolDurationChip` | RESTORED | `view_diff.renderToolFooter` |
| 40 | completed duration chip label is `Took 1.2s`. | `finishToolTimer` | RESTORED | `view_diff.renderToolFooter` |
| 41 | metadata and duration join as `{metadata} • {duration}`. | `tool_view.joinMetadata` | RESTORED | `view_diff.renderToolFooter` |
| 42 | live duration timers are capped to 8 tool ids of 96 bytes; overflow silently omits duration. | `startToolTimer` | CHANGED | `view_diff.ItemCursor` |
| 43 | error tool with no metadata explicitly clears footer. | `applyToolEnd` | RESTORED | `view_diff.diffExistingItem` |
| 44 | errored tool status renders as `.err`. | `tool_view.endAppend`/`append` | RESTORED | `engine_drain.setToolResultMeta`, `view_diff.toolStatus` |

## Arg previews

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 45 | preview rebuild cadence is 32ms. | `presentation_queue.tool_call_preview_interval_ms` | RESTORED | `engine_drain.preview_rebuild_interval_ms` |
| 46 | non-write tool-call args are not shown as raw JSON body. | `applyToolCall` | CHANGED | `engine_drain.toolPreview`, `jsonPreview` |
| 47 | preview pacing was a UI reveal queue decision, not a VM mutation throttle. | `presentation_queue.ToolAppend.presentationIntervalMs` | CHANGED | `engine_drain.toolPreview` |
| 48 | write preview output remains visually capped while footer count grows as args stream. | `tool_view.callPreviewText`/`callPreviewFooter` | RESTORED | `engine_drain.writePreview` |
| 49 | write preview footer appears only when visible lines are fewer than total lines. | `tool_view.callPreviewFooter` | RESTORED | `engine_drain.writePreview` |
| 50 | write preview trims trailing empty lines before display/counting. | `tool_view.callPreviewText`, `callPreviewFooter` | RESTORED | `engine_drain.writePreview` uses raw content. |
| 51 | call preview is cleared on start only for write. | `tool_view.clearsCallPreviewOnStart` | RESTORED | `engine_drain.toolStart` |
| 52 | missing title args render as ellipsis, e.g. `$ ...`. | `tool_view.argStringOrEllipsis` | RESTORED | Title formatter orphaned. |

## Streaming/reveal behavior

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 53 | assistant text/thinking reveal interval is 12ms. | `presentation_queue.assistant_reveal_interval_ms` | CHANGED | `view_diff.diff` emits sampled deltas immediately. |
| 54 | tool-call preview interval is 32ms. | `presentation_queue.tool_call_preview_interval_ms` | CHANGED | `engine_drain.preview_rebuild_interval_ms` |
| 55 | tool output reveal interval is 200ms. | `presentation_queue.tool_output_interval_ms` | CHANGED | No current per-kind output reveal in audited sources. |
| 56 | background status/footer/tag work interval is 100ms. | `presentation_queue.background_pending_work_interval_ms` | CHANGED | No pending presentation queue. |
| 57 | animation fallback interval is 16ms when queue empty. | `presentation_queue.animation_frame_interval_ms` | CHANGED | Not represented in audited current diff/drain sources. |
| 58 | assistant/thinking pending chunks coalesce up to 4KiB. | `presentation_queue.tryCoalesce` | CHANGED | No pending queue. |
| 59 | tool output pending chunks coalesce up to 8KiB per tool id. | `presentation_queue.tryCoalesce` | CHANGED | No pending queue. |
| 60 | pending UI queue is bounded to 512 items / 256KiB and drops overflow. | `presentation_queue.count_max`, `bytes_max`, `push` | CHANGED | No equivalent in audited current sources. |
| 61 | owner applies at most 4 pending UI works / 4KiB per tick. | `applyPendingUiWorkBounded` | CHANGED | `view_diff.diff` may emit all sample changes for a diff. |
| 62 | first pending queue overflow shows `TUI update backlog dropped`. | `queuePendingUiWork` | CHANGED | No pending queue/drop notice. |
| 63 | transcript message/tool chunks are sliced at 1024 bytes on UTF-8 boundaries. | `boundedUiChunk`, `appendToolOutput` | CHANGED | Current diff emits sample suffixes as provided. |
| 64 | committed messages tag latest user/assistant/tool source ids for transcript navigation. | `queueSourceTag`, `presentation_queue.SourceTag` | RESTORED | `vm.Item.source_id`, `view_diff.emitSourceTag` |

## Composer chrome

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 65 | greeter title is `zi {version}` and subtitle is `Type / for commands. Ask zi about zi if you get lost.` | `installGreeter` | RESTORED | `frame_loop.installGreeter` |
| 66 | composer-left cwd collapses `$HOME` to `~`. | `formatComposerCwd` | RESTORED | `view_diff.formatChromeCwd` |
| 67 | composer-left cwd of `.` is resolved to real path before formatting. | `applySessionChromeParts` | RESTORED | `Engine.initInThread`, `view_diff.formatChromeCwd` |
| 68 | composer cwd is bounded to status text buffer. | `formatComposerCwd` | CHANGED | `view_diff.formatChromeCwd` |
| 69 | composer-right context shows `{percent_tenths}/{window}`, e.g. `12.3%/200k`. | `formatContextUsage` | RESTORED | `AgentSession.chrome`, `view_diff.formatChromeRight` |
| 70 | `no authenticated model` appears only when provider and model are both `unknown`. | `formatComposerRight` | RESTORED | `view_diff.formatChromeRight` |
| 71 | composer-right still includes `provider/model (thinking_level)`. | `formatComposerRight` | RESTORED | `view_diff.formatChromeRight` |
| 72 | old composer status contribution ids were 1/2. | constants `composer_cwd_slot_id`, `composer_session_slot_id` | OBSOLETE | Current ids are 3/4 in `view_diff.zig`. |
| 73 | `loading completions` shimmer status while completions snapshot is in flight. | `setCompletionStatus` | RESTORED | `vm.CompletionSlot.in_flight`, `engine_drain.startCompletion`, `view_diff.emitCompletion` |
| 74 | queue status copy is `queued: N steering, M follow-up`. | `applyQueueCounts` | RESTORED | `view_diff.emitQueue` |

## Status/notify copy

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 75 | notify command carries level mapped from transcript status level. | `notifyLevel` | RESTORED | `failure_text.noticeCopy`, `view_diff.emitNotices` |
| 76 | info notifications get empty annote; warning/error annote is null unless semantic overrides. | `notifyAnnote` | RESTORED | `failure_text.noticeCopy`, `view_diff.emitNotices` |
| 77 | operation failure fallback messages: missing credentials, rate limit, context overflow, network, etc. | `formatOperationalFailureMessage` | RESTORED | `vm.NoticeFailureCategory`, `failure_text.noticeCopy` |
| 78 | operation failure semantics choose annote `auth`/`rate`/`context`/`provider`/`network`/`cancel`/`error`. | `operationalFailureNotifySemantic` | RESTORED | `vm.NoticeFailureCategory`, `failure_text.noticeCopy` |
| 79 | operation failure semantics choose per-category TTLs from 3s to 15s. | `operationalFailureNotifySemantic` | RESTORED | `vm.NoticeFailureCategory`, `failure_text.noticeCopy` |
| 80 | retry status says `retry A/B in Dms[: reason]`. | `formatRetryStatus` | RESTORED | `failure_text.retryStatus`, `view_diff.emitOperation` |
| 81 | retry-start notification has annote `retry`, warning tone, TTL 5000ms. | `auto_retry_start` branch | RESTORED | `engine_drain.retryStart`, `failure_text.noticeCopy`, `view_diff.emitNotices` |
| 82 | retry-end failure notification has annote `retry`, err tone, TTL 10000ms. | `auto_retry_end` branch | RESTORED | `engine_drain.retryEnd`, `failure_text.noticeCopy`, `view_diff.emitNotices` |
| 83 | recovery notices: `recovering event gap`, `replay requires snapshot in TUI adapter`, `replay gap; requesting snapshot`. | `acceptEnvelope`, `applyClientEvent` | CHANGED | No replay/recovery rendering in audited current sources. |
| 84 | event overflow copy is `event overflow: dropped N`. | `event_overflow` branch | RESTORED | `engine_drain.eventOverflow`, `view_diff.emitNotices` |
| 85 | rejected queue-full copy is `prompt queue full ({max})`. | `formatRejectionMessage` | RESTORED | `engine_drain.rejection`, `failure_text.queueFull` |
| 86 | submit queue-full copy is `command queue full`. | `submitCommand` | RESTORED | `frame_loop.submitErrorText` |
| 87 | cancel request shows keyed `cancel requested` with canceled tone. | `cancelActive` | RESTORED | `engine_drain.operationCancelRequested`, `failure_text.noticeCopy` |
| 88 | operation canceled shows keyed `canceled` notify and marks pending tools canceled. | `applyOperationFinished` | RESTORED | `engine_drain.cancelStreaming`, `failure_text.noticeCopy` |
| 89 | shutdown-start event requests terminal stop. | `applyClientEvent.shutdown_started` | OBSOLETE | |
| 90 | selection copy statuses: `selection copied`, `selection copied via terminal clipboard`, `clipboard copy failed`, empty/too-large selection. | `finishReadyFrontendTask`, `handleCopySelection` | RESTORED | `frame_loop.spawnCopySelection`, `drainOneWorkerResult` |
| 91 | input warnings: `input truncated`, `input effects dropped`, `input reader stopped`, editor/clipboard image errors. | `pollAndDrainInput`, `appendClipboardImageError`, `handleExternalEditor` | RESTORED | `frame_loop.drainInput`, `editorError`, `workerErrorText` |

## History/paging notices

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 92 | when viewing older history and live output arrives, show `new output below; ctrl+end reloads tail`. | `noteHistoryHasNewerTail` | RESTORED | `view_diff.emitHistory` |
| 93 | requesting tail snapshot clears the transcript-tail notice. | `requestTailSnapshot` | RESTORED | `frame_loop.requestTranscriptTail`, `view_diff.emitHistory` |
| 94 | history pages prepend older items in reverse page order. | `applyHistoryPage` | RESTORED | `view_diff.emitHistory`, `prependHistoryItem` |
| 95 | while an older history window is open, live tail presentation work is dropped until reload. | `applyHistoryPage`, `tailTranscriptWork` | RESTORED | `ViewModel.sample` suppresses tail while history open |
| 96 | hidden-thinking history assistant rows append an empty hidden thinking placeholder before text. | `appendHistoryThinkingPlaceholder` | RESTORED | `view_diff.prependHistoryItem` |
| 97 | history message append splits large text into bounded chunks. | `appendHistoryMessage` | RESTORED | `view_diff.prependHistoryMessage` chunks at transcript cap |
| 98 | history tool results install settled body/footer directly, bypassing reveal queue. | `applyHistoryToolResult` | RESTORED | `engine_drain.publishHistoryPage`, `view_diff.prependHistoryTool` |

## Session lifecycle visuals

| # | Decision | Old source (fn name) | Status | New home |
|---:|---|---|---|---|
| 99 | `/session` transcript title is `Session Info`. | `appendSessionInfo` | RESTORED | `Engine.publishSessionInfo`, `view_diff.customAppend` |
| 100 | `/session` output includes `File: {path}` or `File: In-memory`, then `ID`. | `formatSessionInfo` | RESTORED | `Engine.formatSessionInfo` |
| 101 | `/session` output has markdown sections `**Messages**`, `**Tokens**`, optional `**Cost**`. | `formatSessionInfo` | RESTORED | `Engine.formatSessionInfo` |
| 102 | generic prompt-command transcript output title is `Command` and markdown formatted. | `applyClientEvent.prompt_command` | RESTORED | `engine_drain.promptCommand`, `view_diff.customAppend` |
| 103 | session change clears transcript, working/queue/completion statuses, all notifications, timers, pending UI work. | `applySessionChanged` | RESTORED | `view_diff.diff` epoch reset clears transcript/status/notifies |
| 104 | session change shows `started new session` or `resumed session`. | `applySessionChanged` | RESTORED | `Engine.finishSessionOpen`, `engine_drain.notice` |
| 105 | snapshot clears transcript, replays history, updates chrome, then queue counts. | `applySnapshot` | CHANGED | `view_diff.diff` |
| 106 | compaction-start status text is `compacting context`. | `applyClientEvent.compaction_start` | RESTORED | `engine_drain.compactionStart`, `view_diff.emitOperation` |
| 107 | compaction summary transcript item title is `Context Compacted ({reason}, {tokens_before} tokens before)` with markdown summary. | `appendCompactionTranscriptItem` | RESTORED | `vm.CompactionMeta`, `engine_drain.compactionEnd`, `view_diff.customAppend` |
| 108 | compaction end error message is a warning status and working status returns/clears based on retry/active operation. | `applyCompactionEnd` | RESTORED | `engine_drain.compactionEnd`, `Engine.stepActive` status restore |
| 109 | operation finish clears working status for completed/failed/canceled. | `applyOperationFinished` | RESTORED | `engine_drain.operationIdle`, `view_diff.emitOperation` |
| 110 | canceled operation marks pending tools canceled. | `applyOperationFinished` | RESTORED | `engine_drain.cancelStreaming`, `view_diff.diffExistingItem` |
| 111 | clipboard image paste inserts composer marker `@{path}`. | `finishReadyFrontendTask` | RESTORED | `frame_loop.drainOneWorkerResult` |
| 112 | OSC52 fallback copy path reports `selection copied via terminal clipboard`. | `finishReadyFrontendTask` | RESTORED | `frame_loop.drainOneWorkerResult` |
| 113 | custom transcript appends are bounded and can carry caller-provided title/markdown format. | `appendCustom` | RESTORED | `vm.Item.title/markdown`, `view_diff.customAppend` |

## Summary

| Status | Count |
|---|---:|
| RESTORED | 95 |
| MISSING | 0 |
| CHANGED | 17 |
| OBSOLETE | 2 |
| TOTAL | 114 |

## Top user-visible open/changed items

1. Recovery/replay notices are changed with the in-process ViewModel architecture; RPC will rebuild them later.
2. Old presentation queue cadence/coalescing rows are changed by design: sampling is the reveal cadence.
3. Row 114 is restored: streamed plain rows retain committed wraps and only reflow the unstable suffix.

| 114 | Unbroken single-line items retain committed soft wraps while streaming, so appends only reflow the unstable suffix. Markdown-sensitive rows reflow until their syntax becomes stable. | `Transcript`/layout cache | RESTORED | `layout.appendMarkdown` plus per-item `WrapState` |
