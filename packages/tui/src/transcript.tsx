import type { BoxRenderable, ScrollBoxRenderable } from "@opentui/core"
import { useKeyboard, useRenderer, useSelectionHandler } from "@opentui/react"
import type { AgentMessage } from "@openzi/coding-agent"
import { useCallback, useLayoutEffect, useReducer, useRef } from "react"

import { MessageView, type ToolCallPresentation, ToolResultView } from "./message.js"
import { useSessionView } from "./session-context.js"
import { useTheme } from "./theme.js"
import { ActiveToolView } from "./tool-block.js"
import { initialTranscriptNavigation, transitionTranscriptNavigation } from "./transcript-navigation.js"

// Pi messages and provider content blocks are ordered but do not have stable IDs.
/* oxlint-disable react/no-array-index-key */

interface PendingNativeRead {
  target: ScrollBoxRenderable
  manualGeneration?: number
  resize: boolean
}

const unseenHint = "New output · Ctrl+End to jump"

export function Transcript() {
  const { session, activeTools, transcriptRevision } = useSessionView()
  const [navigation, dispatchNavigation] = useReducer(transitionTranscriptNavigation, initialTranscriptNavigation)
  const renderer = useRenderer()
  const regionRef = useRef<BoxRenderable | null>(null)
  const scrollRef = useRef<ScrollBoxRenderable | null>(null)
  const statusRef = useRef<BoxRenderable | null>(null)
  const operationGeneration = useRef(0)
  const pendingNativeRead = useRef<PendingNativeRead | null>(null)
  const observedTranscriptRevision = useRef(transcriptRevision)
  const theme = useTheme()
  const toolCalls = collectToolCalls(session.messages, session.streamingMessage)

  const setScrollRef = useCallback((next: ScrollBoxRenderable | null) => {
    if (scrollRef.current === next) return
    operationGeneration.current++
    scrollRef.current = next
  }, [])

  const queueNativeRead = useCallback((kind: "manual" | "resize") => {
    const target = scrollRef.current
    if (!target || target.isDestroyed) return

    let pending = pendingNativeRead.current
    if (!pending || pending.target !== target) {
      const queued: PendingNativeRead = { target, resize: false }
      pending = queued
      pendingNativeRead.current = queued
      queueMicrotask(() => {
        if (pendingNativeRead.current === queued) pendingNativeRead.current = null
        if (scrollRef.current !== queued.target || queued.target.isDestroyed) return

        if (queued.manualGeneration !== undefined && queued.manualGeneration === operationGeneration.current) {
          dispatchNavigation({ type: "MANUAL_POSITION_CHANGED", atTail: isAtTail(queued.target) })
        }
        if (queued.resize) {
          dispatchNavigation({
            type: "RESIZE_SETTLED",
            contentFits: queued.target.scrollHeight <= queued.target.viewport.height
          })
        }
      })
    }

    if (kind === "manual") pending.manualGeneration = ++operationGeneration.current
    else pending.resize = true
  }, [])

  const manualScroll = (delta: number, unit: "absolute" | "viewport") => {
    const target = scrollRef.current
    if (!target || target.isDestroyed) return

    operationGeneration.current++
    target.scrollBy(delta, unit)
    if (scrollRef.current !== target || target.isDestroyed) return
    dispatchNavigation({ type: "MANUAL_POSITION_CHANGED", atTail: isAtTail(target) })
  }

  const jumpToTail = () => {
    const target = scrollRef.current
    if (!target || target.isDestroyed) return

    const generation = ++operationGeneration.current
    dispatchNavigation({ type: "JUMP_TO_TAIL" })
    queueMicrotask(() => {
      if (operationGeneration.current !== generation || scrollRef.current !== target || target.isDestroyed) {
        return
      }
      target.scrollTo(target.scrollHeight)
    })
  }

  useKeyboard(key => {
    const noModifiers = !key.shift && !key.ctrl && !key.meta && !key.super && !key.hyper
    if (key.name === "pageup" && noModifiers) {
      key.preventDefault()
      key.stopPropagation()
      manualScroll(-0.5, "viewport")
      return
    }
    if (key.name === "pagedown" && noModifiers) {
      key.preventDefault()
      key.stopPropagation()
      manualScroll(0.5, "viewport")
      return
    }

    const lineCommand = key.ctrl && key.meta && !key.shift && !key.super && !key.hyper
    if (key.name === "up" && lineCommand) {
      key.preventDefault()
      key.stopPropagation()
      manualScroll(-1, "absolute")
      return
    }
    if (key.name === "down" && lineCommand) {
      key.preventDefault()
      key.stopPropagation()
      manualScroll(1, "absolute")
      return
    }

    if (key.name === "end" && key.ctrl && !key.meta && !key.shift && !key.super && !key.hyper) {
      key.preventDefault()
      key.stopPropagation()
      jumpToTail()
    }
  })

  useSelectionHandler(() => queueNativeRead("manual"))

  const detachForSelection = () => {
    operationGeneration.current++
    dispatchNavigation({ type: "SELECTION_DRAG_STARTED" })
  }

  useLayoutEffect(() => {
    if (observedTranscriptRevision.current === transcriptRevision) return
    observedTranscriptRevision.current = transcriptRevision
    if (navigation.type === "detached") dispatchNavigation({ type: "OUTPUT_COMMITTED" })
  }, [navigation.type, transcriptRevision])

  const unseenOutput = navigation.type === "detached" && navigation.unseenOutput

  const syncUnseenHintVisibility = () => {
    const region = regionRef.current
    const status = statusRef.current
    if (!region || region.isDestroyed || !status || status.isDestroyed) return
    status.visible = region.height > 1
  }

  return (
    <box
      id="transcript-region"
      ref={regionRef}
      position="relative"
      flexGrow={1}
      minHeight={1}
      onSizeChange={syncUnseenHintVisibility}>
      <scrollbox
        id="transcript-scroll"
        ref={setScrollRef}
        flexGrow={1}
        minHeight={1}
        focusable={false}
        stickyScroll={navigation.type === "following"}
        stickyStart="bottom"
        viewportCulling
        scrollbarOptions={{ visible: false }}
        onMouseScroll={() => queueNativeRead("manual")}
        onMouseDown={() => {
          if (renderer.getSelection()?.isDragging) detachForSelection()
        }}
        onMouseDrag={detachForSelection}
        onSizeChange={() => {
          if (navigation.type === "detached") queueNativeRead("resize")
        }}>
        {session.messages.map((message, index) => (
          <TranscriptMessage
            key={`${message.role}-${message.timestamp}-${index}`}
            message={message}
            toolCalls={toolCalls}
          />
        ))}
        {session.streamingMessage ? <MessageView message={session.streamingMessage} /> : null}
        {activeTools.map(tool => (
          <ActiveToolView key={tool.id} tool={tool} />
        ))}
      </scrollbox>
      {unseenOutput ? (
        <box
          id="transcript-status"
          ref={statusRef}
          position="absolute"
          left={0}
          right={0}
          bottom={0}
          zIndex={1}
          height={1}
          visible={(regionRef.current?.height ?? 0) > 1}
          paddingLeft={1}
          backgroundColor={theme.surface.app}
          onMouseScroll={event => {
            const scroll = scrollRef.current
            if (scroll && !scroll.isDestroyed) scroll.processMouseEvent(event)
          }}>
          <text selectable={false} fg={theme.text.accent} bg={theme.surface.app} wrapMode="none" content={unseenHint} />
        </box>
      ) : null}
    </box>
  )
}

function isAtTail(scroll: ScrollBoxRenderable): boolean {
  const maximum = Math.max(0, scroll.scrollHeight - scroll.viewport.height)
  return maximum <= 1 || scroll.scrollTop >= maximum
}

function TranscriptMessage({
  message,
  toolCalls
}: {
  message: AgentMessage
  toolCalls: ReadonlyMap<string, ToolCallPresentation>
}) {
  return message.role === "toolResult" ? (
    <ToolResultView message={message} call={toolCalls.get(message.toolCallId)} />
  ) : (
    <MessageView message={message} />
  )
}

function collectToolCalls(
  messages: readonly AgentMessage[],
  streamingMessage: AgentMessage | undefined
): ReadonlyMap<string, ToolCallPresentation> {
  const calls = new Map<string, ToolCallPresentation>()
  for (const message of messages) collectAssistantToolCalls(calls, message)
  if (streamingMessage) collectAssistantToolCalls(calls, streamingMessage)
  return calls
}

function collectAssistantToolCalls(calls: Map<string, ToolCallPresentation>, message: AgentMessage): void {
  if (message.role !== "assistant") return
  for (const part of message.content) {
    if (part.type === "toolCall") calls.set(part.id, { name: part.name, args: part.arguments })
  }
}
