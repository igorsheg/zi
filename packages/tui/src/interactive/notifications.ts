import { BoxRenderable, CliRenderEvents, fg, StyledText, TextRenderable, type CliRenderer } from "@opentui/core"

import { textWidth, truncateToCells } from "../components/cell-text.js"
import type { Theme } from "../theme.js"

export type NotificationKey = string | number
export type NotificationLevel = number | string
export type NotificationData =
  | null
  | boolean
  | number
  | string
  | readonly NotificationData[]
  | { readonly [key: string]: NotificationData }

export interface NotificationOptions {
  readonly key?: NotificationKey
  readonly group?: NotificationKey
  readonly annote?: string | null
  readonly hidden?: boolean
  readonly ttl?: number
  readonly update_only?: boolean
  readonly skip_history?: boolean
  readonly data?: NotificationData
}

export interface NotificationGroupConfig {
  readonly name?: string | false
  readonly icon?: string | false
  readonly icon_on_left?: boolean
  readonly annote_separator?: string
  readonly ttl?: number
  readonly render_limit?: number
  readonly priority?: number
  readonly skip_history?: boolean
  readonly debug_annote?: string
  readonly info_annote?: string
  readonly warn_annote?: string
  readonly error_annote?: string
}

export interface NotificationHistoryFilter {
  readonly group_key?: NotificationKey
  readonly before?: number
  readonly since?: number
  readonly include_removed?: boolean
  readonly include_active?: boolean
}

export interface NotificationHistoryItem {
  readonly key?: NotificationKey
  readonly group_key: NotificationKey
  readonly group_name?: string
  readonly group_icon?: string
  readonly message: string
  readonly annote?: string
  readonly level?: NotificationLevel
  readonly hidden: boolean
  readonly expires_at: number | null
  readonly last_updated: number
  readonly skip_history: boolean
  readonly data?: NotificationData
  readonly removed: boolean
}

interface ActiveNotification {
  readonly id: number
  readonly key?: NotificationKey
  readonly groupKey: NotificationKey
  message: string
  annote?: string
  level?: NotificationLevel
  hidden: boolean
  expiresAt: number | null
  lastUpdated: number
  skipHistory: boolean
  data?: NotificationData
}

interface NotificationGroup {
  readonly key: NotificationKey
  readonly created: number
  readonly items: ActiveNotification[]
  config: Required<Pick<NotificationGroupConfig, "ttl" | "priority">> & NotificationGroupConfig
}

interface NotificationGroupClaim {
  readonly token: symbol
  readonly capacity: number
}

type ClockState = { readonly type: "idle" } | { readonly type: "live" }

interface RenderLine {
  readonly chunks: readonly RenderChunk[]
  readonly width: number
}

interface RenderChunk {
  readonly text: string
  readonly color: string
}

export interface NotificationCenterOptions {
  readonly filter?: number
  readonly history_size?: number
  readonly max_active?: number
  readonly max_visible?: number
  readonly max_visible_lines?: number
}

type NotificationCenterOwnerOptions = NotificationCenterOptions & { readonly now?: () => number }

export interface NotificationAPI {
  notify(msg: string | null | undefined, level?: NotificationLevel | null, opts?: NotificationOptions): void
  close(): boolean
  clear(groupKey?: NotificationKey): void
  clear_history(filter?: NotificationHistoryFilter | NotificationKey): void
  reset(): void
  set_config(key: NotificationKey, config: NotificationGroupConfig | null, overwrite?: boolean): void
  suppress(suppress?: boolean): void
  remove(groupKey: NotificationKey, itemKey: NotificationKey): boolean
  get_history(filter?: NotificationHistoryFilter | NotificationKey): readonly NotificationHistoryItem[]
  group_keys(): readonly NotificationKey[]
}

export interface NotificationGroupProducer {
  notify(
    key: NotificationKey,
    msg: string | null | undefined,
    level?: NotificationLevel | null,
    opts?: Omit<NotificationOptions, "key" | "group">
  ): void
  remove(key: NotificationKey): boolean
  dispose(): void
}

export const defaultNotificationTtlSeconds = 5
export const maxNotificationMessageBytes = 16 * 1024
export const maxNotificationDataBytes = 16 * 1024
export const maxNotificationDataDepth = 32
export const maxNotificationDataNodes = 4_096
export const maxNotificationAnnoteBytes = 1024
export const maxNotificationActive = 128
export const maxNotificationRetainedActive = maxNotificationActive * 2
export const maxNotificationHistory = 128
export const maxVisibleNotifications = 32
export const maxVisibleNotificationLines = 64

const defaultGroupKey = "default"
const maxNotificationGroups = 64
const lineMargin = 1

/** Fidget-style notification ownership and layout, adapted from j-hui/fidget.nvim@6f793b2. */
export class NotificationCenter implements NotificationAPI {
  readonly root: BoxRenderable

  readonly #renderer: CliRenderer
  readonly #theme: Theme
  readonly #text: TextRenderable
  readonly #now: () => number
  readonly #filter: number
  readonly #historySize: number
  readonly #maxActive: number
  readonly #maxVisible: number
  readonly #maxVisibleLines: number
  readonly #groups: NotificationGroup[] = []
  readonly #configs = new Map<NotificationKey, NotificationGroupConfig>()
  readonly #claims = new Map<NotificationKey, NotificationGroupClaim>()
  readonly #history: NotificationHistoryItem[] = []
  #host: BoxRenderable | undefined
  #clock: ClockState = { type: "idle" }
  #nextId = 1
  #nextGroup = 1
  #suppressed = false
  #closed = false
  #presentation = ""
  #disposed = false

  constructor(renderer: CliRenderer, theme: Theme, options: NotificationCenterOwnerOptions = {}) {
    const admitted = admitNotificationCenterOptions(options)
    this.#renderer = renderer
    this.#theme = theme
    this.#now = admitted.now
    this.#filter = admitted.filter
    this.#historySize = admitted.historySize
    this.#maxActive = admitted.maxActive
    this.#maxVisible = admitted.maxVisible
    this.#maxVisibleLines = admitted.maxVisibleLines
    this.#configs.set(defaultGroupKey, {})

    this.root = new BoxRenderable(renderer, {
      id: "notifications",
      position: "absolute",
      right: 1,
      bottom: 0,
      zIndex: 5,
      maxWidth: "100%",
      maxHeight: "100%",
      visible: false
    })
    this.#text = new TextRenderable(renderer, {
      id: "notification-surface",
      selectable: false,
      wrapMode: "none",
      truncate: true,
      fg: theme.text.muted,
      content: ""
    })
    this.root.add(this.#text)
    renderer.on(CliRenderEvents.FRAME, this.#onFrame)
    renderer.on(CliRenderEvents.RESIZE, this.#onResize)
  }

  attach(host: BoxRenderable): void {
    this.#assertOpen()
    if (this.#host === host) return
    this.detach()
    this.#host = host
    host.add(this.root)
    this.#render()
  }

  detach(): void {
    if (!this.#host) return
    this.#host.remove(this.root)
    this.#host = undefined
  }

  notify(msg: string | null | undefined, level?: NotificationLevel | null, opts: NotificationOptions = {}): void {
    this.#notify(msg, level, opts)
  }

  claimGroup(key: NotificationKey, config: NotificationGroupConfig, capacity: number): NotificationGroupProducer {
    this.#assertOpen()
    validateDisplayKey(key, "claimed group key")
    validateGroupConfig(config)
    const admittedCapacity = boundedPositiveCount(
      capacity,
      maxNotificationActive,
      maxNotificationActive,
      "producer capacity"
    )
    if (key === defaultGroupKey) throw new Error("The default notification group cannot be claimed")
    if (
      this.#claims.has(key) ||
      this.#groups.some(group => group.key === key) ||
      this.#configs.has(key) ||
      this.#history.some(item => item.group_key === key)
    ) {
      throw new Error(`Notification group ${String(key)} is already in use`)
    }
    if (this.#configs.size >= maxNotificationGroups) {
      throw new Error(`Notification configs cannot exceed ${maxNotificationGroups}`)
    }
    const claimedCapacity = [...this.#claims.values()].reduce((total, claim) => total + claim.capacity, 0)
    if (claimedCapacity + admittedCapacity > maxNotificationActive) {
      throw new Error(`Notification producer capacities cannot exceed ${maxNotificationActive}`)
    }
    const token = Symbol(String(key))
    this.#claims.set(key, { token, capacity: admittedCapacity })
    this.#configs.set(key, Object.freeze({ ...config }))
    let released = false
    return Object.freeze({
      notify: (
        itemKey: NotificationKey,
        msg: string | null | undefined,
        level?: NotificationLevel | null,
        opts: Omit<NotificationOptions, "key" | "group"> = {}
      ) => {
        if (released) throw new Error(`Notification group ${String(key)} producer is disposed`)
        this.#notify(msg, level, { ...opts, key: itemKey, group: key }, token)
      },
      remove: (itemKey: NotificationKey) => {
        if (released) throw new Error(`Notification group ${String(key)} producer is disposed`)
        return this.#remove(key, itemKey, token)
      },
      dispose: () => {
        if (released) return
        released = true
        this.#releaseClaim(key, token)
      }
    })
  }

  close(): boolean {
    this.#assertOpen()
    this.#closed = true
    this.root.visible = false
    return true
  }

  clear(groupKey?: NotificationKey): void {
    this.#assertOpen()
    if (groupKey !== undefined) this.#assertPublicGroup(groupKey)
    const now = this.#now()
    this.#expire(now)
    let changed = false
    for (let groupIndex = this.#groups.length - 1; groupIndex >= 0; groupIndex--) {
      const group = this.#groups[groupIndex]!
      if (this.#claims.has(group.key) || (groupKey !== undefined && group.key !== groupKey)) continue
      for (const item of group.items) this.#archive(group, item, now)
      this.#groups.splice(groupIndex, 1)
      changed = true
    }
    if (changed) this.#closed = false
    this.#finishMutation()
  }

  remove(groupKey: NotificationKey, itemKey: NotificationKey): boolean {
    this.#assertPublicGroup(groupKey)
    return this.#remove(groupKey, itemKey)
  }

  suppress(suppress?: boolean): void {
    this.#assertOpen()
    this.#suppressed = suppress ?? !this.#suppressed
    this.#render()
  }

  reset(): void {
    this.#assertOpen()
    let activeChanged = false
    for (let index = this.#groups.length - 1; index >= 0; index--) {
      if (this.#claims.has(this.#groups[index]!.key)) continue
      this.#groups.splice(index, 1)
      activeChanged = true
    }
    for (let index = this.#history.length - 1; index >= 0; index--) {
      if (this.#claims.has(this.#history[index]!.group_key)) continue
      this.#history.splice(index, 1)
    }
    if (activeChanged) this.#closed = false
    this.#finishMutation()
  }

  set_config(key: NotificationKey, config: NotificationGroupConfig | null, overwrite = false): void {
    this.#assertOpen()
    validateDisplayKey(key, "config key")
    this.#assertPublicGroup(key)
    if (config === null) {
      if (key === defaultGroupKey) throw new Error("The default notification config cannot be removed")
      if (this.#configs.delete(key)) this.#refreshPublicGroupConfigs(key)
      return
    }
    validateGroupConfig(config)
    if (!overwrite && this.#configs.has(key)) return
    if (!this.#configs.has(key) && this.#configs.size >= maxNotificationGroups) {
      throw new Error(`Notification configs cannot exceed ${maxNotificationGroups}`)
    }
    this.#configs.set(key, Object.freeze({ ...config }))
    this.#refreshPublicGroupConfigs(key)
  }

  group_keys(): readonly NotificationKey[] {
    this.#assertOpen()
    this.#expire(this.#now())
    this.#syncClock()
    this.#render()
    return this.#groups.map(group => group.key)
  }

  get_history(filter: NotificationHistoryFilter | NotificationKey = {}): readonly NotificationHistoryItem[] {
    this.#assertOpen()
    const now = this.#now()
    this.#expire(now)
    this.#syncClock()
    this.#render()
    const admitted = typeof filter === "object" ? filter : { group_key: filter }
    validateHistoryFilter(admitted)
    const history: NotificationHistoryItem[] = []
    if (admitted.include_active !== false) {
      for (const group of this.#groups) {
        if (admitted.group_key !== undefined && group.key !== admitted.group_key) continue
        for (const item of group.items) {
          if (!item.skipHistory && matchesHistoryTime(item.lastUpdated, now, admitted)) {
            history.push(this.#historyItem(group, item, false, item.lastUpdated))
          }
        }
      }
    }
    if (admitted.include_removed !== false) {
      for (const item of this.#history) {
        if (admitted.group_key !== undefined && item.group_key !== admitted.group_key) continue
        if (matchesHistoryTime(item.last_updated, now, admitted)) history.push(item)
      }
    }
    return Object.freeze(history)
  }

  clear_history(filter: NotificationHistoryFilter | NotificationKey = {}): void {
    this.#assertOpen()
    const now = this.#now()
    const admitted = typeof filter === "object" ? filter : { group_key: filter }
    validateHistoryFilter(admitted)
    if (admitted.group_key !== undefined) this.#assertPublicGroup(admitted.group_key)
    if (admitted.include_removed === false) return
    for (let index = this.#history.length - 1; index >= 0; index--) {
      const item = this.#history[index]!
      if (this.#claims.has(item.group_key)) continue
      if (admitted.group_key !== undefined && item.group_key !== admitted.group_key) continue
      if (matchesHistoryTime(item.last_updated, now, admitted)) this.#history.splice(index, 1)
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stopClock()
    this.#renderer.off(CliRenderEvents.FRAME, this.#onFrame)
    this.#renderer.off(CliRenderEvents.RESIZE, this.#onResize)
    this.detach()
    this.root.destroyRecursively()
    this.#groups.length = 0
    this.#claims.clear()
    this.#history.length = 0
  }

  #notify(
    msg: string | null | undefined,
    level: NotificationLevel | null | undefined,
    opts: NotificationOptions,
    token?: symbol
  ): void {
    this.#assertOpen()
    validateNotificationInput(msg, level, opts)
    const hasData = Object.hasOwn(opts, "data")
    const admittedData = hasData ? admitNotificationData(opts.data) : undefined
    if (typeof level === "number" && level < this.#filter) return
    const groupKey = opts.group ?? defaultGroupKey
    const claim = this.#claims.get(groupKey)
    if (claim?.token !== token || (!claim && token !== undefined)) {
      if (claim) throw new Error(`Notification group ${String(groupKey)} is producer-owned`)
      throw new Error(`Notification producer no longer owns group ${String(groupKey)}`)
    }

    const now = this.#now()
    this.#expire(now)
    const group = this.#group(groupKey, msg !== null && msg !== undefined && opts.update_only !== true)
    if (!group) {
      this.#finishMutation()
      return
    }
    const item = opts.key === undefined ? undefined : group.items.find(candidate => candidate.key === opts.key)
    if (!item) {
      if (msg === null || msg === undefined || opts.update_only) {
        this.#removeEmptyGroup(group)
        this.#finishMutation()
        return
      }
      if (claim && group.items.length >= claim.capacity) {
        throw new Error(`Notification producer ${String(groupKey)} cannot exceed ${claim.capacity} active items`)
      }
      const created: ActiveNotification = {
        id: this.#nextId++,
        ...(opts.key === undefined ? {} : { key: opts.key }),
        groupKey,
        message: msg,
        ...resolvedAnnote(group.config, level, opts),
        ...(level === null || level === undefined ? {} : { level }),
        hidden: opts.hidden ?? false,
        expiresAt: expiry(now, opts.ttl, group.config.ttl),
        lastUpdated: now,
        skipHistory: opts.skip_history ?? group.config.skip_history ?? false,
        ...(admittedData === undefined ? {} : { data: admittedData })
      }
      group.items.push(created)
      this.#enforceActiveBound(now)
      this.#closed = false
      this.#finishMutation()
      return
    }

    if (msg !== null && msg !== undefined) item.message = msg
    if (level !== null && level !== undefined) {
      item.level = level
      const annote = annoteForLevel(group.config, level)
      if (annote !== undefined) item.annote = annote
    }
    if (Object.hasOwn(opts, "annote")) {
      if (opts.annote === null || opts.annote === undefined) delete item.annote
      else item.annote = opts.annote
    }
    if (Object.hasOwn(opts, "hidden")) item.hidden = opts.hidden ?? false
    if (Object.hasOwn(opts, "ttl")) item.expiresAt = expiry(now, opts.ttl, group.config.ttl)
    if (Object.hasOwn(opts, "skip_history")) item.skipHistory = opts.skip_history ?? false
    if (hasData) {
      if (admittedData === undefined) delete item.data
      else item.data = admittedData
    }
    item.lastUpdated = now
    this.#closed = false
    this.#finishMutation()
  }

  #remove(groupKey: NotificationKey, itemKey: NotificationKey, token?: symbol): boolean {
    this.#assertOpen()
    validateDisplayKey(groupKey, "notification group")
    validateKey(itemKey, "notification key")
    const claim = this.#claims.get(groupKey)
    if (claim?.token !== token || (!claim && token !== undefined)) {
      if (claim) throw new Error(`Notification group ${String(groupKey)} is producer-owned`)
      throw new Error(`Notification producer no longer owns group ${String(groupKey)}`)
    }
    const now = this.#now()
    this.#expire(now)
    const group = this.#groups.find(candidate => candidate.key === groupKey)
    const index = group?.items.findIndex(item => item.key === itemKey) ?? -1
    if (!group || index < 0) {
      this.#finishMutation()
      return false
    }
    const [item] = group.items.splice(index, 1)
    if (item) this.#archive(group, item, now)
    this.#removeEmptyGroup(group)
    this.#closed = false
    this.#finishMutation()
    return true
  }

  #releaseClaim(key: NotificationKey, token: symbol): void {
    if (this.#disposed) return
    const claim = this.#claims.get(key)
    if (claim?.token !== token) return
    const group = this.#groups.find(candidate => candidate.key === key)
    if (group) this.#groups.splice(this.#groups.indexOf(group), 1)
    for (let index = this.#history.length - 1; index >= 0; index--) {
      if (this.#history[index]!.group_key === key) this.#history.splice(index, 1)
    }
    this.#claims.delete(key)
    this.#configs.delete(key)
    this.#finishMutation()
  }

  #assertPublicGroup(key: NotificationKey): void {
    this.#assertOpen()
    if (this.#claims.has(key)) throw new Error(`Notification group ${String(key)} is producer-owned`)
  }

  #group(key: NotificationKey, create: boolean): NotificationGroup | undefined {
    let group = this.#groups.find(candidate => candidate.key === key)
    if (group || !create) return group
    if (this.#groups.length >= maxNotificationGroups)
      throw new Error(`Active notification groups cannot exceed ${maxNotificationGroups}`)
    group = { key, created: this.#nextGroup++, items: [], config: this.#resolveConfig(key) }
    this.#groups.push(group)
    this.#sortGroups()
    return group
  }

  #sortGroups(): void {
    this.#groups.sort((left, right) => left.config.priority - right.config.priority || left.created - right.created)
  }

  #refreshPublicGroupConfigs(key: NotificationKey): void {
    let changed = false
    for (const group of this.#groups) {
      if (this.#claims.has(group.key)) continue
      if (key !== defaultGroupKey && group.key !== key) continue
      group.config = this.#resolveConfig(group.key)
      changed = true
    }
    if (changed) {
      this.#sortGroups()
      this.#closed = false
    }
    this.#render()
  }

  #resolveConfig(key: NotificationKey): NotificationGroup["config"] {
    const configured = this.#configs.get(key) ?? {}
    if (this.#claims.has(key)) {
      return {
        ...configured,
        ttl: configured.ttl ?? defaultNotificationTtlSeconds,
        priority: configured.priority ?? 50
      }
    }
    const fallback = this.#configs.get(defaultGroupKey) ?? {}
    return {
      ...fallback,
      ...configured,
      ...(key !== defaultGroupKey && typeof key === "string" && configured.name === undefined ? { name: key } : {}),
      ttl: configured.ttl ?? fallback.ttl ?? defaultNotificationTtlSeconds,
      priority: configured.priority ?? fallback.priority ?? 50
    }
  }

  #enforceActiveBound(now: number): void {
    while (this.#unclaimedActiveCount() > this.#maxActive) {
      let oldestGroup: NotificationGroup | undefined
      let oldest: ActiveNotification | undefined
      for (const group of this.#groups) {
        if (this.#claims.has(group.key)) continue
        for (const item of group.items) {
          if (
            !oldest ||
            item.lastUpdated < oldest.lastUpdated ||
            (item.lastUpdated === oldest.lastUpdated && item.id < oldest.id)
          ) {
            oldest = item
            oldestGroup = group
          }
        }
      }
      if (!oldest || !oldestGroup) throw new Error("Caller-owned notifications exceeded the active bound")
      oldestGroup.items.splice(oldestGroup.items.indexOf(oldest), 1)
      this.#archive(oldestGroup, oldest, now)
      this.#removeEmptyGroup(oldestGroup)
    }
  }

  #activeCount(): number {
    return this.#groups.reduce((count, group) => count + group.items.length, 0)
  }

  #unclaimedActiveCount(): number {
    return this.#groups.reduce((count, group) => count + (this.#claims.has(group.key) ? 0 : group.items.length), 0)
  }

  #expire(now: number): void {
    for (let groupIndex = this.#groups.length - 1; groupIndex >= 0; groupIndex--) {
      const group = this.#groups[groupIndex]!
      for (let itemIndex = group.items.length - 1; itemIndex >= 0; itemIndex--) {
        const item = group.items[itemIndex]!
        if (item.expiresAt === null || item.expiresAt > now) continue
        group.items.splice(itemIndex, 1)
        this.#archive(group, item, now)
      }
      if (group.items.length === 0) this.#groups.splice(groupIndex, 1)
    }
  }

  #archive(group: NotificationGroup, item: ActiveNotification, removedAt: number): void {
    if (item.skipHistory || this.#historySize === 0) return
    this.#history.push(this.#historyItem(group, item, true, removedAt))
    if (this.#history.length > this.#historySize) this.#history.splice(0, this.#history.length - this.#historySize)
  }

  #historyItem(
    group: NotificationGroup,
    item: ActiveNotification,
    removed: boolean,
    updatedAt: number
  ): NotificationHistoryItem {
    const name = groupName(group)
    const icon = groupIcon(group)
    return Object.freeze({
      ...(item.key === undefined ? {} : { key: item.key }),
      group_key: group.key,
      ...(name === undefined ? {} : { group_name: name }),
      ...(icon === undefined ? {} : { group_icon: icon }),
      message: item.message,
      ...(item.annote === undefined ? {} : { annote: item.annote }),
      ...(item.level === undefined ? {} : { level: item.level }),
      hidden: item.hidden,
      expires_at: item.expiresAt,
      last_updated: updatedAt,
      skip_history: item.skipHistory,
      ...(Object.hasOwn(item, "data") ? { data: item.data } : {}),
      removed
    })
  }

  #removeEmptyGroup(group: NotificationGroup): void {
    if (group.items.length > 0) return
    const index = this.#groups.indexOf(group)
    if (index >= 0) this.#groups.splice(index, 1)
  }

  #finishMutation(): void {
    this.#syncClock()
    this.#render()
  }

  #syncClock(): ClockState {
    const needsClock = this.#groups.some(group => group.items.some(item => item.expiresAt !== null))
    if (needsClock && this.#clock.type === "idle") {
      this.#clock = { type: "live" }
      this.#renderer.requestLive()
    } else if (!needsClock) {
      this.#stopClock()
    }
    return this.#clock
  }

  #stopClock(): void {
    if (this.#clock.type === "idle") return
    this.#clock = { type: "idle" }
    this.#renderer.dropLive()
  }

  #render(): void {
    const lines = this.#renderLines()
    const visible = !this.#suppressed && !this.#closed && lines.length > 0 && this.#host !== undefined
    this.root.visible = visible
    if (!visible) return
    const width = Math.max(...lines.map(line => line.width))
    this.root.width = width
    this.root.height = lines.length
    this.#text.width = width
    this.#text.height = lines.length
    const chunks = []
    for (const [lineIndex, line] of lines.entries()) {
      if (lineIndex > 0) chunks.push(fg(this.#theme.text.muted)("\n"))
      if (line.width < width) chunks.push(fg(this.#theme.text.muted)(" ".repeat(width - line.width)))
      for (const chunk of line.chunks) chunks.push(fg(chunk.color)(chunk.text))
    }
    const content = new StyledText(chunks)
    const signature = `${width}\0${lines.map(line => line.chunks.map(chunk => `${chunk.color}\0${chunk.text}`).join("\x01")).join("\n")}`
    if (signature !== this.#presentation) {
      this.#presentation = signature
      this.#text.content = content
    }
  }

  #renderLines(): RenderLine[] {
    const maxWidth = Math.max(4, this.#renderer.width - 2)
    const chunks: RenderLine[][] = []
    let visible = 0
    for (const group of this.#groups) {
      const header = renderHeader(group, this.#theme, maxWidth)
      if (header) chunks.push([header])
      const deduped = dedupe(group.items)
      const limit = Math.min(group.config.render_limit ?? this.#maxVisible, this.#maxVisible - visible)
      let groupVisible = 0
      for (const { item, count } of deduped) {
        if (item.hidden) continue
        if (groupVisible >= limit) break
        const lines = renderItem(item, count, group.config, this.#theme, maxWidth, this.#maxVisibleLines)
        if (lines.length === 0) continue
        chunks.push(lines)
        groupVisible++
        visible++
      }
      if (visible >= this.#maxVisible) break
      if (group !== this.#groups.at(-1)) chunks.push([renderSeparator(this.#theme)])
    }
    const lines = chunks.toReversed().flat()
    const limit = Math.min(this.#maxVisibleLines, this.#renderer.height)
    return lines.slice(0, limit)
  }

  #onFrame = (): void => {
    if (this.#disposed || this.#clock.type === "idle") return
    const before = this.#activeCount()
    this.#expire(this.#now())
    const changed = before !== this.#activeCount()
    if (changed) this.#render()
    const clock = this.#syncClock()
    if (changed && clock.type === "idle") this.#renderer.requestRender()
  }

  #onResize = (): void => {
    if (!this.#disposed) this.#render()
  }

  #assertOpen(): void {
    if (this.#disposed) throw new Error("NotificationCenter is disposed")
  }
}

function dedupe(
  items: readonly ActiveNotification[]
): readonly { readonly item: ActiveNotification; readonly count: number }[] {
  const byContent = new Map<string, { item: ActiveNotification; count: number }>()
  for (const item of items) {
    const key = JSON.stringify([item.message, item.annote])
    const duplicate = byContent.get(key)
    if (duplicate) duplicate.count++
    else byContent.set(key, { item, count: 1 })
  }
  return [...byContent.values()]
}

function renderHeader(group: NotificationGroup, theme: Theme, maxWidth: number): RenderLine | undefined {
  const name = groupName(group)
  const icon = groupIcon(group)
  if (!name && !icon) return undefined
  const text = group.config.icon_on_left
    ? [icon, name].filter(Boolean).join(" ")
    : [name, icon].filter(Boolean).join(" ")
  return plainLine(truncateToCells(text, maxWidth - 2 * lineMargin), theme.text.accent)
}

function renderSeparator(theme: Theme): RenderLine {
  return plainLine("--", theme.text.dim)
}

function renderItem(
  item: ActiveNotification,
  count: number,
  config: NotificationGroup["config"],
  theme: Theme,
  maxWidth: number,
  maxLines: number
): RenderLine[] {
  const source = count === 1 ? item.message : `(${count}x) ${item.message}`
  const messageLines = source.split("\n", maxLines)
  if (messageLines.length === 1 && messageLines[0] === "" && item.annote === undefined) return []
  const annote = item.annote
  const separator = config.annote_separator ?? " "
  const innerWidth = Math.max(0, maxWidth - 2 * lineMargin)
  const result: RenderLine[] = []
  for (const [index, original] of messageLines.entries()) {
    const showAnnote = index === 0 && annote !== undefined
    const annoteWidth = showAnnote ? textWidth(separator) + textWidth(annote) : 0
    const message = truncateToCells(original, Math.max(0, innerWidth - annoteWidth))
    const chunks: RenderChunk[] = [{ text: " ", color: theme.text.muted }]
    if (message) chunks.push({ text: message, color: theme.text.muted })
    if (showAnnote) {
      if (message) chunks.push({ text: separator, color: theme.text.muted })
      chunks.push({ text: truncateToCells(annote, innerWidth), color: levelColor(item.level, theme) })
    }
    chunks.push({ text: " ", color: theme.text.muted })
    result.push({ chunks, width: chunks.reduce((width, chunk) => width + textWidth(chunk.text), 0) })
  }
  return result
}

function plainLine(text: string, color: string): RenderLine {
  const chunks = [
    { text: " ", color },
    { text, color },
    { text: " ", color }
  ]
  return { chunks, width: textWidth(text) + 2 * lineMargin }
}

function groupName(group: NotificationGroup): string | undefined {
  if (group.config.name === false) return undefined
  if (group.config.name !== undefined) return group.config.name
  return group.key === defaultGroupKey ? "Notifications" : String(group.key)
}

function groupIcon(group: NotificationGroup): string | undefined {
  if (group.config.icon === false) return undefined
  return group.config.icon ?? "❰❰"
}

function resolvedAnnote(
  config: NotificationGroup["config"],
  level: NotificationLevel | null | undefined,
  opts: NotificationOptions
): Pick<ActiveNotification, "annote"> | Record<never, never> {
  if (Object.hasOwn(opts, "annote"))
    return opts.annote === null || opts.annote === undefined ? {} : { annote: opts.annote }
  const annote = level === null || level === undefined ? undefined : annoteForLevel(config, level)
  return annote === undefined ? {} : { annote }
}

function annoteForLevel(config: NotificationGroup["config"], level: NotificationLevel): string | undefined {
  if (typeof level === "string") return undefined
  if (level === 1) return config.debug_annote ?? "DEBUG"
  if (level === 2) return config.info_annote ?? "INFO"
  if (level === 3) return config.warn_annote ?? "WARN"
  if (level >= 4) return config.error_annote ?? "ERROR"
  return undefined
}

function levelColor(level: NotificationLevel | undefined, theme: Theme): string {
  if (typeof level === "string") {
    if (level === "error") return theme.text.error
    if (level === "warn" || level === "warning") return theme.text.warning
    if (level === "success") return theme.text.success
    if (level === "debug" || level === "trace") return theme.text.dim
    return theme.text.accent
  }
  if (level !== undefined && level >= 4) return theme.text.error
  if (level === 3) return theme.text.warning
  if (level === 1) return theme.text.dim
  return theme.text.accent
}

export function validateNotificationCenterOptions(options: NotificationCenterOptions = {}): void {
  admitNotificationCenterOptions(options)
}

function admitNotificationCenterOptions(options: NotificationCenterOwnerOptions): {
  readonly now: () => number
  readonly filter: number
  readonly historySize: number
  readonly maxActive: number
  readonly maxVisible: number
  readonly maxVisibleLines: number
} {
  const filter = options.filter ?? 2
  if (!Number.isFinite(filter)) throw new Error("Notification filter must be finite")
  return {
    now: options.now ?? (() => Date.now() / 1000),
    filter,
    historySize: boundedCount(options.history_size, maxNotificationHistory, maxNotificationHistory, "history_size"),
    maxActive: boundedPositiveCount(options.max_active, maxNotificationActive, maxNotificationActive, "max_active"),
    maxVisible: boundedPositiveCount(
      options.max_visible,
      maxVisibleNotifications,
      maxVisibleNotifications,
      "max_visible"
    ),
    maxVisibleLines: boundedPositiveCount(
      options.max_visible_lines,
      maxVisibleNotificationLines,
      maxVisibleNotificationLines,
      "max_visible_lines"
    )
  }
}

function expiry(now: number, ttl: number | undefined, defaultTtl: number): number | null {
  const seconds = ttl === undefined || ttl === 0 ? defaultTtl : ttl
  return seconds === Infinity ? null : now + seconds
}

function matchesHistoryTime(lastUpdated: number, now: number, filter: NotificationHistoryFilter): boolean {
  const ageSeconds = now - lastUpdated
  if (filter.before !== undefined && ageSeconds < filter.before) return false
  if (filter.since !== undefined && ageSeconds > filter.since) return false
  return true
}

function validateNotificationInput(
  msg: string | null | undefined,
  level: NotificationLevel | null | undefined,
  opts: NotificationOptions
): void {
  if (msg !== null && msg !== undefined) validateText(msg, "message", maxNotificationMessageBytes)
  if (!opts || typeof opts !== "object" || Array.isArray(opts))
    throw new Error("Notification options must be an object")
  if (level !== null && level !== undefined && typeof level !== "number" && typeof level !== "string") {
    throw new Error("Notification level must be a number or string")
  }
  if (typeof level === "number" && !Number.isFinite(level)) throw new Error("Notification level must be finite")
  if (typeof level === "string") validateSingleLine(level, "level", maxNotificationAnnoteBytes)
  if (opts.key !== undefined) validateKey(opts.key, "notification key")
  if (opts.group !== undefined) validateDisplayKey(opts.group, "notification group")
  if (opts.annote !== null && opts.annote !== undefined) {
    validateSingleLine(opts.annote, "annotation", maxNotificationAnnoteBytes)
  }
  validateOptionalBoolean(opts.hidden, "hidden")
  validateOptionalBoolean(opts.update_only, "update_only")
  validateOptionalBoolean(opts.skip_history, "skip_history")
  if (opts.ttl !== undefined && opts.ttl !== Infinity && (!Number.isFinite(opts.ttl) || opts.ttl < 0)) {
    throw new Error("Notification ttl must be a non-negative number or Infinity")
  }
}

function admitNotificationData(value: NotificationData | undefined): NotificationData | undefined {
  if (value === undefined) return undefined
  let admitted: NotificationData
  let serialized: string
  try {
    admitted = freezeNotificationData(value, 0, { nodes: 0, bytes: 0, ancestors: new Set() })
    serialized = JSON.stringify(admitted)
  } catch (cause) {
    if (cause instanceof Error && cause.message.startsWith("Notification data cannot exceed")) throw cause
    throw new Error("Notification data must be bounded JSON", { cause })
  }
  if (Buffer.byteLength(serialized) > maxNotificationDataBytes) {
    throw new Error(`Notification data cannot exceed ${maxNotificationDataBytes} bytes`)
  }
  return admitted
}

interface NotificationDataAdmission {
  nodes: number
  bytes: number
  readonly ancestors: Set<object>
}

function freezeNotificationData(value: unknown, depth: number, admission: NotificationDataAdmission): NotificationData {
  if (depth > maxNotificationDataDepth) {
    throw new Error(`Notification data cannot exceed depth ${maxNotificationDataDepth}`)
  }
  admission.nodes++
  if (admission.nodes > maxNotificationDataNodes) {
    throw new Error(`Notification data cannot exceed ${maxNotificationDataNodes} nodes`)
  }
  if (value === null || typeof value === "boolean") return value
  if (typeof value === "string") {
    admitNotificationDataText(value, admission)
    return value
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Notification data must be bounded JSON")
    return value
  }
  if (typeof value !== "object") throw new Error("Notification data must be bounded JSON")
  if (admission.ancestors.has(value)) throw new Error("Notification data must be bounded JSON")
  admission.ancestors.add(value)
  try {
    if (Array.isArray(value)) {
      const frozen: NotificationData[] = []
      for (const item of value) frozen.push(freezeNotificationData(item, depth + 1, admission))
      return Object.freeze(frozen)
    }
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) throw new Error("Notification data must be bounded JSON")
    const frozen: Record<string, NotificationData> = {}
    for (const key in value) {
      if (!Object.hasOwn(value, key)) continue
      admitNotificationDataText(key, admission)
      const descriptor = Object.getOwnPropertyDescriptor(value, key)
      if (!descriptor || !("value" in descriptor)) throw new Error("Notification data must be bounded JSON")
      Object.defineProperty(frozen, key, {
        value: freezeNotificationData(descriptor.value, depth + 1, admission),
        enumerable: true,
        writable: false,
        configurable: false
      })
    }
    return Object.freeze(frozen)
  } finally {
    admission.ancestors.delete(value)
  }
}

function admitNotificationDataText(value: string, admission: NotificationDataAdmission): void {
  admission.bytes += Buffer.byteLength(value)
  if (admission.bytes > maxNotificationDataBytes) {
    throw new Error(`Notification data cannot exceed ${maxNotificationDataBytes} bytes`)
  }
}

function validateGroupConfig(config: NotificationGroupConfig): void {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("Notification group config must be an object")
  }
  if (config.name !== undefined && config.name !== false) {
    validateSingleLine(config.name, "group name", maxNotificationAnnoteBytes)
  }
  if (config.icon !== undefined && config.icon !== false) {
    validateSingleLine(config.icon, "group icon", maxNotificationAnnoteBytes)
  }
  if (config.annote_separator !== undefined) {
    validateSingleLine(config.annote_separator, "annotation separator", 64)
  }
  validateOptionalBoolean(config.icon_on_left, "icon_on_left")
  validateOptionalBoolean(config.skip_history, "skip_history")
  if (config.ttl !== undefined && config.ttl !== Infinity && (!Number.isFinite(config.ttl) || config.ttl < 0)) {
    throw new Error("Notification config ttl must be a non-negative number or Infinity")
  }
  if (config.render_limit !== undefined) {
    boundedPositiveCount(config.render_limit, 1, maxVisibleNotifications, "render_limit")
  }
  if (config.priority !== undefined && !Number.isFinite(config.priority)) {
    throw new Error("Notification priority must be finite")
  }
  for (const [name, value] of [
    ["debug_annote", config.debug_annote],
    ["info_annote", config.info_annote],
    ["warn_annote", config.warn_annote],
    ["error_annote", config.error_annote]
  ] as const) {
    if (value !== undefined) validateSingleLine(value, name, maxNotificationAnnoteBytes)
  }
}

function validateHistoryFilter(filter: NotificationHistoryFilter): void {
  if (!filter || typeof filter !== "object" || Array.isArray(filter)) {
    throw new Error("Notification history filter must be an object or group key")
  }
  if (filter.group_key !== undefined) validateKey(filter.group_key, "history group")
  validateOptionalBoolean(filter.include_active, "include_active")
  validateOptionalBoolean(filter.include_removed, "include_removed")
  for (const [name, value] of [
    ["before", filter.before],
    ["since", filter.since]
  ] as const) {
    if (value !== undefined && (!Number.isFinite(value) || value < 0))
      throw new Error(`Notification ${name} must be non-negative`)
  }
}

function validateKey(key: NotificationKey, label: string): void {
  if ((typeof key !== "string" && typeof key !== "number") || (typeof key === "number" && !Number.isFinite(key))) {
    throw new Error(`${label} must be a finite number or string`)
  }
  if (typeof key === "string" && Buffer.byteLength(key) > maxNotificationAnnoteBytes) {
    throw new Error(`${label} cannot exceed ${maxNotificationAnnoteBytes} bytes`)
  }
}

function validateDisplayKey(key: NotificationKey, label: string): void {
  validateKey(key, label)
  if (typeof key === "string" && /[\r\n]/u.test(key)) throw new Error(`${label} must be single-line`)
}

function validateSingleLine(value: string, label: string, maxBytes: number): void {
  validateText(value, label, maxBytes)
  if (/[\r\n]/u.test(value)) throw new Error(`Notification ${label} must be single-line`)
}

function validateText(value: string, label: string, maxBytes: number): void {
  if (typeof value !== "string") throw new Error(`Notification ${label} must be a string`)
  if (Buffer.byteLength(value) > maxBytes) throw new Error(`Notification ${label} cannot exceed ${maxBytes} bytes`)
}

function validateOptionalBoolean(value: boolean | undefined, label: string): void {
  if (value !== undefined && typeof value !== "boolean") throw new Error(`Notification ${label} must be boolean`)
}

function boundedCount(value: number | undefined, fallback: number, maximum: number, label: string): number {
  const admitted = value ?? fallback
  if (!Number.isSafeInteger(admitted) || admitted < 0 || admitted > maximum) {
    throw new Error(`Notification ${label} must be an integer from 0 through ${maximum}`)
  }
  return admitted
}

function boundedPositiveCount(value: number | undefined, fallback: number, maximum: number, label: string): number {
  const admitted = boundedCount(value, fallback, maximum, label)
  if (admitted === 0) throw new Error(`Notification ${label} must be positive`)
  return admitted
}
