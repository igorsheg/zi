import { parseColor, RGBA } from "@opentui/core"

import type { Color } from "../theme.js"

export function createColorRamp(from: Color, to: Color, steps: number): readonly RGBA[] {
  const start = parseColor(from)
  const end = parseColor(to)
  const startChannels = start.toInts()
  const endChannels = end.toInts()
  const last = steps - 1

  return Array.from({ length: steps }, (_, index) => {
    if (index === 0) return start
    if (index === last) return end
    return RGBA.fromInts(
      interpolateChannel(startChannels[0], endChannels[0], index, last),
      interpolateChannel(startChannels[1], endChannels[1], index, last),
      interpolateChannel(startChannels[2], endChannels[2], index, last),
      interpolateChannel(startChannels[3], endChannels[3], index, last)
    )
  })
}

function interpolateChannel(from: number, to: number, step: number, last: number): number {
  return from + Math.trunc(((to - from) * step) / last)
}
